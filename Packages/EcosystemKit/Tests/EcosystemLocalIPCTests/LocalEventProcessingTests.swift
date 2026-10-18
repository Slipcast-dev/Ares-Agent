import XCTest
@testable import EcosystemLocalIPC

/// Время передаётся явно: takeover и отзыв токенов не требуют ожидания секунд.
final class LocalEventProcessingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func fixture() async throws -> (URL, LocalEventInbox, UUID) {
        let path = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("e10-processing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let inbox = try LocalEventInbox(directory: path), id = UUID()
        try await inbox.append(id: id, kind: "rule.completed", capability: "rule.history", summary: "Правило завершено", now: now)
        return (path, inbox, id)
    }
    private func denied(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Ожидался отказ") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
    }

    func testTwoClientsGetIndependentDeliveryButOnlyOneProcessingOwner() async throws {
        let (path, inbox, id) = try await fixture(); defer { try? FileManager.default.removeItem(at: path) }
        let codexGrant = UUID(), harnessGrant = UUID()
        let codexDelivery = try await inbox.claim(client: .codex, authorizationID: codexGrant, now: now)
        let harnessDelivery = try await inbox.claim(client: .deepseekHarness, authorizationID: harnessGrant, now: now)
        XCTAssertEqual(codexDelivery.first?.event.id, id); XCTAssertEqual(harnessDelivery.first?.event.id, id)
        async let first = inbox.claimProcessing(id: id, client: .codex, authorizationID: codexGrant, now: now)
        async let second = inbox.claimProcessing(id: id, client: .deepseekHarness, authorizationID: harnessGrant, now: now)
        let results = try await [first, second]
        XCTAssertEqual(results.filter(\.claimed).count, 1)
        XCTAssertEqual(results.filter { !$0.claimed }.first?.state, "busy")
        XCTAssertNil(results.first { !$0.claimed }?.processingToken)
        let token = try XCTUnwrap(codexDelivery.first?.token)
        try await inbox.ack(id: id, client: .codex, token: token, authorizationID: codexGrant, now: now)
        let remaining = try await inbox.list(client: .deepseekHarness, now: now)
        XCTAssertEqual(remaining.first?.state, .claimed)
    }

    func testGrantAndClientCannotStealProcessingTokenAndRegrantCannotReviveIt() async throws {
        let (path, inbox, id) = try await fixture(); defer { try? FileManager.default.removeItem(at: path) }
        let grant = UUID(), newGrant = UUID()
        let claim = try await inbox.claimProcessing(id: id, client: .codex, authorizationID: grant, now: now)
        let token = try XCTUnwrap(claim.processingToken)
        await denied { try await inbox.ackProcessing(id: id, client: .deepseekHarness, token: token, authorizationID: grant, now: self.now) }
        await denied { try await inbox.ackProcessing(id: id, client: .codex, token: token, authorizationID: newGrant, now: self.now) }
        await denied { try await inbox.reserveProcessingEffect(id: id, client: .codex, token: token, authorizationID: newGrant, key: "event.rule.synthetic", now: self.now) }
    }

    func testEffectReservationSurvivesExpiryRestartAndDifferentOwner() async throws {
        let (path, inbox, id) = try await fixture(); defer { try? FileManager.default.removeItem(at: path) }
        let firstGrant = UUID(), secondGrant = UUID()
        let claim = try await inbox.claimProcessing(id: id, client: .codex, authorizationID: firstGrant, leaseSeconds: 30, now: now)
        let token = try XCTUnwrap(claim.processingToken)
        try await inbox.reserveProcessingEffect(id: id, client: .codex, token: token, authorizationID: firstGrant, key: "event.rule.synthetic", now: now)
        let restored = try LocalEventInbox(directory: path), later = now.addingTimeInterval(31)
        let taken = try await restored.claimProcessing(id: id, client: .deepseekHarness, authorizationID: secondGrant, now: later)
        XCTAssertTrue(taken.claimed)
        do {
            try await restored.reserveProcessingEffect(id: id, client: .deepseekHarness, token: XCTUnwrap(taken.processingToken), authorizationID: secondGrant, key: "event.rule.synthetic", now: later)
            XCTFail("Lease expiry разрешил второй эффект")
        } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .conflict) }
        await denied { try await restored.ackProcessing(id: id, client: .codex, token: token, authorizationID: firstGrant, now: later) }
    }

    func testSameGrantCanRetryReservedEffectAfterRestartAndLeaseRenewal() async throws {
        let (path, inbox, id) = try await fixture(); defer { try? FileManager.default.removeItem(at: path) }
        let grant = UUID()
        let first = try await inbox.claimProcessing(id: id, client: .codex, authorizationID: grant, leaseSeconds: 30, now: now)
        try await inbox.reserveProcessingEffect(id: id, client: .codex, token: XCTUnwrap(first.processingToken), authorizationID: grant, key: "event.rule.synthetic", now: now)
        let restored = try LocalEventInbox(directory: path), later = now.addingTimeInterval(31)
        let second = try await restored.claimProcessing(id: id, client: .codex, authorizationID: grant, now: later)
        XCTAssertNotEqual(first.processingToken, second.processingToken)
        try await restored.reserveProcessingEffect(id: id, client: .codex, token: XCTUnwrap(second.processingToken), authorizationID: grant, key: "event.rule.synthetic", now: later)
    }

    func testProcessingAckIsDurableAndSeparateFromDeliveryAck() async throws {
        let (path, inbox, id) = try await fixture(); defer { try? FileManager.default.removeItem(at: path) }
        let grant = UUID(), first = try await inbox.claimProcessing(id: id, client: .codex, authorizationID: grant, now: now)
        let token = try XCTUnwrap(first.processingToken)
        try await inbox.ackProcessing(id: id, client: .codex, token: token, authorizationID: grant, now: now)
        try await inbox.ackProcessing(id: id, client: .codex, token: token, authorizationID: grant, now: now)
        let restored = try LocalEventInbox(directory: path)
        let claim = try await restored.claimProcessing(id: id, client: .deepseekHarness, authorizationID: UUID(), now: now)
        XCTAssertFalse(claim.claimed); XCTAssertEqual(claim.state, "finished"); XCTAssertNil(claim.processingToken)
        let delivery = try await restored.list(client: .deepseekHarness, now: now)
        XCTAssertEqual(delivery.first?.state, .pending)
        await denied { try await restored.reserveProcessingEffect(id: id, client: .codex, token: token, authorizationID: grant, key: "event.rule.synthetic", now: self.now) }
    }
    func testLegacyDeliverySurvivesVersionedProcessingUpgrade() async throws {
        let (path, inbox, id) = try await fixture(); defer { try? FileManager.default.removeItem(at: path) }
        let file = path.appendingPathComponent("event-inbox-v1.json"), grant = UUID()
        let delivery = try await inbox.claim(client: .codex, authorizationID: grant, now: now)
        try await inbox.ack(id: id, client: .codex, token: XCTUnwrap(delivery.first?.token), authorizationID: grant, now: now)
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(legacy["version"] as? Int, 1)
        _ = try await inbox.claimProcessing(id: id, client: .codex, authorizationID: grant, now: now)
        let upgraded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(upgraded["version"] as? Int, 2)
        let restored = try LocalEventInbox(directory: path)
        let codex = try await restored.list(client: .codex, now: now)
        let harness = try await restored.list(client: .deepseekHarness, now: now)
        XCTAssertEqual(codex.first?.state, .acked); XCTAssertEqual(harness.first?.state, .pending)
    }

    func testRPCProcessingClaimChecksSourceCapabilityRootsAndCurrentGrant() async throws {
        let (path, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: path) }
        let service = try LocalAutomationService(directory: path, domain: "ares")
        let policy = try LocalAccessPolicy(directory: path, domain: "ares")
        let root = UUID(), id = UUID()
        try await service.inbox.append(id: id, kind: "rule.completed", capability: "rule.history", rootIDs: [root], summary: "Правило завершено")
        func grant(_ capabilities: [String], roots: [UUID]) async throws -> LocalAccessGrant {
            var draft = LocalAccessDraft(); draft.client = .codex; draft.dataClass = .fileMetadata
            draft.capabilities = capabilities; draft.roots = roots
            let plan = try await policy.request(draft, client: nil)
            return try await policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
        }
        func call(_ operation: String, token: UUID? = nil, validRoots: Set<UUID> = []) async throws -> Data {
            var payload = LocalAutomationRequest(); payload.eventID = id; payload.processingToken = token
            return try await LocalAutomationControl.handle(service: service, policy: policy, role: .mcp,
                client: .codex, validRoots: validRoots,
                request: LocalRPCRequest(domain: "ares", operation: operation, payload: LocalWire.encode(payload)))
        }
        _ = try await grant(["events.read"], roots: [root])
        await denied { _ = try await call("events.claim_processing", validRoots: [root]) }
        _ = try await grant(["events.read", "rule.history"], roots: [])
        await denied { _ = try await call("events.claim_processing", validRoots: [root]) }
        let approved = try await grant(["events.read", "rule.history"], roots: [root])
        await denied { _ = try await call("events.claim_processing") }
        let claim = try LocalWire.decode(LocalProcessingClaim.self, await call("events.claim_processing", validRoots: [root]))
        let token = try XCTUnwrap(claim.processingToken)
        _ = try await policy.revoke(approved.id, role: .gui)
        await denied { _ = try await call("events.ack_processing", token: token, validRoots: [root]) }
        _ = try await grant(["events.read", "rule.history"], roots: [root])
        await denied { _ = try await call("events.ack_processing", token: token, validRoots: [root]) }
    }

}
