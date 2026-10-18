import XCTest
import EcosystemContracts
import EcosystemRuntimeSupport
@testable import EcosystemLocalIPC

final class LocalAccessPolicyTests: XCTestCase {
    func directory() throws -> URL {
        let path = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("e6-policy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return path
    }
    func draft(_ client: LocalMCPClient = .codex) -> LocalAccessDraft {
        var result = LocalAccessDraft(); result.client = client; result.capabilities = ["system.get_metrics"]; return result
    }
    func grant(_ policy: LocalAccessPolicy, _ draft: LocalAccessDraft, now: Date = Date()) async throws -> LocalAccessGrant {
        let plan = try await policy.request(draft, client: draft.client, now: now)
        return try await policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui, now: now)
    }
    func denied(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Missing denial") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
    }
    func testDefaultDenyAndClientSpoofing() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "athena")
        await denied { _ = try await policy.authorize(client: .codex, capability: "system.get_metrics") }
        _ = try await grant(policy, draft())
        _ = try await policy.authorize(client: .codex, capability: "system.get_metrics")
        await denied { _ = try await policy.authorize(client: .deepseekHarness, capability: "system.get_metrics") }
        await denied { _ = try await policy.request(self.draft(.deepseekHarness), client: .codex) }
    }
    func testGUIOnlyApprovalExpiryFingerprintAndSingleUse() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "athena"); let now = Date()
        let plan = try await policy.request(draft(), client: .codex, now: now)
        await denied { _ = try await policy.approve(plan.id, fingerprint: plan.fingerprint, role: .mcp) }
        for (fingerprint, time) in [("forged", now), (plan.fingerprint, now.addingTimeInterval(301))] {
            do { _ = try await policy.approve(plan.id, fingerprint: fingerprint, role: .gui, now: time); XCTFail("Invalid plan") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .staleSnapshot) }
        }
        _ = try await policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui, now: now)
        do { _ = try await policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui, now: now); XCTFail("Spent plan") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .staleSnapshot) }
    }
    func testRevokeAndSameRegrantNeverReviveTicketAcrossReload() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "athena")
        let first = try await grant(policy, draft()); let ticket = try await policy.authorize(client: .codex, capability: "system.get_metrics")
        _ = try await policy.revoke(first.id, role: .gui); _ = try await grant(policy, draft())
        let loaded = try LocalAccessPolicy(directory: path, domain: "athena")
        await denied { _ = try await loaded.check(ticket) }
        _ = try await loaded.authorize(client: .codex, capability: "system.get_metrics")
    }
    func testRateQuotaPeriodAndExpiryCheckpointsDoNotConsumeRequests() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "athena"); let now = Date()
        var input = draft(); input.maximumRequests = 1; input.periodSeconds = 60; input.lifetimeSeconds = 120
        _ = try await grant(policy, input, now: now)
        let ticket = try await policy.authorize(client: .codex, capability: "system.get_metrics", now: now)
        for _ in 0..<3 { _ = try await policy.check(ticket, now: now) }
        await denied { _ = try await policy.authorize(client: .codex, capability: "system.get_metrics", now: now) }
        _ = try await policy.authorize(client: .codex, capability: "system.get_metrics", now: now.addingTimeInterval(61))
        await denied { _ = try await policy.check(ticket, now: now.addingTimeInterval(121)) }
    }
    func testRootCapabilityAndSourceBudgetCannotExpand() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "ares"); let root = UUID()
        var input = LocalAccessDraft(); input.client = .codex; input.roots = [root]; input.capabilities = ["file.scan"]; input.maximumSourceObjects = 2; input.maximumSourceBytes = 10
        _ = try await grant(policy, input); let ticket = try await policy.authorize(client: .codex, capability: "file.scan", roots: [root])
        _ = try await policy.check(ticket, root: root, objects: 2, bytes: 10)
        await denied { _ = try await policy.check(ticket, root: UUID()) }
        await denied { _ = try await policy.check(ticket, objects: 3) }
        await denied { _ = try await policy.check(ticket, bytes: 11) }
        await denied { _ = try await policy.authorize(client: .codex, capability: "rule.run") }
    }
    func testAggregateAndMetadataProjectionNeverExportAbsoluteHint() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "ares")
        var input = LocalAccessDraft(); input.client = .codex; input.capabilities = ["file.analyze_storage"]
        _ = try await grant(policy, input); let aggregate = try await policy.authorize(client: .codex, capability: "file.analyze_storage")
        let data = Data("{\"records\":[{\"relativePath\":\"private.txt\"}],\"displayName\":\"Private\",\"relativePathHint\":\"/private/full/path\"}".utf8)
        let stripped = String(decoding: try await policy.export(data, ticket: aggregate), as: UTF8.self)
        XCTAssertFalse(stripped.contains("private.txt")); XCTAssertFalse(stripped.contains("/private/full/path")); XCTAssertFalse(stripped.contains("Private"))
        input.dataClass = .fileMetadata; _ = try await grant(policy, input)
        let ticket = try await policy.authorize(client: .codex, capability: "file.analyze_storage")
        let allowed = String(decoding: try await policy.export(data, ticket: ticket), as: UTF8.self)
        XCTAssertTrue(allowed.contains("private.txt")); XCTAssertFalse(allowed.contains("/private/full/path"))
    }
    func testMetadataRequiresOwnClassAndExportHasObjectAndByteLimits() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "ares")
        var input = LocalAccessDraft(); input.capabilities = ["file.search"]
        do { _ = try await policy.request(input, client: .legacy); XCTFail("Metadata under aggregate") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .invalidRequest) }
        input.dataClass = .fileMetadata; input.maximumResultObjects = 1; input.maximumResponseBytes = 1024
        _ = try await grant(policy, input); let ticket = try await policy.authorize(client: .legacy, capability: "file.search")
        for data in [Data("{\"records\":[{},{}]}".utf8), try JSONSerialization.data(withJSONObject: ["value": String(repeating: "x", count: 1025)])] {
            do { _ = try await policy.export(data, ticket: ticket); XCTFail("Export quota") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .invalidRequest) }
        }
    }
    func testOnePendingPlanPerClientAndReplacementInvalidatesOldPreview() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "athena")
        let first = try await policy.request(draft(), client: .codex)
        for _ in 0..<70 { _ = try await policy.request(draft(), client: .codex) }
        let state = await policy.state(); XCTAssertEqual(state.pending.count, 1)
        do { _ = try await policy.approve(first.id, fingerprint: first.fingerprint, role: .gui); XCTFail("Replaced plan approved") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .staleSnapshot) }
        _ = try await policy.request(draft(.deepseekHarness), client: .deepseekHarness)
        let independent = await policy.state(); XCTAssertEqual(independent.pending.count, 2)
    }
    func testInteractiveMCPInputRepliesBeforeWriterClosesPipe() {
        let pipe = Pipe(), received = expectation(description: "Frame before EOF")
        let completed = DispatchSemaphore(value: 0)
        let stream = pipe.fileHandleForReading
        DispatchQueue.global().async {
            let input = BoundedMCPInput(stream: stream)
            guard let frame = input.next(), case .success(let data) = frame else { XCTFail("Missing interactive frame"); received.fulfill(); completed.signal(); return }
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "{}")
            received.fulfill(); completed.signal()
        }
        pipe.fileHandleForWriting.write(Data("{}\n".utf8))
        wait(for: [received], timeout: 1)
        pipe.fileHandleForWriting.closeFile()
        _ = completed.wait(timeout: .now() + 1)
        pipe.fileHandleForReading.closeFile()
    }
    func testBoundedMCPInputDiscardsOversizedLineAndPreservesFollowingUTF8() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let file = path.appendingPathComponent("input")
        try Data((String(repeating: "x", count: 1000) + "\n{\"value\":\"текст\"}\n{}").utf8).write(to: file)
        let stream = try FileHandle(forReadingFrom: file); defer { try? stream.close() }
        let input = BoundedMCPInput(stream: stream, maximumBytes: 64)
        if case .failure(.oversized)? = input.next() {} else { XCTFail("Size not limited") }
        guard case .success(let next)? = input.next() else { return XCTFail("Following line lost") }
        XCTAssertEqual(String(decoding: next, as: UTF8.self), "{\"value\":\"текст\"}")
        guard case .success(let last)? = input.next() else { return XCTFail("EOF fragment lost") }
        XCTAssertEqual(String(decoding: last, as: UTF8.self), "{}"); XCTAssertNil(input.next())
    }
    func testAthenaAggregateHidesLocalMonitorNamesAndInternalTicket() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "athena")
        var input = draft(); input.capabilities = ["monitor.get"]
        _ = try await grant(policy, input); let ticket = try await policy.authorize(client: .codex, capability: "monitor.get")
        let data = Data("{\"rule\":{\"name\":\"salary-private.txt\"},\"accessTicket\":{\"grantID\":\"internal\"}}".utf8)
        let result = String(decoding: try await policy.export(data, ticket: ticket), as: UTF8.self)
        XCTAssertFalse(result.contains("salary-private.txt")); XCTAssertFalse(result.contains("accessTicket"))
    }
    func testRevocationBetweenActionsPreservesDoneReceiptAndNeverStartsNext() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "athena")
        let active = try await grant(policy, draft()); let ticket = try await policy.authorize(client: .codex, capability: "system.get_metrics")
        let queue = try DurableTaskQueue(directory: path.appendingPathComponent("queue"), agentID: .athena)
        let request = try TaskRequest(requestID: UUID(), agentID: .athena, capabilityID: "system.get_metrics", parameters: [String: String](), origin: .user, idempotencyKey: "two-actions", createdAt: UTCTimestamp(ISO8601DateFormatter().string(from: Date())))
        let executor = try DurableTaskExecutor(queue: queue, operations: ["system.get_metrics": RegisteredQueueOperation(mutating: true) { _, context in
            let checked = context.withAuthorization { _ in _ = try await policy.check(ticket) }
            _ = try await checked.recordedAction(key: "first") { Data("done".utf8) }
            _ = try await policy.revoke(active.id, role: .gui)
            return try await checked.recordedAction(key: "second") { XCTFail("Second action entered"); return Data() }
        }])
        let task = try await executor.submit(QueueSubmission(request: request, resources: ["test"], mutating: true))
        let final = try await executor.waitForTerminal(task.id); XCTAssertEqual(final.status, .failed); XCTAssertEqual(final.errorCode, .permissionDenied)
        let receipts = try await queue.receipts(task.id); XCTAssertEqual(receipts.count, 1); XCTAssertEqual(receipts.first?.state, .done)
        _ = try await executor.drain()
    }
    func testRevocationCheckpointBlocksReceiptBeforeCallback() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let policy = try LocalAccessPolicy(directory: path, domain: "athena")
        let active = try await grant(policy, draft()); let ticket = try await policy.authorize(client: .codex, capability: "system.get_metrics")
        let queue = try DurableTaskQueue(directory: path.appendingPathComponent("queue"), agentID: .athena)
        let request = try TaskRequest(requestID: UUID(), agentID: .athena, capabilityID: "system.get_metrics", parameters: [String: String](), origin: .user, idempotencyKey: "receipt-test", createdAt: UTCTimestamp(ISO8601DateFormatter().string(from: Date())))
        let executor = try DurableTaskExecutor(queue: queue, operations: ["system.get_metrics": RegisteredQueueOperation(mutating: true) { _, context in
            let guarded = context.withAuthorization { _ in _ = try await policy.check(ticket) }
            _ = try await policy.revoke(active.id, role: .gui)
            return try await guarded.recordedAction(key: "must-not-run") { XCTFail("Revoked callback entered"); return Data() }
        }])
        let task = try await executor.submit(QueueSubmission(request: request, resources: ["test"], mutating: true))
        let result = try await executor.waitForTerminal(task.id); XCTAssertEqual(result.status, .failed); XCTAssertEqual(result.errorCode, .permissionDenied)
        let receipts = try await queue.receipts(task.id); XCTAssertTrue(receipts.isEmpty)
        _ = try await executor.drain()
    }
}
