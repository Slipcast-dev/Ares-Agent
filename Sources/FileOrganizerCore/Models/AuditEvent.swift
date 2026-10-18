import Foundation

/// Неизменяемая запись аудита. Детальные пути и секреты не входят в модель:
/// экспорт журнала должен быть безопасен даже при передаче внешнему агенту.
public struct AuditEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let origin: TaskOrigin
    public let correlationID: String?
    public let eventType: String
    public let createdAt: Date
    public let summary: String

    public init(
        id: UUID = UUID(),
        origin: TaskOrigin,
        correlationID: String? = nil,
        eventType: String,
        createdAt: Date = Date(),
        summary: String
    ) {
        self.id = id
        self.origin = origin
        self.correlationID = correlationID
        self.eventType = eventType
        self.createdAt = createdAt
        self.summary = summary
    }
}
