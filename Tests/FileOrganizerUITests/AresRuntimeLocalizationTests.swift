import Foundation
import XCTest
import EcosystemLocalization
import EcosystemLocalIPC
@testable import FileOrganizerCore
@testable import FileOrganizer

/// Ошибки переводятся по типу без чтения личных профилей и запуска приложений.
/// Подмена текста NSError известным ключом не должна выдавать typed-семантику.
@MainActor
final class AresRuntimeLocalizationTests: XCTestCase {
    func testEveryKnownCoreErrorRendersBothLanguagesWithoutChangingLegacyCodes() throws {
        let errors: [any RuntimeLocalizedError] = [
            RuleExecutionError.invalidConfiguration, RuleExecutionError.destinationExists,
            RuleExecutionError.verificationFailed, RuleExecutionError.timeout, RuleExecutionError.busy,
            RuleExecutionError.accessRevoked, RuleExecutionError.unsafePath,
            RuleExecutionError.contentConsentRequired, RuleExecutionError.notificationsDisabled,
            RulePolicyError.invalid, RulePolicyError.permission, RulePolicyError.stale,
            RulePolicyError.quota, RulePolicyError.guiRequired, RulePolicyError.space,
            AresFileFailure.staleSnapshot, AresFileFailure.snapshotRequired,
            AresFileFailure.unsafePath, AresFileFailure.capacityExceeded,
            AresFileFailure.invalidCursor, AresFileFailure.hashesNotComputed,
            AuthorizedRootAccessError.notDirectory, AuthorizedRootAccessError.missingBookmark,
            AuthorizedRootAccessError.staleBookmark, AuthorizedRootAccessError.accessDenied,
            TaskCoordinatorError.rootBusy, FileIndexingError.enumerationUnavailable
        ]
        let ru = AgentLocalization(language: .russian), en = AgentLocalization(language: .english)
        let fallback = en.runtimeText("Не удалось выполнить операцию.")
        for error in errors {
            let original = error.localizedDescription
            let russian = ru.runtimeError(error), english = en.runtimeError(error)
            XCTAssertEqual(russian, original)
            XCTAssertFalse(english.isEmpty)
            XCTAssertNotEqual(english, fallback)
            XCTAssertNil(english.range(of: "[А-Яа-яЁё]", options: .regularExpression))
            XCTAssertEqual(error.localizedDescription, original)
        }
        XCTAssertEqual(AresFileFailure.staleSnapshot.rawValue, "staleSnapshot")
        XCTAssertEqual(AresFileFailure.staleSnapshot.knownCode.rawValue, "STALE_SNAPSHOT")
        XCTAssertEqual(RulePolicyError.permission.rawValue, "permission")
        XCTAssertEqual(RulePolicyError.permission.knownCode.rawValue, "PERMISSION_DENIED")
        XCTAssertEqual(RuleActionKind.copy.rawValue, "copy")
    }

    func testUntrustedErrorTextNeverBecomesAKeyOrLeaksToEitherUIOrClient() {
        let ru = AgentLocalization(language: .russian), en = AgentLocalization(language: .english)
        for text in ["Проверьте настройки правила и папку назначения.", "/Users/private/SECRET_TOKEN %@100%"] {
            let foreign = NSError(domain: "untrusted", code: 42, userInfo: [NSLocalizedDescriptionKey: text])
            let message = AresErrorLocalization.message(for: foreign)
            for language in AgentLanguage.allCases {
                let l10n = AgentLocalization(language: language)
                let expected = l10n.runtimeText("Не удалось выполнить операцию.")
                XCTAssertEqual(l10n.runtimeError(foreign), expected)
                XCTAssertEqual(l10n.runtimeMessage(message), expected)
                XCTAssertEqual(AresLocalization(language: language).render(.runtime(message)), expected)
            }
            XCTAssertEqual(foreign.localizedDescription, text)
        }
        // Verbatim остаётся допустимым только для явно выделенных данных:
        // receipt/history не должны случайно переводиться по совпадению ключа.
        let originalHistory = "Проверьте настройки правила и папку назначения."
        XCTAssertEqual(en.runtimeMessage(.verbatim(originalHistory)), originalHistory)
        XCTAssertEqual(ru.runtimeMessage(.verbatim(originalHistory)), originalHistory)
        let cancelled = AresErrorLocalization.message(for: CancellationError())
        XCTAssertEqual(en.runtimeMessage(cancelled), "Execution cancelled.")
        XCTAssertEqual(ru.runtimeMessage(cancelled), "Выполнение отменено.")
    }

    func testFileModelKeepsDeferredTypedFailureAcrossLanguageSwitch() async throws {
        // Fail-closed клиент не открывает /dev/null как БД и не выполняет XPC.
        let container = AppContainer(databaseURL: URL(fileURLWithPath: "/dev/null"),
            localClientOverride: .failure(LocalRuntimeFailure.unavailable))
        let model = FilesViewModel(container: container)
        await model.load()
        let message = try XCTUnwrap(model.errorMessage)
        let ru = AresLocalization(language: .russian).render(message)
        let en = AresLocalization(language: .english).render(message)
        XCTAssertNotEqual(ru, en)
        XCTAssertFalse(en.isEmpty)
        XCTAssertNil(en.range(of: "[А-Яа-яЁё]", options: .regularExpression))
        XCTAssertEqual(model.errorMessage, message)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertNil(model.previewURL)
        let description = RuntimeLocalization.bilingual("Список разрешённых папок; только чтение.")
        XCTAssertTrue(description.contains("Список разрешённых папок"))
        XCTAssertTrue(description.contains("Lists authorized folders; read-only."))
    }
}
