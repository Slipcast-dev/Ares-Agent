import Foundation
import XCTest
import EcosystemLocalization
@testable import EcosystemLocalIPC

/// Сбой и повторная доставка проверяются без обращения к Notification Center.
private actor RuntimeFailureSink: LocalNotificationSending {
    private var failed = false
    private var ids: [UUID] = []
    func authorization() -> String { "authorized" }
    func requestAuthorization() -> String { "authorized" }
    func send(id: UUID, title: String, body: String) throws {
        if !failed { failed = true; throw LocalRuntimeFailure.operationFailed }
        ids.append(id)
    }
    func delivered() -> [UUID] { ids }
}

final class RuntimePresentationTests: XCTestCase {
    func testIndependentPresentationLanguagesKeepHistoryAndReceiptAcrossRestart() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("runtime-language-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = RuntimeFailureSink()
        let service = try LocalAutomationService(directory: root, domain: "athena", notifications: sink)
        _ = try await service.language.set(.en)
        try await service.configure(paused: nil, notificationsEnabled: true)
        let now = await service.cutoff().addingTimeInterval(1), id = UUID()
        try await service.record(id: id, kind: "monitor.threshold", capability: "monitor.history", capturedAt: now, significant: true)
        await service.flushNotifications(now: now)
        let original = try await service.inbox.events(now: now)
        let persisted = root.appendingPathComponent("automation-v1.json")
        let before = try Data(contentsOf: persisted)
        for (runtime, gui) in [(AgentLanguagePreference.en, AgentLanguage.russian), (.ru, .english)] {
            _ = try await service.language.set(runtime)
            let status = try await service.status()
            let language = await service.language.status().effectiveLanguage
            XCTAssertEqual(status.lastFailure, AgentLocalization(language: language).runtimeText("automation.deliveryFailure"))
            // GUI рендерит типизированную причину независимо от языка службы.
            XCTAssertNotEqual(status.lastFailure, AgentLocalization(language: gui).runtimeText("automation.deliveryFailure"))
            XCTAssertEqual(try Data(contentsOf: persisted), before)
            let events = try await service.inbox.events(now: now)
            XCTAssertEqual(events, original)
        }
        await service.flushNotifications(now: now.addingTimeInterval(61))
        let restored = try LocalAutomationService(directory: root, domain: "athena", notifications: sink)
        _ = try await restored.language.set(.en)
        await restored.flushNotifications(now: now.addingTimeInterval(122))
        let ids = await sink.delivered()
        XCTAssertEqual(ids, [id])
        let events = try await restored.inbox.events(now: now)
        XCTAssertEqual(events, original)
    }

    func testFailureCodesAndRetryabilityDoNotDependOnHumanLanguage() throws {
        for failure in [LocalRuntimeFailure.denied, .busy, .unavailable, .cancelled, .recoveryRequired] {
            let before = try LocalWire.encode(failure)
            for language in AgentLanguage.allCases {
                let text = AgentLocalization(language: language).runtimeError(failure)
                XCTAssertFalse(text.isEmpty)
                XCTAssertNotEqual(text, failure.rawValue)
                XCTAssertEqual(try LocalWire.encode(failure), before)
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalCommonMCP.failure(failure)) as? [String: Any])
            let content = try XCTUnwrap(object["structuredContent"] as? [String: Any])
            let error = try XCTUnwrap(content["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, failure.knownCode.rawValue)
            XCTAssertEqual(error["retryable"] as? Bool, [.busy, .unavailable].contains(failure))
        }
        let unsafe = NSError(domain: "SECRET_TOKEN", code: 1, userInfo: [NSLocalizedDescriptionKey: "SECRET_TOKEN"])
        XCTAssertFalse(String(decoding: LocalCommonMCP.failure(unsafe), as: UTF8.self).contains("SECRET_TOKEN"))
    }
    func testToolDefinitionsKeepMachineSchemasAndHaveBothLanguages() throws {
        for tools in [LocalCommonMCP.tools, LocalAccessMCP.tools, LocalInboxMCP.tools] {
            for tool in tools {
                let name = try XCTUnwrap(tool["name"] as? String)
                let description = try XCTUnwrap(tool["description"] as? String)
                XCTAssertTrue(description.contains("\n"), name)
                XCTAssertTrue(description.contains(where: { $0.isASCII && $0.isLetter }), name)
                let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
                XCTAssertEqual(schema["type"] as? String, "object")
                XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
                XCTAssertFalse(name.contains(" "))
                XCTAssertFalse(name.contains("\n"))
            }
        }
        XCTAssertTrue(LocalAccessMCP.names.contains("access.request"))
        XCTAssertFalse(LocalAccessMCP.names.contains("access.approve"))
    }
}
