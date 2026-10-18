import Foundation
import EcosystemLocalIPC

struct AresJob: Codable, Sendable {
    var ruleID: UUID?
    var planID: UUID?
    var rootID: UUID?
    var snapshotID: UUID?
    var query: String?
    var cursor: String?
    var pageSize: Int?
    var rule: AutomationRule?
    var paths: [String]?
    var appLaunch: Bool?
    var origin: TaskOrigin?
    var correlationID: String?
    var requesterRole: LocalRole?
    var requesterClientID: LocalMCPClient?
    var accessTicket: LocalAccessTicket?
    /// Токен lease не сохраняется в job: обновление lease не меняет смысл повтора.
    var sourceEventID: UUID?
}
struct AresSubmission: Codable, Sendable {
    let capability: String
    var job: AresJob
    let key: String
    var deadlineAt: String? = nil
}
struct RootTransfer: Codable, Sendable { let bookmark: Data }
public struct DuplicateAnalysis: Codable, Sendable {
    public var nextCursor: String? = nil
    public var snapshot: FileSnapshotHeader? = nil
    public var hashesAvailable: Bool? = nil
    public var totalDuplicateFileCount: Int? = nil
    public var totalGroupCount: Int? = nil
    public let groups: [DuplicateGroup]
    public let largeFiles: [FileRecord]
}
