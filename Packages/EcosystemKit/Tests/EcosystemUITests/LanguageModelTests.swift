import XCTest
import AppKit
import SwiftUI
import EcosystemLocalization
import EcosystemLocalIPC
@testable import EcosystemUI

private actor LanguageFixture {
    private var state = LocalLanguageStatus(preference: .system, effectiveLanguage: .english)
    private var failRead = false
    private var loseSetReply = false
    private(set) var operations: [String] = []
    func failReads(_ value: Bool) { failRead = value }
    func loseReply() { loseSetReply = true }
    func call(_ operation: String, _ change: LocalLanguageChange?) throws -> LocalLanguageStatus {
        operations.append(operation)
        if operation == "language.get", failRead { throw LocalRuntimeFailure.unavailable }
        if let change {
            state = LocalLanguageStatus(preference: change.preference, effectiveLanguage: change.preference.resolve(preferredLanguages: ["en"]))
            if loseSetReply { throw LocalRuntimeFailure.unavailable }
        }
        return state
    }
}

@MainActor final class LanguageModelTests: XCTestCase {
    func testOpeningSettingsOnlyReadsAndChangingChoiceUpdatesEffectiveLanguage() async {
        let fixture = LanguageFixture(), model = LocalLanguageModel(transport: { try await fixture.call($0, $1) })
        await model.refresh()
        let initial = await fixture.operations; XCTAssertEqual(initial, ["language.get"])
        XCTAssertTrue(model.loaded)
        await model.select(.ru)
        XCTAssertEqual(model.state.effectiveLanguage, .russian)
        XCTAssertFalse(model.busy)
        let history = await fixture.operations; XCTAssertEqual(history, ["language.get", "language.set"])
    }
    func testLostReplyReconcilesByReadWithoutRepeatingMutation() async {
        let fixture = LanguageFixture(), model = LocalLanguageModel(transport: { try await fixture.call($0, $1) })
        await model.refresh(); await fixture.loseReply(); await model.select(.ru)
        XCTAssertEqual(model.state.preference, .ru); XCTAssertTrue(model.loaded)
        let history = await fixture.operations
        XCTAssertEqual(history, ["language.get", "language.set", "language.get"])
        XCTAssertEqual(model.issue, .languageUnconfirmed)
    }
    func testReadFailurePreservesLastChoiceAndDisablesSavingUntilRefresh() async {
        let fixture = LanguageFixture(), model = LocalLanguageModel(transport: { try await fixture.call($0, $1) })
        await model.refresh(); await model.select(.ru)
        await fixture.failReads(true); await model.refresh()
        XCTAssertFalse(model.loaded); XCTAssertEqual(model.state.preference, .ru)
        await model.select(.en)
        XCTAssertEqual(model.state.preference, .ru)
        await fixture.failReads(false); await model.refresh()
        XCTAssertTrue(model.loaded); XCTAssertNil(model.issue)
    }
    func testAgentModelsRemainIndependentAndNewModelRestoresRuntimeChoice() async {
        let a = LanguageFixture(), b = LanguageFixture()
        let first = LocalLanguageModel(transport: { try await a.call($0, $1) })
        let second = LocalLanguageModel(transport: { try await b.call($0, $1) })
        await first.refresh(); await second.refresh(); await first.select(.ru)
        XCTAssertEqual(second.state.preference, .system)
        let reopened = LocalLanguageModel(transport: { try await a.call($0, $1) })
        await reopened.refresh(); XCTAssertEqual(reopened.state.preference, .ru)
    }
    func testPickerRendersBothLanguagesAndThemes() async throws {
        let fixture = LanguageFixture(), model = LocalLanguageModel(transport: { try await fixture.call($0, $1) })
        await model.refresh()
        for choice in [AgentLanguagePreference.ru, .en] {
            await model.select(choice)
            for theme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: Form { LocalLanguageSection(model: model) }
                    .formStyle(.grouped).environment(\.colorScheme, theme)
                    .frame(width: 560, height: 260))
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 260)
                let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                if let output = ProcessInfo.processInfo.environment["ECOSYSTEM_UI_SNAPSHOTS_DIR"] {
                    let folder = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("language-\(choice.rawValue)-\(theme == .light ? "light" : "dark").png"))
                }
            }
        }
    }
}
