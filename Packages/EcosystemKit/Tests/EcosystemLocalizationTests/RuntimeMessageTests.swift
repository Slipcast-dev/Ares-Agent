import Foundation
import XCTest
@testable import EcosystemLocalization

final class RuntimeMessageTests: XCTestCase {
    func testCompleteCatalogueAndSafeSubstitutionInBothLanguages() {
        let ru = AgentLocalization(language: .russian), en = AgentLocalization(language: .english)
        XCTAssertEqual(Set(ru.runtimeCatalogue.keys), Set(en.runtimeCatalogue.keys))
        XCTAssertGreaterThanOrEqual(ru.runtimeCatalogue.count, 171)
        for l10n in [ru, en] {
            XCTAssertTrue(l10n.runtimeCatalogueComplete)
            for (key, value) in l10n.runtimeCatalogue {
                XCTAssertFalse(value.isEmpty)
                let count = value.components(separatedBy: "%@").count - 1
                let sample = "External %@ 100%"
                XCTAssertEqual(l10n.runtimeMessage(RuntimeMessage(key, args: Array(repeating: sample, count: count))),
                    value.components(separatedBy: "%@").joined(separator: sample), key)
            }
        }
        for value in en.runtimeCatalogue.values {
            XCTAssertNil(value.range(of: "[А-Яа-яЁё]", options: .regularExpression))
        }
    }
    func testUnknownErrorAndKeyCannotRevealExternalErrorOrClaimSuccess() {
        let en = AgentLocalization(language: .english)
        let error = NSError(domain: "SECRET_TOKEN /private/data", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Everything succeeded SECRET_TOKEN"])
        XCTAssertEqual(en.runtimeError(error), "The operation could not be completed.")
        XCTAssertEqual(en.runtimeText("unknown.input.key"), "The operation could not be completed.")
        XCTAssertEqual(en.runtimeText("maintenance.removeReady"), "The operation could not be completed.")
        XCTAssertEqual(en.runtimeMessage(.verbatim("%@ unchanged")), "%@ unchanged")
        XCTAssertEqual(en.runtimeMessage(.verbatim(String(repeating: "x", count: 4097))), "The operation could not be completed.")
        XCTAssertEqual(en.runtimeError(CancellationError()), "Execution was cancelled.")
    }
    func testBilingualDescriptionsAreIndependentOfMutableGUISettings() {
        let key = "Общая операция локального агента: %@"
        let text = RuntimeLocalization.bilingual(key, "task.get")
        XCTAssertEqual(text, "Общая операция локального агента: task.get\nShared local agent operation: task.get")
        XCTAssertTrue(text.contains("task.get"))
        // Только представление: этот вызов не читает/пишет profile sidecar.
        XCTAssertFalse(text.contains("runtime.error"))
    }
}
