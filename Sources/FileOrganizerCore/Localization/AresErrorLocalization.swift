import Foundation
import EcosystemLocalization

/// Ошибки связываются с ключами по Swift-типу и case, а не по совпадению
/// внешнего текста. Исходные errorDescription и wire codes остаются прежними.

extension RuleExecutionError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .invalidConfiguration: .init("Проверьте настройки правила и папку назначения.")
        case .destinationExists: .init("Назначение уже существует; перезапись запрещена.")
        case .verificationFailed: .init("Проверка результата не прошла. Исходник сохранён.")
        case .timeout: .init("Операция превысила время ожидания.")
        case .busy: .init("Уже выполняется другое правило.")
        case .accessRevoked: .init("Доступ к папке отозван или диск отключён.")
        case .unsafePath: .init("Путь выходит за пределы разрешённой папки или содержит ссылку.")
        case .contentConsentRequired: .init("Включите локальное чтение содержимого в редакторе правила.")
        case .notificationsDisabled: .init("Сначала разрешите уведомления кнопкой в разделе «Правила».")
        }
    }
}

extension RulePolicyError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .invalid: .init("Проверьте параметры, связи и циклы правила.")
        case .permission: .init("Нужно локальное подтверждение этой версии правила или плана.")
        case .stale: .init("План устарел или файлы изменились. Создайте новый предварительный просмотр.")
        case .quota: .init("Превышен лимит объектов, исходных данных или общий бюджет цепочки правил.")
        case .guiRequired: .init("Действие требует интерфейса или разрешения macOS и не выполнено фоновым агентом.")
        case .space: .init("Недостаточно свободного места с учётом результата и резерва.")
        }
    }
}

extension AresFileFailure: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .staleSnapshot: .init("Файлы изменились. Обновите список файлов и повторите запрос.")
        case .snapshotRequired: .init("Сначала обновите список файлов этой папки.")
        case .unsafePath: .init("Файл недоступен или путь содержит ссылку.")
        case .capacityExceeded: .init("Папка превышает лимит этого анализа: 100 000 файлов.")
        case .invalidCursor: .init("Страница не соответствует текущему запросу. Начните просмотр заново.")
        case .hashesNotComputed: .init("Сначала выполните вычисление дубликатов.")
        }
    }
}

extension AuthorizedRootAccessError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .notDirectory: .init("Можно добавить только папку.")
        case .missingBookmark: .init("Для этой папки не сохранено разрешение доступа.")
        case .staleBookmark: .init("Разрешение для папки устарело. Выберите её снова.")
        case .accessDenied: .init("macOS не предоставила доступ к выбранной папке.")
        }
    }
}

extension TaskCoordinatorError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self { case .rootBusy: .init("Для этой папки уже выполняется задача.") }
    }
}

extension FileIndexingError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self { case .enumerationUnavailable: .init("Не удалось начать сканирование выбранной папки.") }
    }
}

/// UI хранит только безопасный typed message, чтобы уже полученная ошибка
/// меняла язык вместе с экраном без утечки путей и произвольного текста NSError.
public enum AresErrorLocalization {
    public static func message(for error: Error) -> RuntimeMessage {
        if let localized = error as? any RuntimeLocalizedError { return localized.runtimeMessage }
        if error is CancellationError { return .init("Выполнение отменено.") }
        return .init("Не удалось выполнить операцию.")
    }
}

extension AgentRegistrationError: RuntimeLocalizedError {
    public var runtimeMessage: RuntimeMessage {
        switch self {
        case .unavailable: return RuntimeMessage("ares.error.registration.unavailable")
        case .conflict: return RuntimeMessage("ares.error.registration.conflict")
        case .invalidConfiguration: return RuntimeMessage("ares.error.registration.invalidConfiguration")
        case .changedDuringWrite: return RuntimeMessage("ares.error.registration.changedDuringWrite")
        case .commandFailed: return RuntimeMessage("ares.error.registration.commandFailed")
        case .timedOut: return RuntimeMessage("ares.error.registration.timedOut")
        }
    }
}
