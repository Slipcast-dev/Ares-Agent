import Foundation

/// E11 резервирует интеграцию, но не имеет проверенной live-версии Hermes.
/// Пути задаются явно: ни ~/.hermes, ни установщик, ни ключи здесь не читаются.
public struct HermesReadinessAdapter: ClientIntegrationAdapter {
    public let clientId = "hermes"
    public let domain: String
    private let executableURL: URL?
    private let profileURL: URL?
    private let version: String?
    public init(domain: String = "ares", executableURL: URL? = nil,
                profileURL: URL? = nil, detectedVersion: String? = nil) {
        self.domain = domain; self.executableURL = executableURL
        self.profileURL = profileURL; self.version = detectedVersion
    }
    public func detect() async -> IntegrationDetection {
        let exists = executableURL.map { $0.isFileURL && FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        return IntegrationDetection(clientId: clientId, version: version,
            executablePath: executableURL?.path, profilePath: profileURL?.path,
            availability: exists ? .supported : .unsupported)
    }
    public func inspectCapabilities() async -> IntegrationCapabilities { IntegrationCapabilities() }
    public func inspectRegistration() async throws -> IntegrationRegistration {
        IntegrationRegistration(clientId: clientId, domain: domain, state: "planned",
            detail: "Hermes — запланировано. Живое подключение и делегирование ещё не проверены.")
    }
    public func previewRegistration(connected: Bool) async throws -> IntegrationRegistrationPlan {
        guard await detect().availability.isSupported else { throw IntegrationAdapterError.programMissing }
        // Даже существующий executable и правдоподобная версия не разрешают запись:
        // список проверенных версий появится только после H1 с реальным Hermes.
        throw IntegrationAdapterError.unsupportedVersion
    }
    public func applyRegistration(_ plan: IntegrationRegistrationPlan) async throws -> IntegrationRegistration {
        throw IntegrationAdapterError.registrationUnavailable
    }
    public func inspectDelegationSupport() async -> IntegrationSupport { .unknown }
    public func validateConnection() async throws -> IntegrationRegistration {
        throw IntegrationAdapterError.connectionUnverified
    }
    /// Только экспорт фрагмента для будущей версии; JSON является подмножеством
    /// YAML. Метод не читает существующий профиль и не разрешает его применение.
    public func exportMCPDraft(helperURL: URL) throws -> Data {
        guard ["ares", "athena"].contains(domain), helperURL.isFileURL,
              helperURL.path.hasPrefix("/"), !helperURL.path.contains("\n") else {
            throw IntegrationAdapterError.invalidIdentifier
        }
        return try JSONSerialization.data(withJSONObject: ["mcp_servers": [domain:
            ["command": helperURL.path, "args": [String]()]]], options: [.sortedKeys, .prettyPrinted])
    }

}
