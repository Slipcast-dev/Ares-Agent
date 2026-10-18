import EcosystemContracts
import Foundation

public struct RegisteredQueueOperation: Sendable {
    public let mutating: Bool
    public let perform: @Sendable (Data, QueueExecutionContext) async throws -> Data
    public init(mutating: Bool, perform: @escaping @Sendable (Data, QueueExecutionContext) async throws -> Data) {
        self.mutating = mutating; self.perform = perform
    }
}

/// Проверки кооперативной отмены/lease выполняются внутри длительных обходов и
/// перед изменением. Проверку grant/плана домен добавляет непосредственно перед API ФС.
public enum QueueAuthorizationCheck: Sendable { case checkpoint, root(UUID), budget(objects: Int, bytes: Int64) }
public struct QueueExecutionContext: Sendable {
    private let queue: DurableTaskQueue
    public let lease: QueueLease
    private var authorization: (@Sendable (QueueAuthorizationCheck) async throws -> Void)? = nil
    public func withAuthorization(_ check: @escaping @Sendable (QueueAuthorizationCheck) async throws -> Void) -> Self {
        var result = self; result.authorization = check; return result
    }
    public func authorizeRoot(_ id: UUID) async throws { try await authorization?(.root(id)); try await checkpoint() }
    public func authorizeBudget(objects: Int, bytes: Int64) async throws { try await authorization?(.budget(objects: objects, bytes: bytes)); try await checkpoint() }
    init(queue: DurableTaskQueue, lease: QueueLease) { self.queue = queue; self.lease = lease }
    public func checkpoint() async throws {
        try Task.checkCancellation(); try await queue.checkpoint(lease); try await authorization?(.checkpoint)
    }
    public func progress(_ value: TaskProgress) async throws {
        try await checkpoint(); try await queue.reportProgress(lease, progress: value)
    }
    public func recordedAction(key: String, summary: String? = nil, operation: @Sendable () async throws -> Data) async throws -> Data {
        try await checkpoint()
        let receipt = try await queue.beginReceipt(lease, actionKey: key, summary: summary)
        do { try await checkpoint() }
        catch {
            // Callback ещё не запускался: отсутствие эффекта известно, а не
            // предполагается по типу ошибки после произвольной файловой операции.
            try await queue.confirmNoEffect(lease, receiptID: receipt.id, evidence: Data("callback-not-entered".utf8))
            throw error
        }
        let result = try await operation()
        try await queue.completeReceipt(lease, receiptID: receipt.id, evidence: result)
        return result
    }
}

/// Отдельный экземпляр создаётся runtime каждого домена. Реестр фиксируется
/// кодом, а не аргументами модели; shell и произвольные handlers не принимаются.
public actor DurableTaskExecutor {
    private struct RunningJob {
        let operation: Task<Data, Error>
        let heartbeat: Task<Void, Never>
        let deadline: Task<Void, Never>?
    }
    private let queue: DurableTaskQueue
    private let operations: [String: RegisteredQueueOperation]
    private var running: [UUID: RunningJob] = [:]
    private var pumping = false
    private var pumpAgain = false
    private var accepting = true
    private var supervisor: Task<Void, Never>?
    private var supervisionFailure: QueueFailure?
    private var supervisionTicks = 0
    private var finalizationFailures: [UUID: QueueFailure] = [:]

    public init(queue: DurableTaskQueue, operations: [String: RegisteredQueueOperation]) throws {
        try operations.keys.forEach { try ContractValidation.identifier($0) }
        self.queue = queue; self.operations = operations
    }
    public func submit(_ value: QueueSubmission, retrying previousID: UUID? = nil) async throws -> DurableTask {
        guard accepting, let operation = operations[value.capabilityID], operation.mutating == value.mutating else {
            throw QueueFailure.invalidArgument
        }
        let accepted = try await queue.accept(value, retrying: previousID)
        try await pump()
        return accepted
    }
    /// Runtime явно включает supervisor после готовности handlers/БД. Он
    /// отменяет fenced callbacks и не освобождает физический слот до их возврата.
    public func startSupervision() {
        guard supervisor == nil else { return }
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
                guard let self else { return }
                await self.supervise()
            }
        }
    }
    private func supervise() async {
        do {
            try await queue.recoverExpiredLeases()
            for id in Array(running.keys) {
                if let value = try await queue.task(id), value.status.isTerminal {
                    running[id]?.operation.cancel()
                }
            }
            supervisionTicks += 1
            if supervisionTicks >= 60 {
                _ = try await queue.purgeExpiredReadHistory()
                supervisionTicks = 0
            }
            for id in Array(finalizationFailures.keys) {
                if try await queue.task(id)?.status.isTerminal == true { finalizationFailures[id] = nil }
            }
            try await pump()
            supervisionFailure = nil
        } catch { supervisionFailure = .storageFailure }
    }
    public func resumeQueuedTasks() async throws { try await pump() }
    public func cancel(_ id: UUID) async throws {
        _ = try await queue.requestCancellation(id)
        running[id]?.operation.cancel()
        try await pump()
    }
    /// Expiry может опередить реально зависший callback. Оператор не имеет права
    /// освободить quarantine, пока этот callback ещё способен изменить файлы.
    public func canReconcile(_ id: UUID) -> Bool { running[id] == nil }
    public func reconcile(_ id: UUID, resolutions: [UUID: ReceiptResolution]) async throws -> DurableTask {
        guard running[id] == nil else { throw QueueFailure.resourceBusy }
        return try await queue.reconcile(id, resolutions: resolutions)
    }
    public func failures() -> [UUID: QueueFailure] { finalizationFailures }
    public func isHealthy() -> Bool { supervisionFailure == nil && finalizationFailures.isEmpty }

    /// Отключение клиента по умолчанию не останавливает runtime. Для opt-in
    /// cancelOnDisconnect сервер передаёт только task IDs своего соединения.
    public func clientDisconnected(taskIDs: [UUID]) async throws {
        for id in taskIDs {
            guard let task = try await queue.task(id) else { continue }
            let object = try JSONSerialization.jsonObject(with: task.request) as? [String: Any]
            if object?["disconnectPolicy"] as? String == DisconnectPolicy.cancelOnDisconnect.rawValue {
                try await cancel(id)
            }
        }
    }
    public func stopAcceptingAndCancelRunning() async throws {
        accepting = false
        supervisor?.cancel(); supervisor = nil
        for id in Array(running.keys) {
            _ = try await queue.requestCancellation(id)
            running[id]?.operation.cancel()
        }
        // queued сохраняются для контролируемого следующего запуска. Возврат
        // этой функции означает запрос остановки, а не завершение всех callbacks.
    }
    /// Graceful shutdown ограничен по времени. false означает, что callback
    /// ещё жив: процесс может завершиться, но результат потребует recovery.
    public func drain(timeoutSeconds: Double = 3) async throws -> Bool {
        guard timeoutSeconds.isFinite, (0.01...10).contains(timeoutSeconds) else { throw QueueFailure.invalidArgument }
        try await stopAcceptingAndCancelRunning()
        let start = ContinuousClock.now
        while !running.isEmpty {
            if start.duration(to: .now) >= .seconds(timeoutSeconds) { return false }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
    public func waitForTerminal(_ id: UUID, timeoutSeconds: Double = 10) async throws -> DurableTask {
        guard timeoutSeconds.isFinite, (0.01...300).contains(timeoutSeconds) else { throw QueueFailure.invalidArgument }
        let start = ContinuousClock.now
        while true {
            guard let value = try await queue.task(id) else { throw QueueFailure.taskNotFound }
            if value.status.isTerminal { return value }
            guard start.duration(to: .now) < .seconds(timeoutSeconds) else { throw QueueFailure.deadlineExceeded }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func pump() async throws {
        guard accepting else { return }
        if pumping { pumpAgain = true; return }
        pumping = true
        defer { pumping = false }
        repeat {
            pumpAgain = false
            while accepting, running.count < queue.maximumConcurrentTasks, let value = try await queue.nextQueuedTask() {
                let token: QueueLease
                do { token = try await queue.claim(value.id) }
                catch QueueFailure.capacityReached { break }
                catch QueueFailure.invalidState { continue } // queued отменён между await.
                guard let registered = operations[value.capabilityID], registered.mutating == value.mutating else {
                    _ = try await queue.finish(token, status: .failed, errorCode: .unknownCapability)
                    continue
                }
                // Actor мог принять shutdown во время await claim. Такой callback
                // ещё не начат: закрываем его без запуска и без файлового эффекта.
                guard accepting else {
                    _ = try await queue.requestCancellation(value.id)
                    _ = try await queue.finish(token, status: .cancelled, errorCode: .cancelled)
                    break
                }
                let context = QueueExecutionContext(queue: queue, lease: token)
                // Detached отделяет даже CPU-часть callback от actor планировщика.
                let operation = Task.detached(priority: .utility) {
                    try await context.checkpoint()
                    return try await registered.perform(value.request, context)
                }
                let heartbeat = Task { [queue] in
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(nanoseconds: 10_000_000_000)
                            _ = try await queue.heartbeat(token)
                        }
                    } catch is CancellationError { return }
                    catch {
                        operation.cancel()
                        try? await queue.recoverExpiredLeases()
                    }
                }
                // Запись handle предшествует первому ожиданию результата, чтобы
                // быстро завершившийся callback не оставил вечную busy-запись.
                let deadline: Task<Void, Never>? = value.deadline.map { limit in
                    Task {
                        do {
                            while limit > Date() {
                                let seconds = min(60, max(0, limit.timeIntervalSinceNow))
                                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                            }
                            operation.cancel()
                        } catch { return }
                    }
                }
                running[value.id] = RunningJob(operation: operation, heartbeat: heartbeat, deadline: deadline)
                Task { await finalize(value.id, token: token, result: await operation.result) }
            }
        } while pumpAgain && accepting
    }
    private func finalize(_ id: UUID, token: QueueLease, result: Result<Data, Error>) async {
        running[id]?.heartbeat.cancel()
        running[id]?.deadline?.cancel()
        do {
            switch result {
            case .success(let data):
                // Неверный ответ handler не должен оставлять вечную running-задачу
                // после отказа сериализации. Сохраняем безопасную ошибку без payload.
                if data.count > ContractCodec.maximumBytes {
                    _ = try await queue.finish(token, status: .failed, errorCode: .internalError)
                } else {
                    _ = try await queue.finish(token, status: .completed, result: data)
                }
            case .failure(let error):
                let current = try await queue.task(id)
                if let limit = current?.deadline, limit <= Date() {
                    _ = try await queue.finish(token, status: .failed, errorCode: .deadlineExceeded)
                } else if error is CancellationError || (error as? QueueFailure) == .cancelled {
                    _ = try await queue.requestCancellation(id)
                    _ = try await queue.finish(token, status: .cancelled, errorCode: .cancelled)
                } else {
                    _ = try await queue.finish(token, status: .failed,
                        errorCode: (error as? QueueDomainError)?.knownCode ?? ((error as? QueueFailure) == .deadlineExceeded ? .deadlineExceeded : .internalError))
                }
            }
        } catch {
            // Уже восстановленную/fenced задачу не переписываем старым результатом.
            let current = try? await queue.task(id)
            if current?.status.isTerminal != true {
                if finalizationFailures.count >= 64 { finalizationFailures.removeAll() }
                finalizationFailures[id] = .storageFailure
            }
        }
        running[id] = nil
        do { try await pump() }
        catch {
            if finalizationFailures.count >= 64 { finalizationFailures.removeAll() }
            finalizationFailures[id] = .storageFailure
        }
    }
}
