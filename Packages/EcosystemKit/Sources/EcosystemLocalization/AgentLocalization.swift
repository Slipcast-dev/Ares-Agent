import Foundation

/// Только поддерживаемые языки; System разрешается отдельно и не меняет язык ОС.
public enum AgentLanguage: String, CaseIterable, Codable, Sendable {
    case russian = "ru"
    case english = "en"

    public static func resolve(preferredLanguages: [String]) -> AgentLanguage {
        // BCP-47 region/script не создают третью таблицу: en-GB и ru_RU имеют
        // тот же перевод. Порядок предпочтений важнее порядка поддерживаемых локалей.
        for preferred in preferredLanguages {
            let base = preferred.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first.map(String.init)?.lowercased()
            if let base, let language = AgentLanguage(rawValue: base) { return language }
        }
        return .english
    }
}

/// Типизированные ключи первой вертикальной проверки; произвольный ввод MCP
/// не становится ключом ресурса и не открывает путь за пределами resource bundle.
public enum AgentText: String, CaseIterable, Sendable {
    case runtimeFailureTitle = "runtime.failure.title"
    case runtimeFailureRecovery = "runtime.failure.recovery"
    case runtimeFailureGuide = "runtime.failure.guide"
    case closeApplication = "application.close"
    case notificationTestTitle = "notification.test.title"
    case notificationTestBody = "notification.test.body"
    case agentAres = "agent.ares"
    case agentAthena = "agent.athena"
    case automationAttention = "automation.attention"
    case automationCompleted = "automation.completed"
    case languageTitle = "language.title"
    case languageChoice = "language.choice"
    case languageScope = "language.scope"
    case languageUnavailable = "language.unavailable"
    case languageUnconfirmed = "language.unconfirmed"
    case languageRetry = "language.retry"
}

public enum LocalizedAgent: String, Sendable { case ares, athena }

/// Не хранит preferences и не выполняет I/O к профилю. Locale выбирается явно,
/// поэтому runtime не зависит от SwiftUI Environment или языка процесса клиента.
public struct AgentLocalization: Sendable {
    public let language: AgentLanguage
    let table: Bundle?

    public init(language: AgentLanguage) {
        self.language = language
        table = Bundle.module.url(forResource: language.rawValue, withExtension: "lproj")
            .flatMap { Bundle(url: $0) }
    }

    public func text(_ key: AgentText) -> String {
        // Умышленно не возвращаем raw key и не подставляем русский при EN.
        // CI/probe требуют полных таблиц; fallback нужен лишь для повреждённой копии.
        table?.localizedString(forKey: key.rawValue, value: "Localization resource unavailable.", table: "Localizable")
            ?? "Localization resource unavailable."
    }

    /// Plural выбирается ресурсами, а не условием count == 1 в UI.
    public func eventCount(_ count: Int) -> String {
        guard count >= 0 else { return "Localization resource unavailable." }
        let format = table?.localizedString(forKey: "events.count", value: nil, table: "Localizable")
        guard let format, format != "events.count" else { return "Localization resource unavailable." }
        return String(format: format, locale: Locale(identifier: language.rawValue), arguments: [count])
    }

    public func notificationPreview(agent: LocalizedAgent) -> LocalizationNotification {
        // Имя бренда задаётся в отдельной типизированной позиции, пути и свободный
        // пользовательский текст не входят в тестовое уведомление.
        let name = text(agent == .ares ? .agentAres : .agentAthena)
        return LocalizationNotification(title: String(format: text(.notificationTestTitle),
                                                       locale: Locale(identifier: language.rawValue), arguments: [name]),
                                        body: text(.notificationTestBody))
    }

    /// Только диагностика комплектности; абсолютный путь профиля не выдаётся.
    public var resourcesAvailable: Bool { table != nil }

    /// Probe различает ресурсы внутри переносимого .app и developer fallback
    /// SwiftPM. Иначе тест рядом с исходниками мог бы скрыть ошибку упаковщика.
    public var resourcePlacement: String {
        guard let table else { return "missing" }
        let root = Bundle.main.resourceURL?.standardizedFileURL.path ?? ""
        return Bundle.main.bundleURL.pathExtension == "app"
            && table.bundleURL.standardizedFileURL.path.hasPrefix(root + "/") ? "application" : "swiftpm"
    }
}

public struct LocalizationNotification: Sendable {
    public let title: String
    public let body: String
}
