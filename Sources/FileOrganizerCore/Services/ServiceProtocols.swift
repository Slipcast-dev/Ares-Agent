import Foundation

/// Контракт будущего безопасного хранилища корней. Реализация появится вместе с
/// security-scoped bookmarks на CP-03, а протокол уже сейчас защищает UI и MCP
/// от знания формата хранения разрешений.
public protocol AuthorizedRootStoring: Sendable {
    func fetchRoots() async throws -> [AuthorizedRoot]
    func root(withID id: UUID) async throws -> AuthorizedRoot?
}

/// Контракт координатора задач. Он отделяет API планирования от конкретной
/// очереди, поэтому в тестах можно будет использовать детерминированный вариант.
public protocol TaskCoordinating: Sendable {
    func task(withID id: UUID) async throws -> AgentTask?
    func cancelTask(withID id: UUID) async throws
}

/// Журнал фиксирует действия до появления реальных файловых мутаций. Отдельный
/// контракт позволит покрыть безопасное логирование модульными тестами.
public protocol AuditRecording: Sendable {
    func record(_ event: AuditEvent) async throws
    func recentEvents(limit: Int) async throws -> [AuditEvent]
}
