import Foundation
import EcosystemLocalIPC

/// Одна ограниченная payload-модель для внутренних CRUD. Сервер дополнительно
/// проверяет разрешённые поля отдельно для каждой операции и роль соединения.
struct RepositoryPayload: Codable, Sendable {
    var id: UUID?
    var rootID: UUID?
    var query: String?
    var limit: Int?
    var profile: AIProviderProfile?
    var object: Data?
    var objectID: String?
    var table: SQLiteFileRepository.RuleTable?
}
public actor RemoteFileRepository: FileRepository {
    // Снимки доступны только через очередь задач, без обхода её ACL и проверки свежести.
    public func publishSnapshot(records: [FileRecord], summary: ScanSummary) async throws -> FileIndexSnapshot { throw AresFileFailure.snapshotRequired }
    public func currentSnapshot(rootID: UUID) async throws -> FileIndexSnapshot? { throw AresFileFailure.snapshotRequired }
    public func publishHashes(rootID: UUID, snapshotID: UUID, hashes: [UUID: String]) async throws -> FileIndexSnapshot { throw AresFileFailure.snapshotRequired }
    private let client: Result<LocalRPCClient, Error>
    public init(client: Result<LocalRPCClient, Error>) { self.client = client }
    private func read<T: Decodable & Sendable>(_ operation: String, _ payload: RepositoryPayload = RepositoryPayload(), as type: T.Type = T.self) async throws -> T {
        try await client.get().call(operation, payload, as: type)
    }
    public func fetchRoots() async throws -> [AuthorizedRoot] { try await read("repo.roots") }
    public func root(withID id: UUID) async throws -> AuthorizedRoot? { try await read("repo.root", RepositoryPayload(id: id)) }
    public func removeRoot(withID id: UUID) async throws { let _: LocalEmpty = try await read("repo.removeRoot", RepositoryPayload(id: id)) }
    public func indexedFileCount(forRootID id: UUID) async throws -> Int { try await read("repo.count", RepositoryPayload(rootID: id)) }
    public func records(forRootID id: UUID) async throws -> [FileRecord] { try await read("repo.records", RepositoryPayload(rootID: id)) }
    public func searchRecords(forRootID id: UUID, query: String, limit: Int) async throws -> [FileRecord] {
        try await read("repo.search", RepositoryPayload(rootID: id, query: query, limit: limit))
    }
    public func recentEvents(limit: Int) async throws -> [AuditEvent] { try await read("repo.events", RepositoryPayload(limit: limit)) }
    public func fetchProviderProfiles() async throws -> [AIProviderProfile] { try await read("repo.profiles") }
    public func save(profile: AIProviderProfile) async throws { let _: LocalEmpty = try await read("repo.saveProfile", RepositoryPayload(profile: profile)) }
    public func task(withID id: UUID) async throws -> AgentTask? { try await read("repo.task", RepositoryPayload(id: id)) }
    public func recentTasks(limit: Int) async throws -> [AgentTask] { try await read("repo.tasks", RepositoryPayload(limit: limit)) }
    public func ruleObjects<T: Decodable & Sendable>(_ type: T.Type, table: SQLiteFileRepository.RuleTable) async throws -> [T] {
        try await read("repo.ruleObjects", RepositoryPayload(table: table))
    }
    public func ruleObject<T: Decodable & Sendable>(_ type: T.Type, id: String, table: SQLiteFileRepository.RuleTable) async throws -> T? {
        try await read("repo.ruleObject", RepositoryPayload(objectID: id, table: table))
    }
    public func saveRuleObject<T: Encodable & Sendable>(_ object: T, id: String, table: SQLiteFileRepository.RuleTable) async throws {
        guard table == .rules else { throw LocalRuntimeFailure.denied }
        let _: LocalEmpty = try await read("repo.saveRule", RepositoryPayload(object: try LocalWire.encode(object), objectID: id, table: table))
    }
    public func deleteRule(id: UUID) async throws { let _: LocalEmpty = try await read("repo.deleteRule", RepositoryPayload(id: id)) }
    // Эти записи выполняют только доменные handlers в runtime. Proxy не даёт
    // интерфейсу обходить очередь или читать persistent bookmark из SQLite.
    public func save(root: AuthorizedRoot, bookmarkData: Data) async throws { throw LocalRuntimeFailure.denied }
    public func bookmarkData(forRootID id: UUID) async throws -> Data? { throw LocalRuntimeFailure.denied }
    public func replaceIndex(records: [FileRecord], forRootID rootID: UUID) async throws { throw LocalRuntimeFailure.denied }
    public func updateContentHash(_ hash: String, forRecordID id: UUID) async throws { throw LocalRuntimeFailure.denied }
    public func upsertRuleFile(_ file: RuleFileSnapshot, rootID: UUID) async throws { throw LocalRuntimeFailure.denied }
    public func record(_ event: AuditEvent) async throws { throw LocalRuntimeFailure.denied }
    public func save(task: AgentTask) async throws { throw LocalRuntimeFailure.denied }
}
