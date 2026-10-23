import XCTest
@testable import EcosystemLocalIPC

/// Поддельный адаптер проверяет оркестрацию доставки без вызовов системного
/// центра уведомлений, диалогов TCC и изменения пользовательских настроек.
private actor InboxTestNotificationSink: LocalNotificationSending {
    struct Sent: Sendable {
        let id: UUID
        let title: String
        let body: String
    }
    private var state: String
    private var failuresRemaining = 0
    private var delivered: [Sent] = []
    private var requests = 0
    init(authorization: String = "authorized") { state = authorization }
    func authorization() -> String { state }
    func requestAuthorization() -> String { requests += 1; return state }
    func send(id: UUID, title: String, body: String) throws {
        if failuresRemaining > 0 { failuresRemaining -= 1; throw LocalRuntimeFailure.operationFailed }
        delivered.append(Sent(id: id, title: title, body: body))
    }
    func failNext() { failuresRemaining = 1 }
    func sent() -> [Sent] { delivered }
    func requestCount() -> Int { requests }
}

final class LocalAutomationServiceTests: XCTestCase {
    private func directory() throws -> URL {
        let value = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("e7-automation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return value
    }
    private func record(_ service: LocalAutomationService, id: UUID = UUID(), at: Date,
                        significant: Bool = true) async throws {
        try await service.record(id: id, kind: "monitor.threshold", capability: "monitor.history",
                                 capturedAt: at, significant: significant)
    }
    func testBackwardClockKeepsFutureEventScheduled() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let service = try LocalAutomationService(directory: path, domain: "athena", notifications: InboxTestNotificationSink())
        let now = Date()
        try await service.configure(paused: nil, notificationsEnabled: true)
        try await record(service, at: now)
        let delay = await service.notificationRetryDelay(now: now.addingTimeInterval(-120))
        XCTAssertEqual(try XCTUnwrap(delay), 120, accuracy: 0.001)
        await service.flushNotifications(now: now)
        let complete = await service.notificationRetryDelay(now: now); XCTAssertNil(complete)
    }

    func testRetryRespectsCooldownAndStopsAfterLastDelivery() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let service = try LocalAutomationService(directory: path, domain: "athena", notifications: InboxTestNotificationSink())
        let now = Date()
        try await service.configure(paused: nil, notificationsEnabled: true)
        try await record(service, at: now); try await record(service, at: now)
        await service.flushNotifications(now: now)
        let pending = await service.notificationRetryDelay(now: now.addingTimeInterval(20))
        XCTAssertEqual(try XCTUnwrap(pending), 40, accuracy: 0.001)
        await service.flushNotifications(now: now.addingTimeInterval(60))
        let done = await service.notificationRetryDelay(now: now.addingTimeInterval(60)); XCTAssertNil(done)
    }

    func testRetryDeadlineOnlyExistsForFreshUndeliveredEvents() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let sink = InboxTestNotificationSink(authorization: "denied")
        let service = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        let now = Date()
        try await service.configure(paused: nil, notificationsEnabled: true)
        let empty = await service.notificationRetryDelay(now: now); XCTAssertNil(empty)
        try await record(service, at: now)
        let pending = await service.notificationRetryDelay(now: now); XCTAssertEqual(pending, 60)
        let expired = await service.notificationRetryDelay(now: now.addingTimeInterval(3601)); XCTAssertNil(expired)
        try await service.configure(paused: nil, notificationsEnabled: false)
        let disabled = await service.notificationRetryDelay(now: now); XCTAssertNil(disabled)
    }

    func testDeniedSystemNotificationsPreserveInboxAcrossRestartWithoutPrompt() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let sink = InboxTestNotificationSink(authorization: "denied")
        let service = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        let captured = await service.cutoff().addingTimeInterval(1), id = UUID()
        try await service.configure(paused: nil, notificationsEnabled: true)
        try await record(service, id: id, at: captured)
        await service.flushNotifications(now: captured.addingTimeInterval(1))
        let sent = await sink.sent(), requests = await sink.requestCount()
        XCTAssertTrue(sent.isEmpty); XCTAssertEqual(requests, 0)
        let restored = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        let events = try await restored.inbox.events(now: captured)
        XCTAssertEqual(events.map(\.id), [id])
        let status = try await restored.status()
        XCTAssertEqual(status.notificationAuthorization, "denied")
        XCTAssertTrue(status.settings.notificationsEnabled)
    }
    func testStableEventSendsOnceAcrossRepeatAndRestart() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let sink = InboxTestNotificationSink()
        let service = try LocalAutomationService(directory: path, domain: "ares", notifications: sink)
        _ = try await service.language.set(.ru)
        let captured = await service.cutoff().addingTimeInterval(1), id = UUID()
        try await service.configure(paused: nil, notificationsEnabled: true)
        try await record(service, id: id, at: captured)
        for _ in 0..<4 { await service.flushNotifications(now: captured.addingTimeInterval(2)) }
        let restored = try LocalAutomationService(directory: path, domain: "ares", notifications: sink)
        try await record(restored, id: id, at: captured)
        await restored.flushNotifications(now: captured.addingTimeInterval(3))
        let sent = await sink.sent()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.id, id); XCTAssertEqual(sent.first?.title, "Арес")
        XCTAssertFalse(sent.first?.body.contains("/") ?? true)
        let events = try await restored.inbox.events(now: captured)
        XCTAssertEqual(events.count, 1)
    }
    func testOrdinaryEventsRemainInInboxButNeverCreateBanner() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let sink = InboxTestNotificationSink()
        let service = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        let captured = await service.cutoff().addingTimeInterval(1), ordinary = UUID(), important = UUID()
        try await service.configure(paused: nil, notificationsEnabled: true)
        try await record(service, id: ordinary, at: captured, significant: false)
        try await record(service, id: important, at: captured)
        await service.flushNotifications(now: captured.addingTimeInterval(2))
        let restored = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        await restored.flushNotifications(now: captured.addingTimeInterval(3))
        let sent = await sink.sent()
        XCTAssertEqual(sent.map(\.id), [important])
        let events = try await restored.inbox.events(now: captured)
        XCTAssertEqual(Set(events.map(\.id)), [ordinary, important])
    }
    func testProvisionalDeliveryPreservesQuietStatusAndDurableReceipt() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let sink = InboxTestNotificationSink(authorization: "provisional")
        let service = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        _ = try await service.language.set(.ru)
        let captured = await service.cutoff().addingTimeInterval(1), id = UUID()
        try await service.configure(paused: nil, notificationsEnabled: true)
        try await record(service, id: id, at: captured)
        await service.flushNotifications(now: captured.addingTimeInterval(2))
        let status = try await service.status()
        XCTAssertEqual(status.notificationAuthorization, "provisional")
        let restored = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        await restored.flushNotifications(now: captured.addingTimeInterval(3))
        let sent = await sink.sent()
        XCTAssertEqual(sent.map(\.id), [id])
        XCTAssertEqual(sent.first?.title, "Афина")
        XCTAssertFalse(sent.first?.body.contains("/") ?? true)
    }
    func testPausedAndNotificationPreferencesPersistIndependently() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let sink = InboxTestNotificationSink()
        let service = try LocalAutomationService(directory: path, domain: "ares", notifications: sink)
        try await service.configure(paused: true, notificationsEnabled: false)
        let restored = try LocalAutomationService(directory: path, domain: "ares", notifications: sink)
        let paused = await restored.paused()
        XCTAssertTrue(paused)
        let captured = await restored.cutoff().addingTimeInterval(1)
        try await record(restored, at: captured)
        await restored.flushNotifications(now: captured.addingTimeInterval(2))
        let sent = await sink.sent()
        XCTAssertTrue(sent.isEmpty)
        try await restored.configure(paused: false, notificationsEnabled: nil)
        let again = try LocalAutomationService(directory: path, domain: "ares", notifications: sink)
        let status = try await again.status()
        XCTAssertFalse(status.settings.paused)
        XCTAssertFalse(status.settings.notificationsEnabled)
    }
    func testDeliveryFailureKeepsEventAndRetriesWithSameIdentifier() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let sink = InboxTestNotificationSink()
        let service = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        let captured = await service.cutoff().addingTimeInterval(1), id = UUID()
        try await service.configure(paused: nil, notificationsEnabled: true)
        try await record(service, id: id, at: captured)
        await sink.failNext()
        await service.flushNotifications(now: captured.addingTimeInterval(2))
        let failed = try await service.status()
        XCTAssertNotNil(failed.lastFailure)
        let events = try await service.inbox.events(now: captured)
        XCTAssertEqual(events.map(\.id), [id])
        let restored = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        await restored.flushNotifications(now: captured.addingTimeInterval(3))
        let sent = await sink.sent()
        XCTAssertEqual(sent.map(\.id), [id])
        let status = try await restored.status()
        XCTAssertNil(status.lastFailure)
    }
    func testCutoffIgnoresOldHistoryAndPromptRequiresExplicitRequest() async throws {
        let path = try directory(); defer { try? FileManager.default.removeItem(at: path) }
        let sink = InboxTestNotificationSink(authorization: "notDetermined")
        let service = try LocalAutomationService(directory: path, domain: "athena", notifications: sink)
        let cutoff = await service.cutoff()
        try await record(service, at: cutoff.addingTimeInterval(-1))
        try await service.configure(paused: nil, notificationsEnabled: true)
        await service.flushNotifications(now: cutoff)
        let events = try await service.inbox.events(now: cutoff), before = await sink.requestCount()
        XCTAssertTrue(events.isEmpty); XCTAssertEqual(before, 0)
        let result = try await service.requestNotifications()
        XCTAssertEqual(result, "notDetermined")
        let after = await sink.requestCount()
        XCTAssertEqual(after, 1)
    }
}
