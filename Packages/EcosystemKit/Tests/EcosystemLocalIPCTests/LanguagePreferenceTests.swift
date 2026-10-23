import Darwin
import Foundation
import XCTest
import EcosystemLocalization
import EcosystemContracts
import EcosystemRuntimeSupport
@testable import EcosystemLocalIPC

private actor LanguageNotificationSink: LocalNotificationSending {
    private(set) var sent: [(UUID, String, String)] = []
    func authorization() async -> String { "authorized" }
    func requestAuthorization() async throws -> String { "authorized" }
    func send(id: UUID, title: String, body: String) async throws { sent.append((id, title, body)) }
}

final class LanguagePreferenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/language-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func file(_ directory: URL) -> URL { directory.appendingPathComponent("language-v1.json") }
    private func write(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func testSystemUsesParentGUIThenGlobalPreferences() {
        let preferences = ["dev.slipcast.fileorganizer": ["ru-RU"], UserDefaults.globalDomain: ["en-GB"]]
        XCTAssertEqual(LocalLanguagePreferences.systemLanguages(domain: "ares", lookup: { preferences[$0] }, fallback: ["fr"]), ["ru-RU"])
        XCTAssertEqual(LocalLanguagePreferences.systemLanguages(domain: "athena", lookup: { preferences[$0] }, fallback: ["ru"]), ["en-GB"])
        XCTAssertEqual(LocalLanguagePreferences.systemLanguages(domain: "athena", lookup: { _ in nil }, fallback: ["ru"]), ["ru"])
    }
    func testOldProfileDefaultsToSystemWithoutCreatingFiles() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalLanguagePreferences(directory: root, domain: "ares", preferredLanguages: { ["de", "en-GB", "ru"] })
        let status = await store.status()
        XCTAssertEqual(status, LocalLanguageStatus(preference: .system, effectiveLanguage: .english))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testIndependentDomainsAndRestart() async throws {
        let ares = try directory(), athena = try directory()
        defer { try? FileManager.default.removeItem(at: ares); try? FileManager.default.removeItem(at: athena) }
        let a = try LocalLanguagePreferences(directory: ares, domain: "ares", preferredLanguages: { ["ru"] })
        let b = try LocalLanguagePreferences(directory: athena, domain: "athena", preferredLanguages: { ["en"] })
        _ = try await a.set(.en); _ = try await b.set(.ru)
        let restoredA = try LocalLanguagePreferences(directory: ares, domain: "ares")
        let restoredB = try LocalLanguagePreferences(directory: athena, domain: "athena")
        let stateA = await restoredA.status(), stateB = await restoredB.status()
        XCTAssertEqual(stateA.effectiveLanguage, .english); XCTAssertEqual(stateB.effectiveLanguage, .russian)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file(ares).path)[.posixPermissions] as? Int, 0o600)
    }
    func testResetToSystemAndUnknownLegacyChoice() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = "{\"version\":1,\"preference\":\"future-language\"}"
        try write(original, at: file(root))
        let store = try LocalLanguagePreferences(directory: root, domain: "ares", preferredLanguages: { ["fr", "ru_RU"] })
        let fallback = await store.status(); XCTAssertEqual(fallback.preference, .system)
        XCTAssertEqual(try String(contentsOf: file(root)), original)
        _ = try await store.set(.en)
        let reset = try await store.set(.system); XCTAssertEqual(reset.effectiveLanguage, .russian)
        let before = try Data(contentsOf: file(root)); _ = try await store.set(.system)
        XCTAssertEqual(try Data(contentsOf: file(root)), before)
    }
    func testUnsafeFilesAndDirectoryAreRejected() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try write("{\"version\":1,\"preference\":\"en\"}", at: target)
        try FileManager.default.createSymbolicLink(at: file(root), withDestinationURL: target)
        XCTAssertThrowsError(try LocalLanguagePreferences(directory: root, domain: "ares"))
        try FileManager.default.removeItem(at: file(root))
        try FileManager.default.linkItem(at: target, to: file(root))
        XCTAssertThrowsError(try LocalLanguagePreferences(directory: root, domain: "ares"))
        try FileManager.default.removeItem(at: file(root))
        try write("{}", at: file(root))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file(root).path)
        XCTAssertThrowsError(try LocalLanguagePreferences(directory: root, domain: "ares"))
        let link = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try LocalLanguagePreferences(directory: link, domain: "ares"))
    }
    func testInvalidDocumentAndVersionAreRejectedWithoutRewrite() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for text in ["bad JSON", "{\"version\":2,\"preference\":\"en\"}", "{\"version\":1,\"preference\":\"en\",\"grant\":true}"] {
            try write(text, at: file(root))
            XCTAssertThrowsError(try LocalLanguagePreferences(directory: root, domain: "ares"))
            XCTAssertEqual(try String(contentsOf: file(root)), text)
        }
    }
    func testGUIOnlyAndStrictPayloads() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalLanguagePreferences(directory: root, domain: "athena")
        for role in [LocalRole.mcp, .worker] {
            for operation in ["language.get", "language.set"] {
                let request = LocalRPCRequest(domain: "athena", operation: operation, payload: Data("{}".utf8))
                do { _ = try await LocalLanguageControl.handle(store: store, role: role, request: request); XCTFail("Role bypass") }
                catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
            }
        }
        for text in ["{\"preference\":\"de\"}", "{\"preference\":\"en\",\"path\":\"/tmp\"}"] {
            do {
                _ = try await LocalLanguageControl.handle(store: store, role: .gui,
                    request: LocalRPCRequest(domain: "athena", operation: "language.set", payload: Data(text.utf8)))
                XCTFail("Invalid payload accepted")
            } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .invalidRequest) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(root).path))
    }
    func testDeliveryLanguageChangesWithoutRewritingHistoryOrRepeatingReceipt() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let sink = LanguageNotificationSink()
        let service = try LocalAutomationService(directory: root, domain: "ares", notifications: sink)
        _ = try await service.language.set(.ru)
        try await service.configure(paused: nil, notificationsEnabled: true)
        let now = await service.cutoff().addingTimeInterval(1), id = UUID()
        try await service.record(id: id, kind: "rule.notification", capability: "rule.history", capturedAt: now, significant: true)
        let events = try await service.inbox.events(now: now)
        let automationFile = root.appendingPathComponent("automation-v1.json")
        let before = try Data(contentsOf: automationFile)
        _ = try await service.language.set(.en)
        XCTAssertEqual(try Data(contentsOf: automationFile), before)
        await service.flushNotifications(now: now)
        let sent = await sink.sent
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(sent.first?.0, id); XCTAssertEqual(sent.first?.1, "Ares")
        XCTAssertEqual(sent.first?.2, "Local agent: attention required. Details are available in the application.")
        let after = try await service.inbox.events(now: now); XCTAssertEqual(after, events)
        let restored = try LocalAutomationService(directory: root, domain: "ares", notifications: sink)
        _ = try await restored.language.set(.ru)
        await restored.flushNotifications(now: now.addingTimeInterval(61))
        let replay = await sink.sent; XCTAssertEqual(replay.count, 1)
        let status = try await restored.status(); let cutoff = await service.cutoff(); XCTAssertEqual(status.settings.createdAt, cutoff)
    }
    func testChangingLanguageLeavesExecutingLeaseFingerprintAndTaskIDUnchanged() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = try DurableTaskQueue(directory: root.appendingPathComponent("queue"), agentID: .ares)
        let request = try TaskRequest(requestID: UUID(), agentID: AgentID.ares, capabilityID: "file.scan", parameters: ["sample": 1],
            origin: .user, idempotencyKey: "language-active-task", rootID: UUID(), createdAt: UTCTimestamp("2026-10-21T12:00:00Z"))
        let submission = try QueueSubmission(request: request, resources: ["root.fixture"], mutating: false)
        let accepted = try await queue.accept(submission)
        let lease = try await queue.claim(accepted.id)
        let beforeValue = try await queue.task(accepted.id)
        let before = try XCTUnwrap(beforeValue)
        let language = try LocalLanguagePreferences(directory: root, domain: "ares")
        for choice in [AgentLanguagePreference.en, .ru, .system] { _ = try await language.set(choice) }
        let afterValue = try await queue.task(accepted.id)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.id, before.id); XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.fingerprint, before.fingerprint)
        // Сравниваем persisted снимки до/после. Date из claim может отличаться
        // на округление SQLite, хотя сохранённая lease вообще не менялась.
        XCTAssertEqual(after.lease, before.lease)
        XCTAssertEqual(after.lease?.fencingToken, lease.fencingToken)
        XCTAssertEqual(after.revision, before.revision); XCTAssertNil(after.cancellationRequestedAt)
        let duplicate = try await queue.accept(submission); XCTAssertEqual(duplicate.id, accepted.id)
    }
}
