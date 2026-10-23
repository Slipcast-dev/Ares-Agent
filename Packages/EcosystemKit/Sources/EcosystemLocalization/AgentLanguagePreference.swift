import Foundation

/// Устойчивые значения выбора не являются переводимыми подписями Picker.
public enum AgentLanguagePreference: String, Codable, CaseIterable, Sendable {
    case system, ru, en

    public func resolve(preferredLanguages: [String]) -> AgentLanguage {
        switch self {
        case .ru: return .russian
        case .en: return .english
        case .system: return AgentLanguage.resolve(preferredLanguages: preferredLanguages)
        }
    }
    public var nativeTitle: String {
        switch self {
        case .system: return "System"
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}
