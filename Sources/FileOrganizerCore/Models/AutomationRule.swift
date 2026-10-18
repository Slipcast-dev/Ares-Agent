import Foundation

/// Значения rawValue сохраняются в SQLite, поэтому подписи UI отделены от
/// идентификаторов. Неизвестные события никогда не запускаются как ручные.
public enum RuleEvent: String, Codable, CaseIterable, Sendable {
    case manual, arrived, modified, renamed, directoryCreated, tagAdded, tagRemoved
    case unchanged, resident, fileSize, folderSize, fileCount, duplicate, stabilized
    case diskConnected, scheduled, appLaunch, ruleSucceeded, ruleFailed
    case textContains, imageText, documentType
    public var title: String {
        switch self {
        case .manual: "Ручной запуск"
        case .arrived: "Новый файл / поступление в папку"
        case .modified: "Файл изменён"
        case .renamed: "Файл переименован"
        case .directoryCreated: "Создана подпапка"
        case .tagAdded: "Добавлен Finder-тег"
        case .tagRemoved: "Снят Finder-тег"
        case .unchanged: "Не изменялся заданное время"
        case .resident: "Находится в папке заданное время"
        case .fileSize: "Размер файла превысил порог"
        case .folderSize: "Размер папки превысил порог"
        case .fileCount: "Количество файлов достигло порога"
        case .duplicate: "Новый точный дубликат"
        case .stabilized: "Завершилось копирование / скачивание"
        case .diskConnected: "Подключён диск"
        case .scheduled: "По расписанию"
        case .appLaunch: "При запуске приложения"
        case .ruleSucceeded: "Другое правило завершилось"
        case .ruleFailed: "Ошибка другого правила"
        case .textContains: "Ключевое слово в документе"
        case .imageText: "Текст на изображении (OCR)"
        case .documentType: "Тип документа"
        }
    }
}

public enum RuleActionKind: String, Codable, CaseIterable, Sendable {
    case addTag, removeTag, archive, notify, log, showFiles, showDuplicates, createDirectories, copy, runRule
    public var title: String {
        switch self {
        case .addTag: "Добавить Finder-тег"
        case .removeTag: "Снять Finder-тег"
        case .archive: "Создать и проверить ZIP-копию"
        case .notify: "Уведомить"
        case .log: "Записать в историю"
        case .showFiles: "Показать файлы"
        case .showDuplicates: "Показать дубликаты"
        case .createDirectories: "Создать подпапки"
        case .copy: "Скопировать"
        case .runRule: "Запустить другое правило"
        }
    }
}

public enum RuleNameMatch: String, Codable, CaseIterable, Sendable {
    case contains, prefix, suffix, wildcard
    public var title: String {
        switch self {
        case .contains: "Содержит"
        case .prefix: "Начинается с"
        case .suffix: "Заканчивается на"
        case .wildcard: "Шаблон (* и ?)"
        }
    }
}

public struct RuleConditions: Codable, Equatable, Sendable {
    public var extensions: [String] = []
    public var name = ""
    public var nameMatch = RuleNameMatch.contains
    public var minimumBytes: Int64? = nil
    public var maximumBytes: Int64? = nil
    public var requiredTag = ""
    public var absentTag = ""
    public var excludedPaths: [String] = []
    public var excludedNames: [String] = []
    public var modifiedAfter: Date? = nil
    public var createdAfter: Date? = nil
    public var firstSeenAfter: Date? = nil
    public var allConditions = true
    public init() {}
}

public struct RuleAction: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: RuleActionKind
    public var value = ""
    public var destinationRootID: UUID? = nil
    public var nextRuleID: UUID? = nil
    public var archiveTogether = false
    public init(kind: RuleActionKind, value: String = "") { self.kind = kind; self.value = value }
}

public enum RuleSchedule: String, Codable, CaseIterable, Sendable {
    case once, daily, weekly, interval
    public var title: String {
        switch self {
        case .once: "Однократно"
        case .daily: "Каждые 24 часа"
        case .weekly: "Каждые 7 суток"
        case .interval: "Заданный интервал"
        }
    }
}

/// Подписи отделены от сохраняемых значений: локализация не меняет историю
/// и не нарушает проверку завершённых действий после обновления приложения.
public enum RulePresentation {
    public static func status(_ value: String) -> String {
        switch value {
        case "running": "Выполняется"
        case "recoveryRequired": "Требуется проверка результата"
        case "completed": "Завершено"
        case "partial_or_failed": "Есть ошибки"
        case "failed": "Ошибка"
        case "cancelled": "Отменено"
        case "interrupted": "Прервано"
        case "skipped": "Пропущено"
        default: value
        }
    }
    public static func origin(_ value: String) -> String {
        switch value {
        case "manual": "Вручную"
        case "automatic": "Автоматически"
        case "retry": "Повтор"
        case "chain": "Цепочка правил"
        default: value
        }
    }
}
public struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = "Новое правило"
    public var rootID: UUID?
    public var maximumFiles: Int? = nil
    public var maximumBytes: Int64? = nil
    public var enabled = false
    public var includeSubfolders = true
    public var processExisting = false
    public var allowContentReading = false
    public var event = RuleEvent.manual
    public var eventValue = ""
    public var threshold: Int64 = 1
    public var days = 7
    public var schedule = RuleSchedule.daily
    public var scheduleDate = Date()
    public var intervalSeconds = 3600
    /// nil сохраняет прежние интервальные 24ч/7суток; новый выбор закрепляет календарный пояс.
    public var scheduleTimeZone: String? = nil
    public var catchUpOnce = false
    public var sourceRuleID: UUID?
    public var conditions = RuleConditions()
    public var actions = [RuleAction(kind: .log)]
    public init() {}
}

/// Состояние наблюдения сохраняет время первого обнаружения отдельно от даты
/// создания и стабильный файловый ID для распознавания переименования.
public struct RuleFileSnapshot: Codable, Equatable, Sendable {
    public var version: FileVersion? = nil
    public var relativePath: String
    public var identity: String
    public var byteSize: Int64
    public var modifiedAt: Date?
    public var createdAt: Date?
    public var tags: [String]
    public var firstSeenAt: Date
    public var stableSince: Date
    public var isDirectory: Bool
    public var fingerprint: String { "\(version.map { RulePolicy.versionFingerprint($0) } ?? identity)|\(relativePath)|\(byteSize)|\(modifiedAt?.timeIntervalSince1970 ?? 0)|\(tags.sorted().joined(separator: ","))" }
}

public struct RuleObservation: Codable, Sendable {
    public var files: [RuleFileSnapshot] = []
    public var lastCheckedAt: Date? = nil
    public var lastScheduledAt: Date? = nil
    public var initialized = false
    public var pending: [String: String] = [:]
    public var processed: [String: String] = [:]
    public init() {}
}

public struct RuleRun: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var taskID: UUID? = nil
    public var ruleID: UUID
    public var ruleName: String
    public var createdAt = Date()
    public var origin: String
    public var status = "running"
    public var matchedCount = 0
    public var results: [RuleActionResult] = []
    public init(rule: AutomationRule, origin: String) { ruleID = rule.id; ruleName = rule.name; self.origin = origin }
}
public struct RuleActionResult: Codable, Sendable {
    public var actionID: UUID
    public var kind: RuleActionKind
    public var relativePath: String
    public var status: String
    public var message: String
}
