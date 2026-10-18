import Foundation

/// Имя роли совпадает с именем её MCP-сервера, но не заменяет разрешения runtime.
public enum CodexAgentDomain: String, Codable, Sendable { case ares, athena }

public struct CodexAdapterConfiguration: Sendable {
    public let domain: CodexAgentDomain
    public let configDirectory: URL
    public let helperURL: URL
    public let codexExecutableURL: URL?
    public init(domain: CodexAgentDomain, configDirectory: URL, helperURL: URL,
                codexExecutableURL: URL? = nil) {
        self.domain = domain; self.configDirectory = configDirectory
        self.helperURL = helperURL; self.codexExecutableURL = codexExecutableURL
    }
}

/// План связывается с содержимым файлов: подтверждение устаревшего плана невозможно.
public struct CodexConnectionPlan: Codable, Sendable {
    public let domain: String
    public let connected: Bool
    public let fingerprint: String
    public let changes: [String]
    public let warnings: [String]
    public let backupDirectory: String?
}

public struct CodexAdapterStatus: Codable, Sendable {
    public let domain: String
    public let connected: Bool
    public let state: String
    public let detail: String
}

public enum CodexAdapterError: Error, LocalizedError, Sendable {
    case unsafePath, conflict, stalePlan, invalidConfiguration, cliUnavailable, cliValidationFailed, recoveryRequired, ioFailure
    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "Небезопасный путь или права файлов конфигурации."
        case .conflict: return "Обнаружена чужая или изменённая конфигурация агента."
        case .stalePlan: return "Файлы изменились после предварительного просмотра. Создайте новый план."
        case .invalidConfiguration: return "Некорректная конфигурация адаптера."
        case .cliUnavailable: return "Для проверки подключения требуется установленный Codex CLI."
        case .cliValidationFailed: return "Codex CLI отклонил подготовленную конфигурацию."
        case .recoveryRequired: return "Незавершённая операция требует восстановления без перезаписи чужих изменений."
        case .ioFailure: return "Не удалось безопасно сохранить конфигурацию."
        }
    }
}
