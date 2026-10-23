import Foundation
import XCTest
@testable import EcosystemLocalization

final class SharedLocalizationTests: XCTestCase {
    func testSharedTablesHaveIdenticalTypedKeysAndValidFormats() throws {
        var keys: [Set<String>] = []
        for language in AgentLanguage.allCases {
            let l10n = AgentLocalization(language: language)
            let bundle = try XCTUnwrap(l10n.table)
            let url = try XCTUnwrap(bundle.url(forResource: "Shared", withExtension: "strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            keys.append(Set(table.keys))
            XCTAssertEqual(Set(table.keys), Set(SharedText.allCases.map(\.rawValue)))
            for key in SharedText.allCases {
                let format = try XCTUnwrap(table[key.rawValue])
                XCTAssertEqual(format.components(separatedBy: "%@").count - 1, key.argumentKinds.count, key.rawValue)
                XCTAssertFalse(format.replacingOccurrences(of: "%@", with: "").contains("%"), key.rawValue)
                let arguments = key.argumentKinds.map { $0 == .count ? SharedArgument.count(21) : .text("Sample 100%") }
                let result = l10n.render(key, arguments: arguments)
                XCTAssertFalse(result.isEmpty); XCTAssertNotEqual(result, key.rawValue)
                XCTAssertNotEqual(result, "Localization resource unavailable.", key.rawValue)
                if language == .english { XCTAssertNil(result.range(of: "[А-Яа-яЁё]", options: .regularExpression), key.rawValue) }
            }
        }
        XCTAssertEqual(keys[0], keys[1])
    }
    func testTypedParametersAndLiteralPercentAreSafe() {
        let en = AgentLocalization(language: .english)
        XCTAssertEqual(en.message(.grantCounts, .count(1), .count(0)), "Permissions: 1; awaiting approval: 0")
        XCTAssertEqual(en.message(.folders, .text("100% %@ sample")), "Folders: 100% %@ sample")
        XCTAssertEqual(en.message(.grantCounts, .text("1"), .text("0")), "Localization resource unavailable.")
        XCTAssertEqual(en.text(.grantCounts), "Localization resource unavailable.")
    }
    func testConfirmationLanguageDoesNotFollowLaterSelection() {
        let opened = ConfirmationLanguage(language: .russian)
        let later = AgentLocalization(language: .english)
        XCTAssertEqual(opened.localization.text(.stopConfirmTitle), "Аварийно остановить этого агента?")
        XCTAssertEqual(later.text(.stopConfirmTitle), "Emergency stop this agent?")
        XCTAssertTrue(opened.localization.text(.stopConfirmBody).contains("не откатываются"))
        XCTAssertEqual(ConfirmationLanguage(language: later.language).localization.text(.stopConfirmTitle), "Emergency stop this agent?")
    }
    func testPauseStopResumeAndRecoveryRemainDifferentDecisions() {
        let en = AgentLocalization(language: .english)
        XCTAssertTrue(en.text(.pauseConfirmBody).contains("latest 100"))
        XCTAssertTrue(en.text(.pauseConfirmBody).contains("manual requests remain available"))
        XCTAssertTrue(en.text(.stopConfirmBody).contains("until explicitly resumed"))
        XCTAssertTrue(en.text(.resumeConfirmBody).contains("not repeated automatically"))
        XCTAssertTrue(en.text(.recoveryConfirmBody).contains("will not be repeated"))
        XCTAssertNotEqual(en.text(.cancel), en.text(.resume))
    }
}
