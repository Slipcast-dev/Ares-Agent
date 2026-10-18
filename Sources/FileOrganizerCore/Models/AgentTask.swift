import Foundation

/// Источник задачи сохраняется в журнале, чтобы пользователь видел, кто запросил
/// операцию. Это не даёт источнику дополнительных прав: их проверяет политика.
public enum TaskOrigin: String, Codable, CaseIterable, Sendable {
    case user
    case codex
    case deepSeekHarness
    case localRule
}

/// Жизненный цикл фоновой задачи. Терминальные статусы отделены от активных, что
/// позволит координатору в следующих этапах корректно освобождать блокировку корня.
public enum AgentTaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case completed
    case cancelled
    case failed
    case cancelling, interrupted, recoveryRequired, partial

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed, .interrupted, .recoveryRequired, .partial:
            return true
        case .queued, .running, .cancelling:
            return false
        }
    }
}

/// Нейтральная запись задачи, не привязанная к SwiftUI или транспорту MCP.
public struct AgentTask: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let rootID: UUID
    public let origin: TaskOrigin
    public let correlationID: String?
    public let status: AgentTaskStatus
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        rootID: UUID,
        origin: TaskOrigin,
        correlationID: String? = nil,
        status: AgentTaskStatus = .queued,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.rootID = rootID
        self.origin = origin
        self.correlationID = correlationID
        self.status = status
        self.createdAt = createdAt
    }
}
