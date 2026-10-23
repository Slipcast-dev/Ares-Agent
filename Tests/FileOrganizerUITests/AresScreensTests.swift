import AppKit
import SwiftUI
import XCTest
import FileOrganizerCore
import EcosystemLocalIPC
import EcosystemLocalization
import EcosystemUI
@testable import FileOrganizer

/// Контентные снимки не нажимают кнопки: собственная SQLite содержит только
/// синтетический индекс; регистрация клиентов и системные разрешения не вызываются.
@MainActor final class AresScreensTests: XCTestCase {
    private func render<V: View>(_ view: V, name: String, language: AgentLanguage, theme: ColorScheme) async throws {
        let host = NSHostingView(rootView: view.environment(\.agentLanguage, language).environment(\.colorScheme, theme)
            .frame(width: 900, height: 920).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 920)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var colors = Set<Int>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert(Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255))
                }
            }
            if colors.count > 8 { break }
        }
        XCTAssertGreaterThan(colors.count, 8, "Empty offscreen frame: " + name)
        if let path = ProcessInfo.processInfo.environment["ECOSYSTEM_UI_SNAPSHOTS_DIR"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent("ares-\(name)-\(language.rawValue)-\(theme == .light ? "light" : "dark").png"))
        }
    }
    func testAresScreensInBothLanguagesAndThemes() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/ares-ui-l10n-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let container = AppContainer(databaseURL: base.appendingPathComponent("fixture.sqlite"), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = AuthorizedRoot(displayName: "Мои документы — example folder", relativePathHint: base.appendingPathComponent("Example").path)
        // Bookmark фиктивный и никогда не разрешается: в этом тесте только чтение индекса.
        try await container.fileRepository.save(root: root, bookmarkData: Data())
        let rows = ["Проекты/Report.TXT", "Проекты/report.txt", String(repeating: "LongFolder/", count: 12) + "example.pdf"].map { path in
            FileRecord(rootID: root.id, relativePath: path, fileName: (path as NSString).lastPathComponent,
                fileExtension: (path as NSString).pathExtension.lowercased(), byteSize: 200_000_000,
                createdAt: Date(), modifiedAt: Date(), typeIdentifier: nil)
        }
        try await container.fileRepository.replaceIndex(records: rows, forRootID: root.id)
        var rule = AutomationRule(); rule.rootID = root.id; rule.name = "Моё правило — user title"; rule.actions = [RuleAction(kind: .copy)]
        rule.actions[0].destinationRootID = root.id
        try await container.fileRepository.saveRuleObject(rule, id: rule.id.uuidString, table: .rules)
        var run = RuleRun(rule: rule, origin: "manual"); run.status = "completed"; run.matchedCount = 3
        try await container.fileRepository.saveRuleObject(run, id: run.id.uuidString, table: .runs)
        let overview = OverviewViewModel(container: container); overview.load()
        for _ in 0..<30 where overview.roots.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(overview.roots.map(\.id), [root.id])
        let model = RulesViewModel(container: container); await model.load()
        let object: [String: Any] = ["id": UUID().uuidString, "ruleID": rule.id.uuidString, "name": rule.name, "kind": "run",
            "revision": "fixture-revision", "fingerprint": "fixture-fingerprint", "expiresAt": Date().addingTimeInterval(600).timeIntervalSinceReferenceDate,
            "fileCount": rows.count, "byteSize": 600_000_000, "maximumFiles": 1000, "maximumBytes": 1_073_741_824,
            "sourceRootID": root.id.uuidString, "destinationRootIDs": [root.id.uuidString], "source": root.displayName,
            "destinations": [root.displayName], "actions": [RuleActionKind.copy.title], "files": rows.map(\.relativePath), "approved": false]
        let plan = try LocalWire.decode(RulePlanSummary.self, JSONSerialization.data(withJSONObject: object))
        model.reviewingFiles = rows.map(\.relativePath)
        let connections = AgentConnectionsViewModel(container: container)
        connections.isRegistering = true
        connections.registrationMessages = [.codex: .verbatim("fixture: disconnected"), .harness: .verbatim("fixture: disconnected")]
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                try await render(OverviewView(viewModel: overview), name: "overview", language: language, theme: theme)
                try await render(FilesView(container: container), name: "files", language: language, theme: theme)
                try await render(DuplicatesView(viewModel: overview), name: "duplicates", language: language, theme: theme)
                try await render(RulesView(container: container), name: "rules", language: language, theme: theme)
                try await render(RuleEditorView(rule: rule, roots: [root], rules: [rule], errorMessage: nil, save: { _ in XCTFail("Snapshot must not save") }), name: "editor", language: language, theme: theme)
                try await render(RulePlanReviewView(model: model, plan: plan, language: language), name: "plan", language: language, theme: theme)
                try await render(RuleHistoryView(container: container), name: "history", language: language, theme: theme)
                try await render(Form { AgentSettingsSections(model: connections) }.formStyle(.grouped), name: "settings", language: language, theme: theme)
            }
        }
        XCTAssertFalse(plan.approved)
        let persisted = try await container.fileRepository.ruleObjects(AutomationRule.self, table: .rules)
        XCTAssertEqual(persisted, [rule])
    }
}
