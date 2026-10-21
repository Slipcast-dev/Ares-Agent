import Foundation
import EcosystemContracts

/// GUI получает только идентификатор и состояние: пути, параметры и результаты
/// задач не нужны экрану эксплуатации и не попадают в диагностический экспорт.
public struct LocalOperationalTask: Codable, Identifiable, Sendable {
    public let id: UUID
    public let status: TaskStatus
    public init(id: UUID, status: TaskStatus) { self.id = id; self.status = status }
}
