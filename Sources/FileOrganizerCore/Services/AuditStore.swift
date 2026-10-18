import Foundation

/// Временное локальное хранилище аудита с сериализацией доступа. Контракт уже
/// совпадает с будущей SQLite-реализацией, поэтому замена не затронет UI и
/// исполнитель планов.
public actor InMemoryAuditStore: AuditRecording {
    private var events: [AuditEvent] = []

    public init() {}

    public func record(_ event: AuditEvent) {
        events.append(event)
    }

    public func recentEvents(limit: Int) -> [AuditEvent] {
        Array(events.suffix(max(limit, 0)).reversed())
    }
}
