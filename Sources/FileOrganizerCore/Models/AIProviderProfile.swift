import Foundation

/// Поддерживаемые семейства API. Секрет намеренно не является частью профиля:
/// он должен храниться в Keychain под отдельным идентификатором.
public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case openAI, deepSeek, openRouter, ollama, compatible
    public var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama — локально"
        case .compatible: "Другой OpenAI-совместимый API"
        }
    }
    public var defaultEndpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .compatible: "https://"
        }
    }
}

public struct AIProviderProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: AIProviderKind
    public let endpoint: URL
    public let secretReference: String?
    public let modelName: String?

    public init(id: UUID = UUID(), name: String, kind: AIProviderKind, endpoint: URL, secretReference: String? = nil, modelName: String? = nil) throws {
        try AIEndpointValidator.validate(endpoint: endpoint, kind: kind)
        self.id = id; self.name = name; self.kind = kind; self.endpoint = endpoint; self.secretReference = secretReference
        self.modelName = modelName
    }
}

public enum AIEndpointValidator {
    public static func validate(endpoint: URL, kind: AIProviderKind) throws {
        guard let scheme = endpoint.scheme?.lowercased(), let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              ["http", "https"].contains(scheme) else { throw AIProviderError.invalidEndpoint }
        if kind == .ollama {
            guard scheme == "https" || endpoint.host == "localhost" || endpoint.host == "127.0.0.1" else { throw AIProviderError.insecureEndpoint }
        } else if scheme != "https" { throw AIProviderError.insecureEndpoint }
    }
}

public enum AIProviderError: Error, LocalizedError, Sendable {
    case invalidEndpoint, insecureEndpoint
    public var errorDescription: String? { self == .invalidEndpoint ? "Некорректный адрес ИИ-провайдера." : "Облачный ИИ-провайдер должен использовать HTTPS." }
}
