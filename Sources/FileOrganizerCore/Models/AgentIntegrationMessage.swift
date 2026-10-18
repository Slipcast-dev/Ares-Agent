import Foundation

/// Минимальный контракт обмена между независимыми агентами. Он не содержит
/// файловых путей, содержимого или секретов: для первого релиза достаточно
/// корреляции рекомендации и её классификации.
public struct AgentIntegrationMessage: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sourceAgentID: String
    public let targetAgentID: String
    public let taskID: UUID
    public let correlationID: String
    public let createdAt: Date
    public let payloadClassification: PayloadClassification

    public init(schemaVersion: Int = 1, sourceAgentID: String, targetAgentID: String, taskID: UUID, correlationID: String, createdAt: Date = Date(), payloadClassification: PayloadClassification) throws {
        guard schemaVersion == 1, !sourceAgentID.isEmpty, !targetAgentID.isEmpty, !correlationID.isEmpty else { throw AgentIntegrationError.invalidEnvelope }
        self.schemaVersion = schemaVersion; self.sourceAgentID = sourceAgentID; self.targetAgentID = targetAgentID
        self.taskID = taskID; self.correlationID = correlationID; self.createdAt = createdAt; self.payloadClassification = payloadClassification
    }
}

/// Разрешены только агрегированные рекомендации. Новые классы должны проходить
/// отдельный security review до включения в межагентный обмен.
public enum PayloadClassification: String, Codable, Sendable { case storageRecommendation, downloadsRecommendation, projectInventoryMetadata }
public enum AgentIntegrationError: Error, LocalizedError, Sendable { case invalidEnvelope; public var errorDescription: String? { "Некорректный безопасный конверт межагентного сообщения." } }
