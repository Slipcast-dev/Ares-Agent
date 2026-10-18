import CryptoKit
import Darwin
import Foundation
import EcosystemRuntimeSupport

public enum LocalExportClass: String, Codable, Sendable { case aggregate, fileMetadata }
/// Экспорт и локальное чтение содержимого — независимые полномочия. Здесь нет
/// contentExport/secret: эти классы нельзя включить даже GUI-запросом.
public struct LocalAccessDraft: Codable, Equatable, Sendable {
    public var client: LocalMCPClient = .legacy
    public var roots: [UUID] = []
    public var capabilities: [String] = []
    public var dataClass: LocalExportClass = .aggregate
    public var maximumResultObjects: Int = 1000
    public var maximumResponseBytes: Int = 524_288
    public var maximumSourceObjects: Int = 1000
    public var maximumSourceBytes: Int64 = 1_073_741_824
    public var maximumRequests: Int = 1000
    public var periodSeconds: Int = 3600
    public var lifetimeSeconds: Int = 86400
    public init() {}
    public var fingerprint: String {
        var normalized = self; normalized.roots.sort { $0.uuidString < $1.uuidString }; normalized.capabilities.sort()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(normalized)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "invalid"
    }
}
public struct LocalAccessGrant: Codable, Identifiable, Sendable {
    public let id: UUID
    public let revision: Int64
    public let draft: LocalAccessDraft
    public let issuedAt: Date
    public let expiresAt: Date
    public let authorizationBasis: String
    public var revokedAt: Date?
    var windowStartedAt: Date
    var requestCount: Int
}
public struct LocalAccessPlan: Codable, Identifiable, Sendable {
    public let id: UUID
    public let draft: LocalAccessDraft
    public let fingerprint: String
    public let expiresAt: Date
    public var consumed = false
}
/// Ticket сохраняется в job сервером; payload не может назначить его себе.
/// Старый ticket не оживает после revoke → new grant с прежними настройками.
public struct LocalAccessTicket: Codable, Equatable, Sendable {
    public let grantID: UUID
    public let revision: Int64
    public let client: LocalMCPClient
    public let capability: String
}
public struct LocalAccessState: Codable, Sendable { public let grants: [LocalAccessGrant]; public let pending: [LocalAccessPlan] }
public struct LocalAccessRequest: Codable, Sendable {
    public var draft: LocalAccessDraft?
    public var planID: UUID?
    public var grantID: UUID?
    public var fingerprint: String?
    public init(draft: LocalAccessDraft? = nil, planID: UUID? = nil, grantID: UUID? = nil, fingerprint: String? = nil) { self.draft = draft; self.planID = planID; self.grantID = grantID; self.fingerprint = fingerprint }
}
public struct LocalAccessScope: Codable, Sendable {
    public struct Root: Codable, Identifiable, Sendable {
        public let id: UUID; public let name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }
    public let roots: [Root]
    public let capabilities: [String]
    public init(roots: [Root], capabilities: [String]) { self.roots = roots; self.capabilities = capabilities }
}

public actor LocalAccessPolicy {
    private struct Document: Codable { var version = 1; var grants: [LocalAccessGrant] = []; var plans: [LocalAccessPlan] = [] }
    public nonisolated let domain: String
    private let file: URL
    private var document: Document
    public init(directory: URL, domain: String) throws {
        guard ["ares", "athena"].contains(domain) else { throw LocalRuntimeFailure.invalidConfiguration }
        self.domain = domain; file = directory.appendingPathComponent("access-v1.json")
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size <= 2_097_152 else { throw LocalRuntimeFailure.invalidConfiguration }
            let loaded = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard loaded.version == 1, loaded.grants.count <= 128, loaded.plans.count <= 64 else { throw LocalRuntimeFailure.invalidConfiguration }
            for grant in loaded.grants { try Self.validate(grant.draft, domain: domain) }
            for plan in loaded.plans { try Self.validate(plan.draft, domain: domain) }
            document = loaded
        } else { document = Document() }
    }
    public nonisolated var capabilities: [String] { Self.allowedCapabilities(domain) }
    private nonisolated static func allowedCapabilities(_ domain: String) -> [String] {
        domain == "ares" ? ["events.read", "file.list_roots", "file.scan", "file.search", "file.analyze_storage", "file.compute_duplicates", "file.find_duplicates", "file.get_audit_report", "rule.list", "rule.get", "rule.validate", "rule.propose", "rule.preview", "rule.run", "rule.request_enable", "rule.disable", "rule.history"] : ["events.read", "system.get_info", "system.get_metrics", "diagnostics.run", "storage.get_overview", "diagnostics.history", "monitor.list", "monitor.get", "monitor.preview", "monitor.propose", "monitor.request_enable", "monitor.disable", "monitor.history"]
    }
    public nonisolated func requiresMetadata(_ capability: String) -> Bool {
        domain == "ares" && (capability.hasPrefix("rule.") || ["file.search", "file.compute_duplicates", "file.find_duplicates"].contains(capability))
    }
    private nonisolated func validate(_ draft: LocalAccessDraft) throws { try Self.validate(draft, domain: domain) }
    private nonisolated static func validate(_ draft: LocalAccessDraft, domain: String) throws {
        guard draft.roots.count <= 128, Set(draft.roots).count == draft.roots.count, !draft.capabilities.isEmpty,
              Set(draft.capabilities).isSubset(of: Set(allowedCapabilities(domain))), Set(draft.capabilities).count == draft.capabilities.count,
              (1...1000).contains(draft.maximumResultObjects), (1024...524_288).contains(draft.maximumResponseBytes),
              (1...1000).contains(draft.maximumSourceObjects), (1...1_073_741_824).contains(draft.maximumSourceBytes),
              (1...10_000).contains(draft.maximumRequests), (60...86_400).contains(draft.periodSeconds),
              (60...2_592_000).contains(draft.lifetimeSeconds), domain == "ares" || draft.roots.isEmpty,
              draft.dataClass == .fileMetadata || !draft.capabilities.contains(where: { domain == "ares" && ($0.hasPrefix("rule.") || ["file.search", "file.compute_duplicates", "file.find_duplicates"].contains($0)) }) else { throw LocalRuntimeFailure.invalidRequest }
    }
    private func persist(_ next: Document) throws {
        let bytes = try JSONEncoder().encode(next); guard bytes.count <= 2_097_152 else { throw LocalRuntimeFailure.busy }
        try bytes.write(to: file, options: [.atomic]); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw LocalRuntimeFailure.operationFailed }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw LocalRuntimeFailure.operationFailed }
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); guard parent >= 0 else { throw LocalRuntimeFailure.operationFailed }; defer { close(parent) }
        guard fsync(parent) == 0 else { throw LocalRuntimeFailure.operationFailed }; document = next
    }
    public func state(client: LocalMCPClient? = nil, now: Date = Date()) -> LocalAccessState {
        LocalAccessState(grants: document.grants.filter { (client == nil || $0.draft.client == client) && $0.revokedAt == nil && $0.expiresAt > now }, pending: document.plans.filter { (client == nil || $0.draft.client == client) && !$0.consumed && $0.expiresAt > now })
    }
    public func request(_ draft: LocalAccessDraft, client: LocalMCPClient?, now: Date = Date()) throws -> LocalAccessPlan {
        try validate(draft); if let client, draft.client != client { throw LocalRuntimeFailure.denied }
        let plan = LocalAccessPlan(id: UUID(), draft: draft, fingerprint: draft.fingerprint, expiresAt: now.addingTimeInterval(300))
        var next = document; next.plans.removeAll { $0.consumed || $0.expiresAt <= now || $0.draft.client == draft.client }
        guard next.plans.count < 64 else { throw LocalRuntimeFailure.busy }; next.plans.append(plan); try persist(next); return plan
    }
    public func plan(_ id: UUID, now: Date = Date()) throws -> LocalAccessPlan {
        guard let plan = document.plans.first(where: { $0.id == id }), !plan.consumed, plan.expiresAt > now else { throw LocalRuntimeFailure.staleSnapshot }; return plan
    }
    public func approve(_ id: UUID, fingerprint: String, role: LocalRole, now: Date = Date()) throws -> LocalAccessGrant {
        guard role == .gui else { throw LocalRuntimeFailure.denied }; let plan = try plan(id, now: now)
        guard plan.fingerprint == fingerprint, plan.draft.fingerprint == fingerprint else { throw LocalRuntimeFailure.staleSnapshot }
        try validate(plan.draft)
        var next = document
        // Замена политики отзывает прежнее право даже при равном draft.
        for i in next.grants.indices where next.grants[i].draft.client == plan.draft.client && next.grants[i].revokedAt == nil { next.grants[i].revokedAt = now }
        next.grants.removeAll { $0.revokedAt != nil || $0.expiresAt <= now }
        guard next.grants.count < 128 else { throw LocalRuntimeFailure.busy }
        let grant = LocalAccessGrant(id: UUID(), revision: 1, draft: plan.draft, issuedAt: now, expiresAt: now.addingTimeInterval(Double(plan.draft.lifetimeSeconds)), authorizationBasis: "localGUI", windowStartedAt: now, requestCount: 0)
        next.grants.append(grant); if let i = next.plans.firstIndex(where: { $0.id == id }) { next.plans[i].consumed = true }
        try persist(next); return grant
    }
    public func revoke(_ id: UUID, role: LocalRole, now: Date = Date()) throws -> LocalMCPClient {
        guard role == .gui else { throw LocalRuntimeFailure.denied }
        guard let i = document.grants.firstIndex(where: { $0.id == id }) else { throw LocalRuntimeFailure.invalidRequest }
        var next = document; next.grants[i].revokedAt = now
        for j in next.plans.indices where next.plans[j].draft.client == next.grants[i].draft.client { next.plans[j].consumed = true }
        try persist(next); return next.grants[i].draft.client
    }
    public func authorize(client: LocalMCPClient, capability: String, roots: [UUID] = [], now: Date = Date()) throws -> LocalAccessTicket {
        guard let i = document.grants.firstIndex(where: { $0.draft.client == client && $0.revokedAt == nil && $0.expiresAt > now }), document.grants[i].draft.capabilities.contains(capability), Set(roots).isSubset(of: Set(document.grants[i].draft.roots)) else { throw LocalRuntimeFailure.denied }
        var next = document
        if now.timeIntervalSince(next.grants[i].windowStartedAt) >= Double(next.grants[i].draft.periodSeconds) { next.grants[i].windowStartedAt = now; next.grants[i].requestCount = 0 }
        guard now >= next.grants[i].windowStartedAt, next.grants[i].requestCount < next.grants[i].draft.maximumRequests else { throw LocalRuntimeFailure.denied }
        next.grants[i].requestCount += 1; try persist(next)
        return LocalAccessTicket(grantID: next.grants[i].id, revision: next.grants[i].revision, client: client, capability: capability)
    }
    @discardableResult public func check(_ ticket: LocalAccessTicket, root: UUID? = nil, objects: Int? = nil, bytes: Int64? = nil, now: Date = Date()) throws -> LocalAccessGrant {
        guard let grant = document.grants.first(where: { $0.id == ticket.grantID }), grant.revokedAt == nil, grant.expiresAt > now,
              now >= grant.issuedAt, grant.revision == ticket.revision, grant.draft.client == ticket.client,
              grant.draft.capabilities.contains(ticket.capability), root.map({ grant.draft.roots.contains($0) }) ?? true,
              objects.map({ $0 >= 0 && $0 <= grant.draft.maximumSourceObjects }) ?? true,
              bytes.map({ $0 >= 0 && $0 <= grant.draft.maximumSourceBytes }) ?? true else { throw LocalRuntimeFailure.denied }; return grant
    }
    public func permits(client: LocalMCPClient, capability: String, roots: [UUID] = []) -> Bool {
        document.grants.contains { $0.draft.client == client && $0.revokedAt == nil && $0.expiresAt > Date() && $0.draft.capabilities.contains(capability) && Set(roots).isSubset(of: Set($0.draft.roots)) }
    }
    public func export(_ data: Data, ticket: LocalAccessTicket) throws -> Data {
        let grant = try check(ticket)
        var object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        // Внутренний ticket не является внешним полномочием и не нужен клиенту.
        // Названия локальных monitor rules могут содержать пользовательские данные.
        func stripInternal(_ item: Any) -> Any {
            if let rows = item as? [Any] { return rows.map(stripInternal) }
            guard var row = item as? [String: Any] else { return item }
            row.removeValue(forKey: "accessTicket")
            if domain == "athena", grant.draft.dataClass == .aggregate, row["name"] is String { row["name"] = "Локальная проверка" }
            return row.mapValues(stripInternal)
        }
        object = stripInternal(object)
        if domain == "ares" {
            func redact(_ item: Any) -> Any {
                if let array = item as? [Any] { return array.map(redact) }
                guard var row = item as? [String: Any] else { return item }
                // Полный путь и секреты не экспортируются ни в одном классе.
                for key in ["relativePathHint", "bookmark", "bookmarkData", "secretReference"] where row[key] != nil { row[key] = "" }
                if grant.draft.dataClass == .aggregate {
                    for key in ["records", "files", "groups", "topFiles", "largeFiles", "largestFiles", "items"] where row[key] is [Any] { row[key] = [Any]() }
                    for key in ["name", "displayName", "relativePath", "query"] where row[key] is String { row[key] = "" }
                }
                if let event = row["event"] as? String, ["textContains", "imageText", "documentType"].contains(event), row["eventValue"] != nil { row["eventValue"] = "" }
                return row.mapValues(redact)
            }
            object = redact(object)
        }
        func count(_ item: Any) -> Int {
            if let array = item as? [Any] { return array.reduce(0) { $0 + (($1 is [String: Any]) ? 1 : 0) + count($1) } }
            if let row = item as? [String: Any] { return row.values.reduce(0) { $0 + count($1) } }; return 0
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
        guard bytes.count <= grant.draft.maximumResponseBytes, count(object) <= grant.draft.maximumResultObjects else { throw LocalRuntimeFailure.invalidRequest }; return bytes
    }
}
