import Foundation

public enum TransitionAuthority: String, Codable, Sendable { case scheduler, executor, policy, recovery }
public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case queued, running, waitingForApproval, waitingForResource, cancelling
    case completed, partial, failed, cancelled, interrupted, recoveryRequired
    public var isTerminal: Bool {
        [.completed, .partial, .failed, .cancelled, .interrupted, .recoveryRequired].contains(self)
    }
    public func requireTransition(to next: Self, by authority: TransitionAuthority) throws {
        // Завершённый результат неизменяем; retry создаёт отдельную попытку.
        guard !isTerminal, self != next else { throw ContractFailure.forbiddenTransition }
        let allowed: Bool
        switch (self, next, authority) {
        case (.queued, .running, .executor), (.queued, .waitingForApproval, .policy),
             (.queued, .waitingForResource, .scheduler), (.waitingForApproval, .queued, .policy),
             (.waitingForResource, .queued, .scheduler): allowed = true
        case (_, .cancelling, .executor): allowed = true
        // Запрос отмены может опоздать к безопасной точке. Тогда публикуется
        // фактический completed/partial/failed, а не ложный cancelled.
        case (.cancelling, .completed, .executor), (.cancelling, .partial, .executor),
             (.cancelling, .failed, .executor), (.running, .completed, .executor), (.running, .partial, .executor),
             (.running, .failed, .executor), (.cancelling, .cancelled, .executor),
             (.queued, .cancelled, .executor), (.waitingForApproval, .cancelled, .executor),
             (.waitingForResource, .cancelled, .executor): allowed = true
        case (_, .interrupted, .recovery), (_, .recoveryRequired, .recovery): allowed = true
        default: allowed = false
        }
        guard allowed else { throw ContractFailure.forbiddenTransition }
    }
}
