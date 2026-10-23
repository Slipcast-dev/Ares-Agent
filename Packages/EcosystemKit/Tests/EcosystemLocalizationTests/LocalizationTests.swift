import Foundation
import XCTest
@testable import EcosystemLocalization

final class LocalizationTests: XCTestCase {
    func testPreferenceOrderAndFallback() {
        XCTAssertEqual(AgentLanguage.resolve(preferredLanguages: ["de-DE", "ru_RU", "en-GB"]), .russian)
        XCTAssertEqual(AgentLanguage.resolve(preferredLanguages: ["en-US", "ru"]), .english)
        XCTAssertEqual(AgentLanguage.resolve(preferredLanguages: ["fr", "de"]), .english)
        XCTAssertEqual(AgentLanguage.resolve(preferredLanguages: []), .english)
    }

    func testExplicitLanguagesDoNotFollowProcessDefault() {
        let ru = AgentLocalization(language: .russian)
        let en = AgentLocalization(language: .english)
        XCTAssertTrue(ru.resourcesAvailable)
        XCTAssertTrue(en.resourcesAvailable)
        XCTAssertEqual(ru.text(.runtimeFailureTitle), "Не удалось запустить службу")
        XCTAssertEqual(en.text(.runtimeFailureTitle), "Unable to start the service")
        for key in AgentText.allCases {
            for l10n in [ru, en] {
                XCTAssertFalse(l10n.text(key).isEmpty)
                XCTAssertNotEqual(l10n.text(key), key.rawValue)
                XCTAssertNotEqual(l10n.text(key), "Localization resource unavailable.")
            }
        }
    }

    func testResourceKeysAndFormatTypesMatch() throws {
        var tables: [[String: String]] = []
        for language in AgentLanguage.allCases {
            let bundle = try XCTUnwrap(AgentLocalization(language: language).table)
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            XCTAssertEqual(Set(table.keys), Set(AgentText.allCases.map(\.rawValue)))
            XCTAssertEqual(table[AgentText.notificationTestTitle.rawValue]?.components(separatedBy: "%@").count, 2)
            tables.append(table)
        }
        XCTAssertEqual(Set(tables[0].keys), Set(tables[1].keys))
    }

    func testPluralBranches() {
        let counts = [0, 1, 2, 5, 11, 21, 101]
        XCTAssertEqual(counts.map { AgentLocalization(language: .russian).eventCount($0) },
                       ["0 событий", "1 событие", "2 события", "5 событий", "11 событий", "21 событие", "101 событие"])
        XCTAssertEqual(counts.map { AgentLocalization(language: .english).eventCount($0) },
                       ["0 events", "1 event", "2 events", "5 events", "11 events", "21 events", "101 events"])
    }

    func testNotificationSafeContentAndPlaceholder() {
        XCTAssertEqual(AgentLocalization(language: .english).notificationPreview(agent: .athena).title, "Athena: test notification")
        XCTAssertEqual(AgentLocalization(language: .russian).notificationPreview(agent: .ares).title, "Арес: тестовое уведомление")
        for language in AgentLanguage.allCases {
            let content = AgentLocalization(language: language).notificationPreview(agent: .ares)
            XCTAssertFalse(content.title.contains("%@"))
            XCTAssertFalse(content.body.contains("/Users/"))
        }
    }
}
