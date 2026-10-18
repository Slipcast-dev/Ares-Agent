import Darwin
import XCTest
@testable import EcosystemLocalIPC

final class LocalEventInboxTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func directory() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("e7-inbox-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return value
    }
    private func append(_ inbox: LocalEventInbox, id: UUID = UUID(), ttl: TimeInterval = 604_800) async throws -> LocalInboxEvent {
        try await inbox.append(id: id, kind: "monitor.threshold", capability: "monitor.history", summary: "Порог мониторинга превышен", now: now, ttl: ttl)
    }
    private func assertFailure(_ expected: LocalRuntimeFailure, _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Ожидался отказ") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, expected) }
    }
    func testDuplicateWakeAndRestartPreserveSingleAckedDelivery() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let inbox = try LocalEventInbox(directory: path), id = UUID()
        let original = try await append(inbox, id: id)
        let claimed = try await inbox.claim(client: .codex, now: now)
        let token = try XCTUnwrap(claimed.first?.token)
        try await inbox.ack(id: id, client: .codex, token: token, now: now)
        for _ in 0..<10 { _ = try await append(inbox, id: id) }
        let restored = try LocalEventInbox(directory: path)
        let duplicate = try await restored.append(id: id, kind: "ignored", capability: "ignored", summary: "Повтор", now: now.addingTimeInterval(10))
        XCTAssertEqual(duplicate, original)
        let events = try await restored.events(now: now)
        XCTAssertEqual(events.count, 1)
        let deliveries = try await restored.list(client: .codex, now: now)
        XCTAssertEqual(deliveries.first?.state, .acked)
        let replay = try await restored.claim(client: .codex, now: now)
        XCTAssertTrue(replay.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent("event-inbox-v1.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testClientsCannotStealOrAcknowledgeEachOthersLease() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let inbox = try LocalEventInbox(directory: path), event = try await append(inbox)
        let codex = try await inbox.claim(client: .codex, now: now)
        let codexToken = try XCTUnwrap(codex.first?.token)
        await assertFailure(.denied) { try await inbox.ack(id: event.id, client: .deepseekHarness, token: codexToken, now: self.now) }
        let harness = try await inbox.claim(client: .deepseekHarness, now: now)
        XCTAssertEqual(harness.first?.event.id, event.id)
        XCTAssertNotEqual(harness.first?.token, codexToken)
        try await inbox.ack(id: event.id, client: .codex, token: codexToken, now: now)
        let own = try await inbox.list(client: .deepseekHarness, now: now)
        XCTAssertEqual(own.first?.state, .claimed)
        let legacy = try await inbox.list(client: .legacy, now: now)
        XCTAssertEqual(legacy.first?.state, .pending)
        XCTAssertNil(legacy.first?.token)
    }
    func testLeaseExpiryRedeliveryRejectsOldTokenAcrossRestart() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let inbox = try LocalEventInbox(directory: path), event = try await append(inbox)
        let claim = try await inbox.claim(client: .codex, leaseSeconds: 30, now: now)
        let token = try XCTUnwrap(claim.first?.token)
        let pending = try await inbox.claim(client: .codex, now: now.addingTimeInterval(29))
        XCTAssertTrue(pending.isEmpty)
        let restored = try LocalEventInbox(directory: path)
        let newClaim = try await restored.claim(client: .codex, now: now.addingTimeInterval(30))
        let newToken = try XCTUnwrap(newClaim.first?.token)
        XCTAssertNotEqual(token, newToken)
        await assertFailure(.denied) { try await restored.ack(id: event.id, client: .codex, token: token, now: self.now.addingTimeInterval(31)) }
        try await restored.ack(id: event.id, client: .codex, token: newToken, now: now.addingTimeInterval(31))
    }
    func testTTLExpiryAndPolicyFilteringBeforeClaim() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let inbox = try LocalEventInbox(directory: path)
        let allowed = try await append(inbox, ttl: 40), hidden = try await append(inbox)
        let filtered = try await inbox.list(client: .codex, allowedEventIDs: [allowed.id], now: now)
        XCTAssertEqual(filtered.map { $0.event.id }, [allowed.id])
        let empty = try await inbox.claim(client: .codex, allowedEventIDs: [], now: now)
        XCTAssertTrue(empty.isEmpty)
        let claims = try await inbox.claim(client: .codex, allowedEventIDs: [allowed.id], leaseSeconds: 300, now: now)
        XCTAssertEqual(claims.first?.leaseExpiresAt, allowed.expiresAt)
        let token = try XCTUnwrap(claims.first?.token)
        await assertFailure(.denied) { try await inbox.ack(id: allowed.id, client: .codex, token: token, now: self.now.addingTimeInterval(40)) }
        let expired = try await inbox.list(client: .codex, allowedEventIDs: [allowed.id], now: now.addingTimeInterval(40))
        XCTAssertEqual(expired.first?.state, .expired)
        let later = try await inbox.claim(client: .codex, now: now.addingTimeInterval(40))
        XCTAssertEqual(later.map { $0.event.id }, [hidden.id])
    }
    func testRejectsMalformedFutureVersionAndInsecurePaths() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let file = path.appendingPathComponent("event-inbox-v1.json")
        for json in ["{", "{\"version\":3,\"entries\":[]}", "{\"version\":1,\"entries\":[{}]}"] {
            try Data(json.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertThrowsError(try LocalEventInbox(directory: path))
        }
        try Data("{\"version\":1,\"entries\":[]}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try LocalEventInbox(directory: path))
        try FileManager.default.removeItem(at: file)
        let target = path.appendingPathComponent("target")
        try Data("private".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try LocalEventInbox(directory: path))
        try FileManager.default.removeItem(at: file)
        let inbox = try LocalEventInbox(directory: path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        await assertFailure(.invalidConfiguration) { _ = try await self.append(inbox) }
        XCTAssertEqual(try String(contentsOf: target), "private")
    }
    func testInputBoundsAndSafeAggregateSummary() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let inbox = try LocalEventInbox(directory: path)
        for summary in ["/Users/private/document", "file\\secret", "line\ncontent", String(repeating: "a", count: 513)] {
            await assertFailure(.invalidRequest) { _ = try await inbox.append(id: UUID(), kind: "monitor", capability: "monitor.history", summary: summary, now: self.now) }
        }
        for ttl in [0.0, 2_592_001, .infinity] {
            await assertFailure(.invalidRequest) { _ = try await self.append(inbox, ttl: ttl) }
        }
        for lease in [29.0, 301, .infinity] {
            await assertFailure(.invalidRequest) { _ = try await inbox.claim(client: .codex, leaseSeconds: lease, now: self.now) }
        }
        for limit in [0, 51] {
            await assertFailure(.invalidRequest) { _ = try await inbox.list(client: .codex, limit: limit, now: self.now) }
        }
    }
    func testCountQuotaDoesNotSilentlyDropPendingEventsAndExpiredCanBeEvicted() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let file = path.appendingPathComponent("event-inbox-v1.json")
        // Загружаем реалистичный полный журнал за один раз, не выполняя 4096 fsync.
        let entries: [[String: Any]] = (0..<4096).map { _ in
            ["event": ["id": UUID().uuidString, "kind": "monitor", "capability": "monitor.history", "rootIDs": [], "summary": "Событие", "createdAt": now.timeIntervalSinceReferenceDate, "expiresAt": now.addingTimeInterval(60).timeIntervalSinceReferenceDate], "receipts": [:]]
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let inbox = try LocalEventInbox(directory: path)
        await assertFailure(.busy) { _ = try await self.append(inbox) }
        let before = try await inbox.events(now: now)
        XCTAssertEqual(before.count, 4096)
        let new = try await inbox.append(id: UUID(), kind: "monitor", capability: "monitor.history", summary: "Новое событие", now: now.addingTimeInterval(61))
        let after = try await inbox.events(now: now.addingTimeInterval(61))
        XCTAssertEqual(after.map(\.id), [new.id])
    }
    func testOrdinaryNotificationEligibilityPersistsAtomicallyWithEvent() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let inbox = try LocalEventInbox(directory: path), id = UUID()
        _ = try await inbox.append(id: id, kind: "task.completed", capability: "monitor.history",
                                   summary: "Операция завершена", notificationEligible: false, now: now)
        let restored = try LocalEventInbox(directory: path)
        let event = await restored.event(id: id)
        XCTAssertEqual(event?.notificationEligible, false)
        // Повтор producer после restart не меняет уже записанную классификацию.
        _ = try await restored.append(id: id, kind: "task.completed", capability: "monitor.history",
                                      summary: "Повтор", notificationEligible: true, now: now)
        let duplicate = await restored.event(id: id)
        XCTAssertEqual(duplicate?.notificationEligible, false)
    }
    func testClockRollbackDoesNotPersistLeaseBeforeEventCreation() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let inbox = try LocalEventInbox(directory: path), event = try await append(inbox)
        let rolledBack = try await inbox.claim(client: .codex, leaseSeconds: 30, now: now.addingTimeInterval(-60))
        XCTAssertTrue(rolledBack.isEmpty)
        let restored = try LocalEventInbox(directory: path)
        let deliveries = try await restored.list(client: .codex, now: now)
        XCTAssertEqual(deliveries.first?.state, .pending)
        XCTAssertNil(deliveries.first?.token)
        let claimed = try await restored.claim(client: .codex, now: now)
        XCTAssertEqual(claimed.first?.event.id, event.id)
    }
    func testRegrantCannotAcknowledgePreviousGrantLease() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let inbox = try LocalEventInbox(directory: path), event = try await append(inbox)
        let oldGrant = UUID(), newGrant = UUID()
        let claimed = try await inbox.claim(client: .codex, authorizationID: oldGrant, now: now)
        let token = try XCTUnwrap(claimed.first?.token)
        await assertFailure(.denied) { try await inbox.ack(id: event.id, client: .codex, token: token, authorizationID: newGrant, now: self.now) }
        await assertFailure(.denied) { try await inbox.ack(id: event.id, client: .codex, token: token, now: self.now) }
        let renewed = try await inbox.claim(client: .codex, authorizationID: newGrant, now: now.addingTimeInterval(121))
        let renewedToken = try XCTUnwrap(renewed.first?.token)
        try await inbox.ack(id: event.id, client: .codex, token: renewedToken, authorizationID: newGrant, now: now.addingTimeInterval(122))
    }
    func testOversizedDocumentRejectedBeforeDecode() throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let file = path.appendingPathComponent("event-inbox-v1.json")
        try Data(repeating: 32, count: LocalEventInbox.maximumDocumentBytes + 1).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try LocalEventInbox(directory: path))
    }
}
