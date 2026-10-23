import Foundation
import XCTest
import EcosystemLocalization
import EcosystemContracts
import EcosystemRuntimeSupport
@testable import EcosystemLocalIPC

private actor PreLocalizationNotificationSink: LocalNotificationSending {
    private var ids: [UUID] = []
    func authorization() -> String { "authorized" }
    func requestAuthorization() -> String { "authorized" }
    func send(id: UUID, title: String, body: String) { ids.append(id) }
    func deliveries() -> [UUID] { ids }
}

/// Ограниченная совместимость формата 0.29.0: automation/inbox JSON заданы
/// вручную по опубликованному layout GitHub-update-0.29.0/Athena/Packages/
/// EcosystemKit. Queue fixture использует публичный encoder, чья совместимость
/// с 0.29.0 подтверждается отдельным сравнением исходников/схемы. Это не запуск
/// старого GUI или полного установщика поверх нового профиля.
final class PreLocalizationProfileCompatibilityTests: XCTestCase {
    func testOldJSONAndQueueSurviveLanguageSidecarWithoutRewritingOrNotificationReplay() async throws {
        for domain in ["ares", "athena"] {
            let root = URL(fileURLWithPath: "/private/tmp/pre-localization-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let eventID = UUID(), ordinaryID = UUID()
            let cutoff = Date(timeIntervalSinceReferenceDate: 900_000_000)
            let captured = cutoff.addingTimeInterval(10)
            let now = captured.addingTimeInterval(60)
            let freeText = "Историческое сообщение %@ 100% 😀"
            let automationFile = root.appendingPathComponent("automation-v1.json")
            let inboxFile = root.appendingPathComponent("event-inbox-v1.json")
            let automation: [String: Any] = ["version": 1,
                "settings": ["paused": false, "notificationsEnabled": true,
                             "createdAt": cutoff.timeIntervalSinceReferenceDate],
                "notified": [eventID.uuidString],
                "nextNotificationAt": captured.addingTimeInterval(30).timeIntervalSinceReferenceDate]
            func entry(_ id: UUID, significant: Bool) -> [String: Any] {
                ["event": ["id": id.uuidString, "kind": "legacy.event", "capability": "legacy.history",
                           "rootIDs": [], "summary": freeText, "notificationEligible": significant,
                           "createdAt": captured.timeIntervalSinceReferenceDate,
                           "expiresAt": captured.addingTimeInterval(604800).timeIntervalSinceReferenceDate],
                 "receipts": [:]]
            }
            try write(automation, to: automationFile)
            try write(["version": 1, "entries": [entry(eventID, significant: true), entry(ordinaryID, significant: false)]], to: inboxFile)
            let oldAutomation = try Data(contentsOf: automationFile), oldInbox = try Data(contentsOf: inboxFile)
            let queue = try DurableTaskQueue(directory: root.appendingPathComponent("queue"),
                                             agentID: domain == "ares" ? .ares : .athena)
            let request = try TaskRequest(requestID: UUID(), agentID: domain == "ares" ? .ares : .athena,
                capabilityID: "legacy.operation", parameters: ["literal": freeText], origin: .user,
                idempotencyKey: "old-completed", rootID: UUID(), createdAt: UTCTimestamp("2026-10-19T01:00:00Z"))
            let submitted = try QueueSubmission(request: request, resources: ["legacy.completed"], mutating: true)
            let task = try await queue.accept(submitted)
            let lease = try await queue.claim(task.id)
            let receipt = try await queue.beginReceipt(lease, actionKey: "legacy.effect", summary: freeText)
            try await queue.completeReceipt(lease, receiptID: receipt.id, evidence: Data("old evidence".utf8))
            let completed = try await queue.finish(lease, status: .completed, result: Data(freeText.utf8))
            let pendingRequest = try TaskRequest(requestID: UUID(), agentID: request.agentID,
                capabilityID: "legacy.read", parameters: ["literal": freeText], origin: .user,
                idempotencyKey: "old-queued", rootID: UUID(), createdAt: UTCTimestamp("2026-10-19T01:01:00Z"))
            let pending = try await queue.accept(QueueSubmission(request: pendingRequest, resources: ["legacy.pending"], mutating: false))
            let persistedCompleted = try await queue.task(completed.id)
            let persistedPending = try await queue.task(pending.id)
            // Сравниваем persisted снимки, не возвращённые значения до округления
            // дат SQLite/JSON, чтобы проверка ловила изменение данных профиля.
            let queueBefore = try LocalWire.encode([XCTUnwrap(persistedCompleted), XCTUnwrap(persistedPending)])
            let receiptBefore = try await queue.receipts(task.id)
            let receiptBytes = try LocalWire.encode(receiptBefore)
            let sink = PreLocalizationNotificationSink()
            let filesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            let service = try LocalAutomationService(directory: root, domain: domain, notifications: sink)
            let initial = await service.language.status()
            XCTAssertEqual(initial.preference, .system)
            let languageFile = root.appendingPathComponent("language-v1.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: languageFile.path))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), filesBefore)
            let eventsBefore = try await service.inbox.events(now: now)
            XCTAssertEqual(eventsBefore.map(\.summary), [freeText, freeText])
            for choice in [AgentLanguagePreference.en, .ru, .system] {
                _ = try await service.language.set(choice)
                await service.flushNotifications(now: now)
                XCTAssertEqual(try Data(contentsOf: automationFile), oldAutomation)
                XCTAssertEqual(try Data(contentsOf: inboxFile), oldInbox)
            }
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), filesBefore.union(["language-v1.json"]))
            let restored = try LocalAutomationService(directory: root, domain: domain, notifications: sink)
            // Повтор импортируемого старого UUID возвращает старый summary;
            // новые RU/EN строки не должны перезаписать исходный inbox.
            try await restored.record(id: eventID, kind: "legacy.event", capability: "legacy.history",
                                      capturedAt: captured, significant: true)
            await restored.flushNotifications(now: now.addingTimeInterval(120))
            let sent = await sink.deliveries()
            XCTAssertTrue(sent.isEmpty)
            let eventsAfter = try await restored.inbox.events(now: now)
            XCTAssertEqual(eventsAfter, eventsBefore)
            XCTAssertEqual(try Data(contentsOf: automationFile), oldAutomation)
            XCTAssertEqual(try Data(contentsOf: inboxFile), oldInbox)
            let completedAfter = try await queue.task(completed.id)
            let pendingAfter = try await queue.task(pending.id)
            XCTAssertEqual(try LocalWire.encode([XCTUnwrap(completedAfter), XCTUnwrap(pendingAfter)]), queueBefore)
            let receiptsAfter = try await queue.receipts(task.id)
            XCTAssertEqual(try LocalWire.encode(receiptsAfter), receiptBytes)
            let repeated = try await queue.accept(submitted)
            XCTAssertEqual(repeated.id, completed.id)
            XCTAssertEqual(repeated.result, Data(freeText.utf8))
        }
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
