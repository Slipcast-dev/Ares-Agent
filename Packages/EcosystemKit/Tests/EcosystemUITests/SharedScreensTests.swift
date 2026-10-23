import AppKit
import Foundation
import SwiftUI
import XCTest
import EcosystemLocalIPC
import EcosystemLocalization
@testable import EcosystemUI

/// Все данные синтетические. Busy запрещает авто-refresh/action в preview;
/// dummy XPC client никогда не открывает соединение или пользовательский профиль.
@MainActor final class SharedScreensTests: XCTestCase {
    private func decode<T: Decodable>(_ object: [String: Any], as type: T.Type) throws -> T {
        try LocalWire.decode(type, JSONSerialization.data(withJSONObject: object))
    }
    private func client() throws -> Result<LocalRPCClient, Error> {
        let requirement = "cdhash H\"" + String(repeating: "0", count: 40) + "\""
        let endpoint = ["service": "fixture.unused", "clientRequirement": requirement]
        let config = try decode(["version": 1, "mode": "local-ad-hoc", "domain": "ares",
                                 "serverRequirement": requirement, "endpoints": ["gui": endpoint, "mcp": endpoint, "worker": endpoint]], as: LocalRuntimeConfiguration.self)
        return .success(LocalRPCClient(configuration: config, role: .gui))
    }
    private func render<V: View>(_ view: V, name: String, language: AgentLanguage, theme: ColorScheme) async throws {
        let host = NSHostingView(rootView: view.environment(\.agentLanguage, language).environment(\.colorScheme, theme)
            .frame(width: 640, height: 880).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 880)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        // Пустой/прозрачный compositor frame не считается screenshot приёмкой.
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert(Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255))
                }
            }
            if colors.count > 8 { break }
        }
        XCTAssertGreaterThan(colors.count, 8, "Empty offscreen snapshot: " + name)
        if let output = ProcessInfo.processInfo.environment["ECOSYSTEM_UI_SNAPSHOTS_DIR"] {
            let folder = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("shared-\(name)-\(language.rawValue)-\(theme == .light ? "light" : "dark").png"))
        }
    }
    func testSharedScreensInBothLanguagesAndThemes() async throws {
        let access = AccessModel(client: try client()); access.busy = true
        let root = UUID()
        access.scope = LocalAccessScope(roots: [.init(id: root, name: "Example folder")], capabilities: ["events.read", "file.scan", "file.search", "rule.run"])
        var draft = LocalAccessDraft(); draft.client = .codex; draft.roots = [root]; draft.capabilities = access.scope.capabilities; draft.dataClass = .fileMetadata
        let draftObject = try JSONSerialization.jsonObject(with: LocalWire.encode(draft))
        let plan = try decode(["id": UUID().uuidString, "draft": draftObject, "fingerprint": draft.fingerprint,
                               "expiresAt": Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate, "consumed": false], as: LocalAccessPlan.self)
        let automation = AutomationModel(client: try client()); automation.busy = true
        automation.status = try decode(["settings": ["paused": false, "notificationsEnabled": false, "createdAt": 0],
                                        "notificationAuthorization": "denied", "pendingEvents": 0], as: LocalAutomationStatus.self)
        automation.login = try decode(["configured": false, "registered": true, "disabledBySystem": false], as: LocalLoginStatus.self)
        let recovery = LocalRecoveryViewModel(client: .failure(LocalRuntimeFailure.unavailable))
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                try await render(Form { LocalAccessSection(model: access); Section { PlannedHermesConnection() } }.formStyle(.grouped), name: "access", language: language, theme: theme)
                try await render(AccessReviewContent(model: access, plan: plan, l10n: AgentLocalization(language: language)), name: "approval", language: language, theme: theme)
                try await render(Form { LocalAutomationSection(model: automation) }.formStyle(.grouped), name: "automation", language: language, theme: theme)
                try await render(Form { LocalRecoverySection(model: recovery) }.formStyle(.grouped), name: "recovery", language: language, theme: theme)
            }
        }
        XCTAssertEqual(access.scope.capabilities, ["events.read", "file.scan", "file.search", "rule.run"])
    }
    func testKnownErrorsTranslateAndDoNotExposeRawNSErrorText() async {
        let client: Result<LocalRPCClient, Error> = .failure(NSError(domain: "/Users/private/SECRET_TOKEN", code: 1))
        let access = AccessModel(client: client); await access.refresh()
        XCTAssertEqual(access.error, .operationFailed)
        let recovery = LocalRecoveryViewModel(client: client); await recovery.refresh()
        let en = AgentLocalization(language: .english)
        XCTAssertFalse(recovery.hasSnapshot)
        XCTAssertEqual(recovery.message?.localized(using: en), "The agent could not complete the operation.")
        XCTAssertFalse(recovery.message?.localized(using: en).contains("SECRET_TOKEN") ?? true)
        XCTAssertEqual(AccessLabels.operation("file.scan", using: en), "Scan")
        XCTAssertEqual(AccessLabels.operation("future.unknown", using: en), "future.unknown")
        let automation = AutomationModel(client: client); await automation.refresh()
        XCTAssertEqual(automation.error, .partialData)
    }
}
