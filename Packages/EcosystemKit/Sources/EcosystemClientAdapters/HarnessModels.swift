import Foundation

public enum HarnessAgentDomain: String, Codable, Sendable { case ares, athena }

/// Путь профиля определяется установленным клиентом, а не входным текстом модели.
public struct HarnessAdapterConfiguration: Sendable {
    public let domain: HarnessAgentDomain
    public let patchURL: URL
    public let helperURL: URL
    public let installedVersion: String
    public let profile: String
    public init(domain: HarnessAgentDomain, patchURL: URL, helperURL: URL,
                installedVersion: String, profile: String = "desktop") {
        self.domain = domain; self.patchURL = patchURL; self.helperURL = helperURL
        self.installedVersion = installedVersion; self.profile = profile
    }
}

/// План не содержит исходный YAML, выражения, секреты или данные пользователя.
public struct HarnessConnectionPlan: Codable, Sendable {
    public let clientId: String
    public let domain: String
    public let profile: String
    public let version: String
    public let connected: Bool
    public let fingerprint: String
    public let changes: [String]
    public let warnings: [String]
    public let backupDirectory: String?
}

/// configured не означает, что уже открытая сессия загрузила роль и делегировала ей задачу.
public struct HarnessAdapterStatus: Codable, Sendable {
    public let clientId: String
    public let domain: String
    public let profile: String
    public let version: String
    public let connected: Bool
    public let state: String
    public let detail: String
    public let localMCP: Bool
    public let nativeDelegation: Bool
    public let delegationVerified: Bool
}

public enum HarnessAdapterError: Error, LocalizedError, Sendable {
    case unsafePath, conflict, stalePlan, invalidConfiguration, unsupportedVersion, recoveryRequired, ioFailure
    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "Небезопасный путь или права профиля Harness."
        case .conflict: return "Имя MCP, роли или провайдера занято, либо управляемый блок изменён."
        case .stalePlan: return "Профиль изменился после просмотра плана. Создайте новый план."
        case .invalidConfiguration: return "YAML-профиль Harness повреждён или имеет неоднозначную структуру."
        case .unsupportedVersion: return "Формат установленной версии Harness не проверен. Подключение заблокировано."
        case .recoveryRequired: return "Есть незавершённая операция Harness. Требуется явное восстановление."
        case .ioFailure: return "Не удалось безопасно сохранить профиль Harness."
        }
    }
}
