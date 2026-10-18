import Foundation
import XCTest
import EcosystemContracts
import EcosystemRuntimeSupport
@testable import EcosystemLocalIPC

/// Настоящие приватные SQLite/inbox/policy проверяют историю на границе ACL.
/// Closure повторяет доменную авторизацию: идентичность берётся из сохранённого
/// серверного ticket, а не из аргументов нового запроса истории.
final class LocalMCPHistoryTests: XCTestCase {
    private struct Parameters: Codable, Sendable {
        let accessTicket: LocalAccessTicket
        let privateNote: String
    }
    private struct Fixture {
        let directory: URL
        let root: UUID
        let queue: DurableTaskQueue
        let policy: LocalAccessPolicy
        let inbox: LocalEventInbox
        let history: LocalMCPHistory
    }
    private func approve(_ policy: LocalAccessPolicy, client: LocalMCPClient, root: UUID) async throws -> LocalAccessGrant {
        var draft = LocalAccessDraft(); draft.client = client; draft.roots = [root]
        draft.capabilities = ["file.scan", "file.get_audit_report", "events.read"]
        let plan = try await policy.request(draft, client: client)
        return try await policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
    }
    private func fixture() async throws -> Fixture {
        let directory = URL(fileURLWithPath: "/private/tmp/e8-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = UUID(), queue = try DurableTaskQueue(directory: directory.appendingPathComponent("queue"), agentID: .ares)
        let policy = try LocalAccessPolicy(directory: directory, domain: "ares")
        let inbox = try LocalEventInbox(directory: directory)
        _ = try await approve(policy, client: .codex, root: root)
        _ = try await approve(policy, client: .deepseekHarness, root: root)
        let history = try LocalMCPHistory(directory: directory, domain: "ares", queue: queue, policy: policy, inbox: inbox, authorizeTask: { id, client in
            guard let task = try await queue.task(id, includeResult: false) else { throw LocalRuntimeFailure.invalidRequest }
            let request = try ContractCodec.decode(TaskRequest<Parameters>.self, from: task.request)
            let ticket = request.parameters.accessTicket
            guard ticket.client == client else { throw LocalRuntimeFailure.denied }
            _ = try await policy.check(ticket, root: root)
            return task
        }, validRoots: { [root] })
        return Fixture(directory: directory, root: root, queue: queue, policy: policy, inbox: inbox, history: history)
    }
    private func submit(_ fixture: Fixture, client: LocalMCPClient = .codex, complete: Bool = false, result: Data = Data()) async throws -> DurableTask {
        let ticket = try await fixture.policy.authorize(client: client, capability: "file.scan", roots: [fixture.root])
        let request = try TaskRequest(requestID: UUID(), agentID: .ares, capabilityID: "file.scan", parameters: Parameters(accessTicket: ticket, privateNote: "/private/payroll.csv"), origin: .user, idempotencyKey: UUID().uuidString, rootID: fixture.root, createdAt: UTCTimestamp(ISO8601DateFormatter().string(from: Date())))
        let task = try await fixture.queue.accept(QueueSubmission(request: request, resources: ["history-" + UUID().uuidString.lowercased()], mutating: false))
        guard complete else { return task }
        let lease = try await fixture.queue.claim(task.id)
        try await fixture.queue.reportProgress(lease, progress: TaskProgress(phase: "private-phase", processed: NonnegativeInt(2)))
        return try await fixture.queue.finish(lease, status: .completed, result: result)
    }
    private func page(_ fixture: Fixture, operation: String = "mcp.task.list", client: LocalMCPClient = .codex, size: Int = 1, cursor: String? = nil) async throws -> [String: Any] {
        var payload: [String: Any] = ["pageSize": size]
        if let cursor { payload["cursor"] = cursor }
        let data = try await fixture.history.handle(operation: operation, payload: JSONSerialization.data(withJSONObject: payload), client: client)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func ids(_ page: [String: Any]) -> [String] { (page["items"] as? [[String: Any]] ?? []).compactMap { $0["taskId"] as? String } }
    private func invalid(_ operation: () async throws -> Void, expected: LocalRuntimeFailure = .invalidRequest) async {
        do { try await operation(); XCTFail("История приняла запрещённый запрос") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, expected) }
    }

    func testStableKeysetPagingIgnoresNewInsertAndFiltersOtherClient() async throws {
        let value = try await fixture(); defer { try? FileManager.default.removeItem(at: value.directory) }
        let oldest = try await submit(value), newest = try await submit(value)
        _ = try await submit(value, client: .deepseekHarness)
        let first = try await page(value)
        XCTAssertEqual(ids(first), [newest.id.uuidString])
        let cursor = try XCTUnwrap(first["nextCursor"] as? String)
        let inserted = try await submit(value)
        let second = try await page(value, cursor: cursor)
        XCTAssertEqual(ids(second), [oldest.id.uuidString]); XCTAssertFalse(ids(second).contains(inserted.id.uuidString))
        let harness = try await page(value, client: .deepseekHarness, size: 100)
        XCTAssertEqual(ids(harness).count, 1)
    }

    func testCursorRejectsTamperDifferentClientAndDifferentStream() async throws {
        let value = try await fixture(); defer { try? FileManager.default.removeItem(at: value.directory) }
        _ = try await submit(value); _ = try await submit(value)
        let first = try await page(value), cursor = try XCTUnwrap(first["nextCursor"] as? String)
        await invalid { _ = try await self.page(value, client: .deepseekHarness, cursor: cursor) }
        await invalid { _ = try await self.page(value, operation: "mcp.audit.list", cursor: cursor) }
        var bytes = try XCTUnwrap(Data(base64Encoded: cursor)); bytes[bytes.startIndex] ^= 1
        await invalid { _ = try await self.page(value, cursor: bytes.base64EncodedString()) }
    }

    func testRevokedGrantAndIdenticalRegrantCannotReviveTaskOrCursor() async throws {
        let value = try await fixture(); defer { try? FileManager.default.removeItem(at: value.directory) }
        let task = try await submit(value); _ = try await submit(value)
        let first = try await page(value), cursor = try XCTUnwrap(first["nextCursor"] as? String)
        let state = await value.policy.state(client: .codex), grant = try XCTUnwrap(state.grants.first { $0.revokedAt == nil })
        _ = try await value.policy.revoke(grant.id, role: .gui)
        await invalid({ _ = try await self.page(value) }, expected: .denied)
        _ = try await approve(value.policy, client: .codex, root: value.root)
        await invalid { _ = try await self.page(value, cursor: cursor) }
        let fresh = try await page(value, size: 100); XCTAssertTrue(ids(fresh).isEmpty)
        await invalid({ _ = try await value.history.handle(operation: "mcp.task.get", payload: LocalWire.encode(LocalTaskID(task.id)), client: .codex) }, expected: .denied)
    }

    func testTaskMetadataAndSQLProjectionExcludeHugeResultPrivateRequestAndLease() async throws {
        let value = try await fixture(); defer { try? FileManager.default.removeItem(at: value.directory) }
        let result = Data(repeating: 65, count: 1_048_576)
        let task = try await submit(value, complete: true, result: result)
        let full = try await value.queue.task(task.id), projected = try await value.queue.task(task.id, includeResult: false)
        XCTAssertEqual(full?.result, result); XCTAssertNil(projected?.result); XCTAssertEqual(projected?.id, task.id)
        let data = try await value.history.handle(operation: "mcp.task.get", payload: LocalWire.encode(LocalTaskID(task.id)), client: .codex)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["taskId"] as? String, task.id.uuidString); XCTAssertEqual(object["status"] as? String, "completed")
        for key in ["result", "request", "resources", "lease", "idempotencyKey", "accessTicket", "fingerprint"] { XCTAssertNil(object[key]) }
        XCTAssertLessThan(data.count, 1024)
        let text = String(decoding: data, as: UTF8.self); XCTAssertFalse(text.contains("payroll")); XCTAssertFalse(text.contains("private-phase"))
        await invalid({ _ = try await value.history.handle(operation: "mcp.task.get", payload: LocalWire.encode(LocalTaskID(task.id)), client: .deepseekHarness) }, expected: .denied)
    }

    func testEventHistoryFiltersCapabilityAndGrantRootAndRedactsSummary() async throws {
        let value = try await fixture(); defer { try? FileManager.default.removeItem(at: value.directory) }
        let visible = UUID()
        _ = try await value.inbox.append(id: visible, kind: "finished", capability: "file.scan", rootIDs: [value.root], summary: "Private payroll.csv")
        _ = try await value.inbox.append(id: UUID(), kind: "outside", capability: "file.scan", rootIDs: [UUID()], summary: "Private outside")
        _ = try await value.inbox.append(id: UUID(), kind: "forbidden", capability: "rule.run", rootIDs: [value.root], summary: "Private action")
        let output = try await page(value, operation: "mcp.event.list", size: 100)
        let items = try XCTUnwrap(output["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1); XCTAssertEqual(items.first?["eventId"] as? String, visible.uuidString)
        XCTAssertEqual(items.first?["summary"] as? String, "Локальное событие"); XCTAssertNil(items.first?["rootIDs"])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self).contains("Private"))
    }

    func testEventOSRootRevocationAndAuditUseSafeProjection() async throws {
        let value = try await fixture(); defer { try? FileManager.default.removeItem(at: value.directory) }
        _ = try await value.inbox.append(id: UUID(), kind: "finished", capability: "file.scan", rootIDs: [value.root], summary: "Private name")
        let revoked = try LocalMCPHistory(directory: value.directory, domain: "ares", queue: value.queue, policy: value.policy, inbox: value.inbox, authorizeTask: { _, _ in throw LocalRuntimeFailure.denied }, validRoots: { [] })
        let data = try await revoked.handle(operation: "mcp.event.list", payload: Data("{}".utf8), client: .codex)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); XCTAssertTrue((output["items"] as? [Any] ?? [1]).isEmpty)
        let own = try await submit(value); _ = try await submit(value, client: .deepseekHarness)
        let audit = try await page(value, operation: "mcp.audit.list", size: 100)
        XCTAssertEqual(ids(audit), [own.id.uuidString]); XCTAssertNil((audit["items"] as? [[String: Any]])?.first?["request"])
    }

    func testScanBudgetReturnsCursorAcrossFiveHundredForeignRows() async throws {
        let value = try await fixture(); defer { try? FileManager.default.removeItem(at: value.directory) }
        let own = try await submit(value, complete: true)
        // Завершаем записи сразу: проверяется история >500 строк без нарушения
        // отдельного лимита очереди в 256 незавершённых задач.
        for _ in 0..<501 { _ = try await submit(value, client: .deepseekHarness, complete: true) }
        let first = try await page(value)
        XCTAssertTrue(ids(first).isEmpty)
        let cursor = try XCTUnwrap(first["nextCursor"] as? String)
        let second = try await page(value, cursor: cursor)
        XCTAssertEqual(ids(second), [own.id.uuidString])
    }


    func testAuditFiltersAndCursorAreBoundToUnchangedFilter() async throws {
        let value = try await fixture(); defer { try? FileManager.default.removeItem(at: value.directory) }
        let first = try await submit(value, complete: true), second = try await submit(value, complete: true)
        let queued = try await submit(value)
        func audit(_ arguments: [String: Any]) async throws -> [String: Any] {
            let data = try await value.history.handle(operation: "mcp.audit.list", payload: JSONSerialization.data(withJSONObject: arguments), client: .codex)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let completed = try await audit(["status": "completed", "capability": "file.scan", "pageSize": 1])
        XCTAssertEqual(ids(completed), [second.id.uuidString])
        let cursor = try XCTUnwrap(completed["nextCursor"] as? String)
        let continued = try await audit(["status": "completed", "capability": "file.scan", "pageSize": 1, "cursor": cursor])
        XCTAssertEqual(ids(continued), [first.id.uuidString])
        await invalid { _ = try await audit(["status": "queued", "capability": "file.scan", "cursor": cursor]) }
        await invalid { _ = try await audit(["status": "completed", "capability": "file.search", "cursor": cursor]) }
        let waiting = try await audit(["status": "queued", "pageSize": 100])
        XCTAssertEqual(ids(waiting), [queued.id.uuidString])
        let otherCapability = try await audit(["capability": "file.search"])
        XCTAssertTrue(ids(otherCapability).isEmpty)
        let future = try await audit(["since": "2099-01-01T00:00:00Z"])
        XCTAssertTrue(ids(future).isEmpty)
        let past = try await audit(["since": "2000-01-01T00:00:00Z", "pageSize": 100])
        XCTAssertEqual(Set(ids(past)), Set([first.id.uuidString, second.id.uuidString, queued.id.uuidString]))
    }

    func testInvalidPageSizeUnknownKeysAndTaskIDAreRejected() async throws {
        let value = try await fixture(); defer { try? FileManager.default.removeItem(at: value.directory) }
        for payload in [#"{"pageSize":0}"#, #"{"pageSize":101}"#, #"{"approved":true}"#] {
            await invalid { _ = try await value.history.handle(operation: "mcp.task.list", payload: Data(payload.utf8), client: .codex) }
        }
        await invalid { _ = try await value.history.handle(operation: "mcp.task.get", payload: Data(#"{"id":"bad"}"#.utf8), client: .codex) }
    }
}
