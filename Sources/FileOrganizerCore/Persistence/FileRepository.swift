import Foundation

/// В локальном режиме реализация является XPC-клиентом. Только runtime создаёт
/// SQLiteFileRepository: интерфейс и worker не получают второго writer.
public protocol FileRepository: AuthorizedRootStoring, AuditRecording {
    func save(root: AuthorizedRoot, bookmarkData: Data) async throws
    func fetchRoots() async throws -> [AuthorizedRoot]
    func root(withID id: UUID) async throws -> AuthorizedRoot?
    func removeRoot(withID id: UUID) async throws
    func bookmarkData(forRootID id: UUID) async throws -> Data?
    func replaceIndex(records: [FileRecord], forRootID rootID: UUID) async throws
    func publishSnapshot(records: [FileRecord], summary: ScanSummary) async throws -> FileIndexSnapshot
    func currentSnapshot(rootID: UUID) async throws -> FileIndexSnapshot?
    func publishHashes(rootID: UUID, snapshotID: UUID, hashes: [UUID: String]) async throws -> FileIndexSnapshot
    func indexedFileCount(forRootID rootID: UUID) async throws -> Int
    func records(forRootID rootID: UUID) async throws -> [FileRecord]
    func updateContentHash(_ hash: String, forRecordID recordID: UUID) async throws
    func upsertRuleFile(_ file: RuleFileSnapshot, rootID: UUID) async throws
    func record(_ event: AuditEvent) async throws
    func recentEvents(limit: Int) async throws -> [AuditEvent]
    func searchRecords(forRootID rootID: UUID, query: String, limit: Int) async throws -> [FileRecord]
    func save(profile: AIProviderProfile) async throws
    func fetchProviderProfiles() async throws -> [AIProviderProfile]
    func save(task: AgentTask) async throws
    func task(withID id: UUID) async throws -> AgentTask?
    func recentTasks(limit: Int) async throws -> [AgentTask]
    func saveRuleObject<T: Encodable & Sendable>(_ object: T, id: String, table: SQLiteFileRepository.RuleTable) async throws
    func ruleObjects<T: Decodable & Sendable>(_ type: T.Type, table: SQLiteFileRepository.RuleTable) async throws -> [T]
    func ruleObject<T: Decodable & Sendable>(_ type: T.Type, id: String, table: SQLiteFileRepository.RuleTable) async throws -> T?
    func ruleHistoryPage(ruleID: UUID, runID: UUID?, offset: Int, cursor: String?) async throws -> RuleHistoryPage
    func deleteRule(id: UUID) async throws
}
public extension FileRepository {
    func recentTasks() async throws -> [AgentTask] { try await recentTasks(limit: 30) }
    func searchRecords(forRootID id: UUID, query: String) async throws -> [FileRecord] {
        try await searchRecords(forRootID: id, query: query, limit: 100)
    }
}

/// Страница содержит только публичные поля истории, без message/receipt payload.
public struct RuleHistoryItem: Codable, Sendable {
    public let runID: UUID
    public let taskID: UUID?
    public let runStatus: String
    public let createdAt: Date
    public let actionID: UUID?
    public let kind: RuleActionKind?
    public let relativePath: String
    public let status: String
}
public struct RuleHistoryPage: Codable, Sendable {
    public let items: [RuleHistoryItem]
    public let nextOffset: Int?
    public let nextCursor: String?
    public let runTaskID: UUID?
}
public enum RuleHistoryFailure: Error, Sendable { case invalidRequest, missingRun }
