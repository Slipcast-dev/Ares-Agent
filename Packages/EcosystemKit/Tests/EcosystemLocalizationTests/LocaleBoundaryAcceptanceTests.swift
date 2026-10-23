import Foundation
import XCTest
@testable import EcosystemLocalization

/// Язык текста и региональные данные — разные настройки. Форматируем образцы
/// явно, не изменяя AppleLanguages, Locale.current, часовой пояс или личный профиль.
final class LocaleBoundaryAcceptanceTests: XCTestCase {
    func testRegionalDateTimeDecimalPercentAndByteStringsSurviveLanguageRendering() throws {
        let date = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC.
        let calendar = Calendar.current
        let zone = TimeZone.current
        let locale = Locale.current.identifier
        let decimal = NumberFormatter()
        decimal.numberStyle = .decimal
        decimal.maximumFractionDigits = 2
        decimal.usesGroupingSeparator = false
        let percent = NumberFormatter()
        percent.numberStyle = .percent
        percent.maximumFractionDigits = 1
        var regions: [String: [String]] = [:]
        for identifier in ["en_US", "ru_RU"] {
            decimal.locale = Locale(identifier: identifier)
            percent.locale = Locale(identifier: identifier)
            let decimalValue = try XCTUnwrap(decimal.string(from: NSNumber(value: 1234.5)))
            let percentValue = try XCTUnwrap(percent.string(from: NSNumber(value: 0.125)))
            XCTAssertTrue(decimalValue.contains(identifier == "en_US" ? "." : ","))
            XCTAssertTrue(percentValue.contains("%"))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: identifier)
            formatter.calendar = Calendar(identifier: .gregorian)
            var samples = [decimalValue, percentValue,
                           ByteCountFormatter.string(fromByteCount: 1536, countStyle: .file)]
            for offset in [3 * 3600, -8 * 3600] {
                formatter.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: offset))
                for pattern in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd h:mm a"] {
                    formatter.dateFormat = pattern
                    samples.append(formatter.string(from: date))
                }
            }
            XCTAssertNotEqual(samples[3], samples[4], "12/24-hour styles must differ")
            XCTAssertNotEqual(samples[3], samples[5], "Timezone must affect the supplied timestamp")
            regions[identifier] = samples
            for language in AgentLanguage.allCases {
                let l10n = AgentLocalization(language: language)
                for sample in samples {
                    let message = RuntimeMessage("Локальная операция Athena: %@", args: [sample])
                    let prefix = language == .russian ? "Локальная операция Athena: " : "Local Athena operation: "
                    XCTAssertEqual(l10n.runtimeMessage(message), prefix + sample)
                    XCTAssertEqual(l10n.message(.folders, .text(sample)),
                                   (language == .russian ? "Папки: " : "Folders: ") + sample)
                }
            }
        }
        XCTAssertNotEqual(regions["en_US"]?.first, regions["ru_RU"]?.first)
        XCTAssertEqual(Locale.current.identifier, locale)
        XCTAssertEqual(TimeZone.current, zone)
        XCTAssertEqual(Calendar.current, calendar)
    }

    func testUTF8LongPathsAndPlaceholderLookingArgumentsAreNeverReinterpreted() {
        // Несуществующие пути являются только данными: тест не создаёт файлы
        // и не пытается читать профиль, даже если текст похож на resource key.
        let path = "/Тест/" + String(repeating: "Long folder 😀/", count: 100) + "Cafe\u{301} 日本語 %@ %s %1$@ 100%.txt"
        XCTAssertLessThan(path.count, 4097)
        let samples = [path, "runtime.error.cancelled", "maintenance.removeReady", "%@ %@ %s %n %% 100%", "\u{FEFF}Русский\nEnglish\t😀"]
        for language in AgentLanguage.allCases {
            let l10n = AgentLocalization(language: language)
            for sample in samples {
                let result = l10n.runtimeText("Локальная операция Athena: %@", sample)
                let prefix = language == .russian ? "Локальная операция Athena: " : "Local Athena operation: "
                XCTAssertEqual(Data(result.utf8), Data((prefix + sample).utf8))
                XCTAssertEqual(Data(l10n.runtimeMessage(.verbatim(sample)).utf8), Data(sample.utf8))
                XCTAssertEqual(l10n.message(.folders, .text(sample)),
                               (language == .russian ? "Папки: " : "Folders: ") + sample)
            }
            let fallback = l10n.runtimeText("runtime.error.unknown")
            XCTAssertEqual(l10n.runtimeText("Локальная операция Athena: %@"), fallback)
            XCTAssertEqual(l10n.runtimeText("Локальная операция Athena: %@", "one", "two"), fallback)
            XCTAssertEqual(l10n.runtimeMessage(.verbatim(String(repeating: "😀", count: 4097))), fallback)
        }
    }
}
