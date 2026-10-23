import Foundation

/// Только представление: эта модель не заменяет error codes, event IDs и receipts.
/// История хранит исходный текст; переданные данные никогда не становятся ключами.
public indirect enum RuntimeMessage: Equatable, Sendable {
    case verbatim(String)
    case template(String, [RuntimeMessage])
    public init(_ key: String, args: [String] = []) { self = .template(key, args.map(Self.verbatim)) }
    public init(_ key: String, messages: [RuntimeMessage]) { self = .template(key, messages) }
    public static func capture(_ error: Error) -> RuntimeMessage {
        if error is CancellationError { return RuntimeMessage("runtime.error.cancelled") }
        return (error as? any RuntimeLocalizedError)?.runtimeMessage ?? RuntimeMessage("runtime.error.unknown")
    }
}

/// Conformance допускается лишь для конечного типа ошибки, а не произвольного
/// NSError.localizedDescription: совпадение текста не доказывает его происхождение.
public protocol RuntimeLocalizedError: Error {
    var runtimeMessage: RuntimeMessage { get }
}

public extension AgentLocalization {
    func runtimeText(_ key: String, _ arguments: String...) -> String {
        runtimeMessage(RuntimeMessage(key, args: arguments))
    }
    func runtimeError(_ error: Error) -> String { runtimeMessage(.capture(error)) }
    func runtimeMessage(_ message: RuntimeMessage) -> String { renderRuntime(message, depth: 0) }
    private func renderRuntime(_ message: RuntimeMessage, depth: Int) -> String {
        let fallback = language == .russian ? "Не удалось выполнить операцию." : "The operation could not be completed."
        guard depth <= 8 else { return fallback }
        switch message {
        case .verbatim(let value): return value.count <= 4096 ? value : fallback
        case .template(let key, let arguments):
            guard key.utf8.count <= 1024, arguments.count <= 16,
                  let value = table?.localizedString(forKey: key, value: "__RUNTIME_KEY_MISSING__", table: "Runtime"),
                  value != "__RUNTIME_KEY_MISSING__" else { return fallback }
            let pieces = value.components(separatedBy: "%@")
            guard pieces.count == arguments.count + 1 else { return fallback }
            // Вставляем строки один раз, без printf и повторного поиска ключа.
            var output = pieces[0]
            for (index, argument) in arguments.enumerated() {
                output += renderRuntime(argument, depth: depth + 1) + pieces[index + 1]
            }
            return output
        }
    }
}

public enum RuntimeLocalization {
    /// CLI/MCP не получают новое право чтения GUI-only preference. Язык stderr
    /// можно задать окружением; описания инструментов всегда двуязычные.
    public static var clientLanguage: AgentLanguage {
        let value = ProcessInfo.processInfo.environment["ECOSYSTEM_CLIENT_LANGUAGE"] ?? ""
        return AgentLanguage(rawValue: value) ?? AgentLanguage.resolve(preferredLanguages: Locale.preferredLanguages)
    }
    public static func bilingual(_ key: String, _ arguments: String...) -> String {
        let message = RuntimeMessage(key, args: arguments)
        return AgentLocalization(language: .russian).runtimeMessage(message) + "\n"
            + AgentLocalization(language: .english).runtimeMessage(message)
    }
}

internal extension AgentLocalization {
    var runtimeCatalogue: [String: String] {
        guard let url = table?.url(forResource: "Runtime", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [:] }
        return value
    }
    var runtimeCatalogueComplete: Bool {
        let entries = runtimeCatalogue
        return !entries.isEmpty && entries.allSatisfy { key, value in
            let count = value.components(separatedBy: "%@").count - 1
            return runtimeMessage(RuntimeMessage(key, args: Array(repeating: "sample", count: count)))
                == value.components(separatedBy: "%@").joined(separator: "sample")
        }
    }
}
