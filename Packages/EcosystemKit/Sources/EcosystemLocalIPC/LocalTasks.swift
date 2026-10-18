import Foundation
import EcosystemContracts
import EcosystemRuntimeSupport

public extension LocalRPCClient {
    /// task.get остаётся авторизованным доменным endpoint. Ни taskID, ни роль
    /// из payload не дают доступ: runtime сверяет роль listener и свою запись.
    func waitForResult<T: Decodable & Sendable>(_ id: UUID, as type: T.Type = T.self,
                                    cancelOnCancellation: Bool = true,
                                    onProgress: @escaping @Sendable (TaskProgress?) async -> Void = { _ in }) async throws -> T {
        let data = try await waitForData(id, cancelOnCancellation: cancelOnCancellation, onProgress: onProgress)
        return try LocalWire.decode(type, data)
    }
    func waitForData(_ id: UUID, cancelOnCancellation: Bool = true,
                     onProgress: @escaping @Sendable (TaskProgress?) async -> Void = { _ in }) async throws -> Data {
        let start = ContinuousClock.now
        do {
            while true {
                try Task.checkCancellation()
                let task: DurableTask = try await call("task.get", LocalTaskID(id))
                await onProgress(task.progress)
                if task.status.isTerminal {
                    switch task.status {
                    case .completed, .partial:
                        guard let data = task.result else { throw LocalRuntimeFailure.operationFailed }
                        return data
                    case .cancelled: throw CancellationError()
                    case .recoveryRequired, .interrupted: throw LocalRuntimeFailure.recoveryRequired
                    case .failed where task.errorCode == .permissionDenied: throw LocalRuntimeFailure.denied
                    case .failed where task.errorCode == .invalidArgument: throw LocalRuntimeFailure.invalidRequest
                    case .failed where task.errorCode == .clientUnavailable: throw LocalRuntimeFailure.requiresGUI
                    case .failed where task.errorCode == .staleSnapshot: throw LocalRuntimeFailure.staleSnapshot
                    default: throw task.errorCode == .deadlineExceeded ? LocalRuntimeFailure.deadlineExceeded : LocalRuntimeFailure.operationFailed
                    }
                }
                guard start.duration(to: .now) < .seconds(310) else { throw LocalRuntimeFailure.deadlineExceeded }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch is CancellationError {
            if cancelOnCancellation {
                // Отменённый Swift Task не может послать новый XPC-запрос сам;
                // отдельный короткий Task доставляет явный запрос отмены runtime.
                Task.detached { let _: LocalEmpty? = try? await self.call("task.cancel", LocalTaskID(id)) }
            }
            throw CancellationError()
        }
    }
}
