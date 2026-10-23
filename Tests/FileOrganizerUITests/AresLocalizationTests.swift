import AppKit
import SwiftUI
import XCTest
import FileOrganizerCore
import EcosystemLocalIPC
import EcosystemLocalization
import EcosystemUI
@testable import FileOrganizer

/// Проверяем ресурсы и реальное представление без запуска App/bootstrap и без
/// чтения личных профилей. Все БД и синтетические данные принадлежат тесту.
@MainActor final class AresLocalizationTests: XCTestCase {
    private let ru = AresLocalization(language: .russian)
    private let en = AresLocalization(language: .english)
    private var source: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FileOrganizer/Resources")
    }
    func testResourceParityAndEveryTemplateRendersInBothLanguages() throws {
        func read(_ language: String) throws -> [String: String] {
            try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: source.appendingPathComponent(language + ".lproj/Ares.strings")), format: nil) as? [String: String])
        }
        let russian = try read("ru"), english = try read("en")
        XCTAssertEqual(Set(russian.keys), Set(english.keys))
        XCTAssertGreaterThan(russian.count, 200)
        for key in russian.keys {
            let original = try XCTUnwrap(russian[key]), translated = try XCTUnwrap(english[key])
            let count = original.components(separatedBy: "%@").count - 1
            XCTAssertEqual(count, translated.components(separatedBy: "%@").count - 1, key)
            XCTAssertNil(translated.range(of: "[А-Яа-яЁё]", options: .regularExpression), key)
            for l10n in [ru, en] {
                let rendered = l10n.render(AresMessage(key, args: Array(repeating: "SAMPLE%@100%", count: count)))
                XCTAssertFalse(rendered.isEmpty); XCTAssertNotEqual(rendered, AresLocalization.unavailable, key)
                if count > 0 { XCTAssertTrue(rendered.contains("SAMPLE%@100%")) }
            }
        }
    }
    func testDeferredMessagesPreserveUserTextAndValidateArity() {
        let original = "Обзор/Фото %@ SECRET 100%"
        XCTAssertEqual(en.render(.verbatim(original)), original)
        XCTAssertEqual(en.format("Убрать доступ к папке %@", original), "Revoke access to folder " + original)
        XCTAssertEqual(en.text("Убрать доступ к папке %@"), AresLocalization.unavailable)
        XCTAssertEqual(en.text("unknown-user-key"), AresLocalization.unavailable)
        let deferred = AresMessage("Убрать доступ к папке %@", args: [original])
        XCTAssertTrue(ru.render(deferred).hasPrefix("Убрать доступ"))
        XCTAssertTrue(en.render(deferred).hasPrefix("Revoke access"))
        let frozen = ConfirmationLanguage(language: .russian)
        XCTAssertTrue(AresLocalization(language: frozen.language).render(deferred).hasPrefix("Убрать доступ"))
    }
    func testNavigationAndFilterIdentifiersStayStable() {
        XCTAssertEqual(AppSection.allCases.map(\.rawValue), ["overview", "files", "duplicates", "rules", "history", "settings"])
        XCTAssertEqual(AppSection.allCases.map { en.text($0.title) }, ["Overview", "Files", "Duplicates", "Rules", "Tasks and history", "Settings"])
        XCTAssertEqual(FileCollection.all.rawValue, "Все файлы")
        XCTAssertEqual(RuleActionKind.copy.rawValue, "copy")
        for event in RuleEvent.allCases { XCTAssertNotEqual(en.text(event.title), AresLocalization.unavailable) }
        for action in RuleActionKind.allCases { XCTAssertNotEqual(en.text(action.title), AresLocalization.unavailable) }
    }
    func testCaseDistinctAndLongUserPathsRemainSearchableAfterLanguageSwitch() {
        let container = AppContainer(databaseURL: URL(fileURLWithPath: "/dev/null"), localClientOverride: .failure(LocalRuntimeFailure.unavailable))
        let model = FilesViewModel(container: container)
        let root = UUID(), now = Date()
        model.records = ["Фото/" + String(repeating: "LongFolder/", count: 20) + "Report.TXT", "Фото/report.txt", "Фото/empty.bin"].enumerated().map { index, path in
            FileRecord(rootID: root, relativePath: path, fileName: (path as NSString).lastPathComponent,
                fileExtension: index == 2 ? "bin" : "txt", byteSize: index == 2 ? 0 : 200_000_000,
                createdAt: now, modifiedAt: now, typeIdentifier: nil)
        }
        model.query = "REPORT"; XCTAssertEqual(model.visibleRecords.count, 2)
        let ids = model.visibleRecords.map(\.id)
        _ = en.text(FileCollection.large.rawValue); model.collection = .large
        XCTAssertEqual(model.visibleRecords.map(\.id), ids)
        model.query = "missing"; XCTAssertTrue(model.visibleRecords.isEmpty)
        model.query = ""; model.collection = .all; XCTAssertEqual(model.visibleRecords.count, 3)
    }
    func testUnavailableFileReportsFailureWithoutOpeningScope() async {
        let container = AppContainer(databaseURL: URL(fileURLWithPath: "/dev/null"), localClientOverride: .failure(LocalRuntimeFailure.unavailable))
        let model = FilesViewModel(container: container)
        let record = FileRecord(rootID: UUID(), relativePath: "missing.txt", fileName: "missing.txt", fileExtension: "txt", byteSize: 1, createdAt: nil, modifiedAt: nil, typeIdentifier: nil)
        model.open(record, preview: true)
        for _ in 0..<30 where model.errorMessage == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.errorMessage); XCTAssertNil(model.previewURL)
    }
}
