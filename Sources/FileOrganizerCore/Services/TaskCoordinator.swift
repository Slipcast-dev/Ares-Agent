import Foundation
import EcosystemLocalIPC
import EcosystemContracts

/// Локальный клиент передаёт операции единственному runtime. Совместимый
/// внутрипроцессный режим нужен старым установкам и изолированным unit tests.
public actor TaskCoordinator: TaskCoordinating {
    private struct Running { let id: UUID; var handle: Task<Void, Never>?; var cancellationRequested = false }
    private let repository: any FileRepository
    private let access: AuthorizedRootAccessService
    private let remote: Result<LocalRPCClient, Error>?
    private var running: [UUID: Running] = [:]
    public init(repository: any FileRepository, access: AuthorizedRootAccessService? = nil,
                remote: Result<LocalRPCClient, Error>? = nil) {
        self.repository = repository; self.access = access ?? AuthorizedRootAccessService(repository: repository)
        self.remote = remote
    }
    public func scan(rootID: UUID, origin: TaskOrigin, correlationID: String? = nil,
                     idempotencyKey: String = UUID().uuidString) async throws -> AgentTask {
        if let remote {
            let client = try remote.get()
            let job = AresJob(rootID: rootID, origin: origin, correlationID: correlationID)
            let value: LocalTaskID = try await client.call("work.submit", AresSubmission(capability: "file.scan", job: job, key: idempotencyKey))
            guard let task = try await task(withID: value.id) else { throw LocalRuntimeFailure.operationFailed }
            return task
        }
        guard let root = try await repository.root(withID: rootID) else { throw AuthorizedRootAccessError.missingBookmark }
        let rootURL = try await access.resolveURL(for: root)
        return try await startScan(root: root, rootURL: rootURL, indexingService: FileIndexingService(), origin: origin, correlationID: correlationID)
    }
    public func startScan(root: AuthorizedRoot, rootURL: URL, indexingService: FileIndexingService,
                          origin: TaskOrigin, correlationID: String?) async throws -> AgentTask {
        if remote != nil { return try await scan(rootID: root.id, origin: origin, correlationID: correlationID) }
        guard running[root.id] == nil else { throw TaskCoordinatorError.rootBusy }
        let task = AgentTask(rootID: root.id, origin: origin, correlationID: correlationID)
        // Резервируем ДО первого await: actor reentrancy не пропустит второй scan.
        running[root.id] = Running(id: task.id, handle: nil)
        do { try await repository.save(task: task) }
        catch { running[root.id] = nil; throw error }
        let handle = Task { [repository, weak self] in
            do {
                try Task.checkCancellation()
                try await repository.save(task: Self.state(task, .running))
                guard rootURL.startAccessingSecurityScopedResource() else { throw AuthorizedRootAccessError.accessDenied }
                defer { rootURL.stopAccessingSecurityScopedResource() }
                let result = try await indexingService.scan(root: root, rootURL: rootURL) { _ in }
                try Task.checkCancellation()
                try await repository.replaceIndex(records: result.records, forRootID: root.id)
                try await repository.save(task: Self.state(task, .completed))
            } catch is CancellationError { try? await repository.save(task: Self.state(task, .cancelled)) }
            catch { try? await repository.save(task: Self.state(task, .failed)) }
            await self?.finished(root.id, id: task.id)
        }
        running[root.id]?.handle = handle
        if running[root.id]?.cancellationRequested == true { handle.cancel() }
        return task
    }
    private static func state(_ task: AgentTask, _ status: AgentTaskStatus) -> AgentTask {
        AgentTask(id: task.id, rootID: task.rootID, origin: task.origin, correlationID: task.correlationID, status: status, createdAt: task.createdAt)
    }
    private func finished(_ root: UUID, id: UUID) {
        if running[root]?.id == id { running[root] = nil }
    }
    public func task(withID id: UUID) async throws -> AgentTask? { try await repository.task(withID: id) }
    public func cancelTask(withID id: UUID) async throws {
        if let remote { let _: LocalEmpty = try await remote.get().call("task.cancel", LocalTaskID(id)); return }
        guard let task = try await repository.task(withID: id), running[task.rootID]?.id == id else { return }
        // Отмена старого ID не трогает новый scan; busy снимается после возврата callback.
        running[task.rootID]?.cancellationRequested = true
        running[task.rootID]?.handle?.cancel()
    }
    public func waitForScan(_ id: UUID, onProgress: @escaping @Sendable (ScanProgress) async -> Void = { _ in }) async throws -> ScanSummary {
        if let remote {
            return try await remote.get().waitForResult(id, as: ScanSummary.self, onProgress: { progress in
                if let progress { await onProgress(ScanProgress(indexedFileCount: Int(progress.processed.value), skippedItemCount: 0)) }
            })
        }
        let start = ContinuousClock.now
        while let task = try await repository.task(withID: id) {
            if task.status == .completed {
                let records = try await repository.records(forRootID: task.rootID)
                return ScanSummary(rootID: task.rootID, indexedFileCount: records.count, skippedItemCount: 0,
                                   totalByteSize: records.reduce(0) { $0 + $1.byteSize })
            }
            if task.status.isTerminal { throw task.status == .cancelled ? LocalRuntimeFailure.cancelled : .operationFailed }
            guard start.duration(to: .now) < .seconds(310) else { throw LocalRuntimeFailure.deadlineExceeded }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { try? await cancelTask(withID: id); throw error }
        }
        throw LocalRuntimeFailure.invalidRequest
    }
    public func duplicatePage(rootID: UUID, cursor: String) async throws -> DuplicateAnalysis {
        guard let remote else { throw AresFileFailure.invalidCursor }
        let client = try remote.get()
        let id: LocalTaskID = try await client.call("work.submit", AresSubmission(capability: "file.find_duplicates", job: AresJob(rootID: rootID, cursor: cursor), key: UUID().uuidString))
        return try await client.waitForResult(id.id)
    }
    public func findDuplicates(rootID: UUID) async throws -> DuplicateAnalysis {
        if let remote {
            let client = try remote.get()
            let id: LocalTaskID = try await client.call("work.submit", AresSubmission(capability: "file.compute_duplicates", job: AresJob(rootID: rootID), key: UUID().uuidString))
            return try await client.waitForResult(id.id)
        }
        guard running[rootID] == nil else { throw TaskCoordinatorError.rootBusy }
        let id = UUID(); running[rootID] = Running(id: id, handle: nil)
        defer { finished(rootID, id: id) }
        guard let root = try await repository.root(withID: rootID) else { throw AuthorizedRootAccessError.missingBookmark }
        let url = try await access.resolveURL(for: root)
        guard url.startAccessingSecurityScopedResource() else { throw AuthorizedRootAccessError.accessDenied }
        defer { url.stopAccessingSecurityScopedResource() }
        let records = try await repository.records(forRootID: rootID)
        let groups = try await DuplicateDetectionService().findExactDuplicates(rootURL: url, records: records, onProgress: { _, _ in },
            persistHash: { [repository] id, hash in try await repository.updateContentHash(hash, forRecordID: id) })
        return DuplicateAnalysis(groups: groups, largeFiles: Array(records.sorted { $0.byteSize > $1.byteSize }.prefix(20)))
    }
}
public enum TaskCoordinatorError: Error, LocalizedError, Sendable {
    case rootBusy
    public var errorDescription: String? { "Для этой папки уже выполняется задача." }
}
