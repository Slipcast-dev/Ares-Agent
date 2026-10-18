import CryptoKit
import Darwin
import Foundation
import EcosystemContracts
import EcosystemRuntimeSupport

/// Общая история возвращает только безопасные метаданные. Полные результаты
/// остаются в прежнем task.get и проходят доменную проверку экспорта отдельно.
public actor LocalMCPHistory {
    public typealias TaskAuthorization = @Sendable (UUID, LocalMCPClient) async throws -> DurableTask
    private struct Cursor: Codable {
        let domain: String
        let stream: String
        let client: LocalMCPClient
        let grant: UUID
        let revision: Int64
        let before: String
        let filter: String
        let expires: Date
    }
    private struct Page: Decodable { var pageSize: Int?; var cursor: String?; var capability: String?; var status: String?; var since: String? }
    private struct Identity: Decodable { let id: UUID }
    private let domain: String
    private let queue: DurableTaskQueue
    private let policy: LocalAccessPolicy
    private let inbox: LocalEventInbox?
    private let authorize: TaskAuthorization
    private let roots: @Sendable () async throws -> Set<UUID>
    private let key: SymmetricKey

    public init(directory: URL, domain: String, queue: DurableTaskQueue, policy: LocalAccessPolicy,
                inbox: LocalEventInbox?, authorizeTask: @escaping TaskAuthorization,
                validRoots: @escaping @Sendable () async throws -> Set<UUID> = { [] }) throws {
        guard ["ares", "athena"].contains(domain), policy.domain == domain else { throw LocalRuntimeFailure.invalidConfiguration }
        self.domain = domain; self.queue = queue; self.policy = policy; self.inbox = inbox
        authorize = authorizeTask; roots = validRoots; key = try Self.loadKey(directory)
    }

    public func handle(operation: String, payload: Data, client: LocalMCPClient) async throws -> Data {
        guard ["mcp.task.get", "mcp.task.list", "mcp.audit.list", "mcp.event.list"].contains(operation) else { throw LocalRuntimeFailure.invalidRequest }
        if operation == "mcp.task.get" {
            let id = try LocalWire.decode(Identity.self, payload, keys: ["id"]).id
            let task = try await authorize(id, client)
            return try JSONSerialization.data(withJSONObject: metadata(task), options: [.sortedKeys])
        }
        let page = try LocalWire.decode(Page.self, payload, keys: operation == "mcp.audit.list" ? ["pageSize", "cursor", "capability", "status", "since"] : ["pageSize", "cursor"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let since = page.since.flatMap { formatter.date(from: $0) }
        formatter.formatOptions = [.withInternetDateTime]
        let cutoff = since ?? page.since.flatMap { formatter.date(from: $0) }
        guard page.since == nil || cutoff != nil,
              page.status == nil || TaskStatus.allCases.map(\.rawValue).contains(page.status!),
              page.capability == nil || (!page.capability!.isEmpty && page.capability!.utf8.count <= 128) else { throw LocalRuntimeFailure.invalidRequest }
        // Длина компонентов ограничена схемой; JSON без двусмысленного склеивания.
        let filter = String(decoding: try JSONSerialization.data(withJSONObject: [page.capability ?? "", page.status ?? "", page.since ?? ""]), as: UTF8.self)
        let size = page.pageSize ?? 50
        guard (1...100).contains(size) else { throw LocalRuntimeFailure.invalidRequest }
        // task.list не требует отдельного дополнительного capability: каждая
        // строка повторно проверяется собственным ticket исходного задания.
        // Для привязки cursor нужен действующий grant, но не новая выдача права.
        let capability: String?
        switch operation {
        case "mcp.event.list": capability = "events.read"
        case "mcp.audit.list": capability = domain == "ares" ? "file.get_audit_report" : "diagnostics.history"
        default: capability = nil
        }
        let grant: LocalAccessGrant
        var ticket: LocalAccessTicket?
        if let capability {
            let value = try await policy.authorize(client: client, capability: capability)
            ticket = value; grant = try await policy.check(value)
        } else {
            // status фильтрует по доверенному client, без rate-consuming authorize.
            let snapshot = await policy.state(client: client)
            guard let current = snapshot.grants.first(where: { $0.revokedAt == nil && $0.expiresAt > Date() }) else { throw LocalRuntimeFailure.denied }
            grant = current
        }
        let before = try page.cursor.map { try decode($0, operation: operation, client: client, grant: grant, filter: filter) }
        var items: [[String: Any]] = []
        var usedRoots = Set<UUID>()
        var nextPosition: String?
        if operation == "mcp.event.list" {
            guard let inbox else { throw LocalRuntimeFailure.denied }
            let valid = try await roots()
            let all = try await inbox.events().sorted { Self.eventKey($0) > Self.eventKey($1) }
                .filter { before == nil || Self.eventKey($0) < before! }
            let batch = Array(all.prefix(500))
            for (index, event) in batch.enumerated() {
                let position = Self.eventKey(event)
                let permitted = grant.draft.capabilities.contains(event.capability)
                    && Set(event.rootIDs).isSubset(of: Set(grant.draft.roots))
                    && Set(event.rootIDs).isSubset(of: valid)
                if permitted {
                    usedRoots.formUnion(event.rootIDs)
                    items.append(["eventId": event.id.uuidString, "kind": event.kind,
                                  "capability": event.capability, "createdAt": Self.date(event.createdAt),
                                  "summary": "Локальное событие"])
                }
                if items.count == size || index == batch.count - 1 {
                    if index < batch.count - 1 || all.count > batch.count { nextPosition = position }
                    break
                }
            }
        } else {
            let number = try before.map { value -> Int64 in
                guard let result = Int64(value), result > 0 else { throw LocalRuntimeFailure.invalidRequest }; return result
            }
            let batch = try await queue.history(before: number, limit: 500)
            for (index, row) in batch.enumerated() {
                do {
                    let task = try await authorize(row.id, client)
                    if (page.capability == nil || task.capabilityID == page.capability)
                        && (page.status == nil || task.status.rawValue == page.status)
                        && (cutoff == nil || task.createdAt >= cutoff!) { items.append(metadata(task)) }
                }
                catch let failure as LocalRuntimeFailure where failure == .denied || failure == .invalidRequest { /* Чужая или уже удалённая строка. */ }
                if items.count == size || index == batch.count - 1 {
                    // При полном scan-batch возможна пустая следующая страница;
                    // позиция сохраняется и чужие строки не раскрываются.
                    if index < batch.count - 1 || batch.count == 500 { nextPosition = String(row.position) }
                    break
                }
            }
        }
        if operation == "mcp.event.list", !usedRoots.isSubset(of: try await roots()) { throw LocalRuntimeFailure.denied }
        // Повторная проверка после actor hops закрывает окно отзыва grant.
        if let ticket { _ = try await policy.check(ticket) }
        else {
            let current = await policy.state(client: client)
            guard current.grants.contains(where: { $0.id == grant.id && $0.revision == grant.revision && $0.revokedAt == nil && $0.expiresAt > Date() }) else { throw LocalRuntimeFailure.denied }
        }
        var result: [String: Any] = ["items": items, "nextCursor": NSNull()]
        if let nextPosition { result["nextCursor"] = try encode(position: nextPosition, operation: operation, client: client, grant: grant, filter: filter) }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        // Применяем object/byte quotas и при отдельном task-list без capability.
        guard items.count <= grant.draft.maximumResultObjects, data.count <= grant.draft.maximumResponseBytes else { throw LocalRuntimeFailure.invalidRequest }
        return data
    }

    private func metadata(_ task: DurableTask) -> [String: Any] {
        var result: [String: Any] = ["taskId": task.id.uuidString, "status": task.status.rawValue,
            "capability": task.capabilityID, "createdAt": Self.date(task.createdAt), "revision": task.revision,
            "cancellationTooLate": task.cancellationTooLate]
        if let finished = task.finishedAt { result["finishedAt"] = Self.date(finished) }
        if let error = task.errorCode { result["errorCode"] = error.rawValue }
        // Progress summary может содержать имя файла; экспортируется только доля.
        if let progress = task.progress, let value = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? [String: Any] {
            var safe: [String: Any] = [:]
            for key in ["processed", "total"] where value[key] is NSNumber { safe[key] = value[key] }
            if !safe.isEmpty { result["progress"] = safe }
        }
        return result
    }
    private static func date(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    private static func eventKey(_ value: LocalInboxEvent) -> String {
        String(format: "%020.6f", value.createdAt.timeIntervalSince1970) + ":" + value.id.uuidString
    }
    private func encode(position: String, operation: String, client: LocalMCPClient, grant: LocalAccessGrant, filter: String) throws -> String {
        let value = Cursor(domain: domain, stream: operation, client: client, grant: grant.id,
                           revision: grant.revision, before: position, filter: filter, expires: Date().addingTimeInterval(300))
        guard let data = try AES.GCM.seal(JSONEncoder().encode(value), using: key).combined else { throw LocalRuntimeFailure.operationFailed }
        return data.base64EncodedString()
    }
    private func decode(_ text: String, operation: String, client: LocalMCPClient, grant: LocalAccessGrant, filter: String) throws -> String {
        do {
            guard text.utf8.count <= 2048, let bytes = Data(base64Encoded: text) else { throw LocalRuntimeFailure.invalidRequest }
            let data = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key)
            let value = try JSONDecoder().decode(Cursor.self, from: data)
            guard value.domain == domain, value.stream == operation, value.client == client,
                  value.grant == grant.id, value.revision == grant.revision, value.filter == filter,
                  value.expires > Date(), value.expires <= Date().addingTimeInterval(301) else { throw LocalRuntimeFailure.invalidRequest }
            return value.before
        } catch { throw LocalRuntimeFailure.invalidRequest }
    }
    private static func loadKey(_ directory: URL) throws -> SymmetricKey {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }; defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        let name = "mcp-history-key-v1.bin"
        var descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { throw LocalRuntimeFailure.invalidConfiguration }
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
            defer { close(descriptor) }
            let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard count == 32, fsync(descriptor) == 0, fsync(parent) == 0 else { throw LocalRuntimeFailure.operationFailed }
            return key
        }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1, info.st_size == 32 else { throw LocalRuntimeFailure.invalidConfiguration }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard Darwin.read(descriptor, &bytes, 32) == 32 else { throw LocalRuntimeFailure.invalidConfiguration }
        return SymmetricKey(data: bytes)
    }
}
