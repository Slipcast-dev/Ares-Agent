import CryptoKit
import Foundation
import Yams

/// Два точных контракта desktop проверяются раздельно: новая версия переносит
/// инструменты и persona в Agent Preset, поэтому semver-диапазон здесь небезопасен. Composer строит
/// только YAML-узлы: !!js остаётся текстом и никогда не передаётся JS evaluator.
public enum HarnessPatch {
    public static let supportedVersion = "0.2.0-rc.2"
    public static let supportedVersions: Set<String> = [supportedVersion, "0.2.1-rc.2"]
    public static let contractID = "desktop-0.2.0-rc.2+desktop-0.2.1-rc.2"
    public static func supports(version: String) -> Bool { supportedVersions.contains(version) }
    public static func rawTools(for domain: HarnessAgentDomain) -> [String] {
        let common = ["access.request", "access.status", "agent.get_capabilities", "agent.get_status", "audit.list", "event.list", "events.ack", "events.ack_processing", "events.claim", "events.claim_processing", "events.list", "task.cancel", "task.get", "task.get_result", "task.list"]
        let operations = domain == .ares
            ? ["file.analyze_storage", "file.compute_duplicates", "file.find_duplicates", "file.get_audit_report", "file.get_task", "file.list_roots", "file.scan", "file.search", "rule.disable", "rule.get", "rule.history", "rule.list", "rule.preview", "rule.propose", "rule.request_enable", "rule.run", "rule.validate"]
            : ["diagnostics.history", "diagnostics.run", "diagnostics.start", "monitor.disable", "monitor.get", "monitor.history", "monitor.list", "monitor.preview", "monitor.propose", "monitor.request_enable", "storage.get_overview", "system.cancel_task", "system.get_info", "system.get_metrics", "system.get_task"]
        return (common + operations).sorted()
    }
    /// Точное имя SDK включает hash, если raw MCP имя содержит точку или иной
    /// недопустимый символ. Без hash фильтр незаметно запретил бы нужный инструмент.
    public static func publicToolName(server: String, rawName: String) -> String {
        let joined = "mcp__" + server + "__" + rawName
        // SDK использует JavaScript regex без флага /u: каждая UTF-16
        // surrogate code unit заменяется отдельно, даже внутри одного emoji.
        let normalized = joined.utf16.map { unit -> Character in
            let allowed = (65...90).contains(unit) || (97...122).contains(unit)
                || (48...57).contains(unit) || unit == 95 || unit == 45
            return allowed ? Character(UnicodeScalar(unit)!) : "_"
        }
        let text = String(normalized)
        guard text != joined || text.count > 64 else { return text }
        let hash = SHA256.hash(data: Data((server + "\0" + rawName).utf8)).map { String(format: "%02x", $0) }.joined()
        return String(text.prefix(51)) + "_" + String(hash.prefix(12))
    }

    struct Inventory {
        var ids = Set<String>(); var servers = Set<String>()
        var providers = Set<String>(); var tools = Set<String>()
        var empty = true
    }
    static func inspect(_ data: Data) throws -> Inventory {
        guard data.count <= 1_048_576, let source = String(data: data, encoding: .utf8) else { throw HarnessAdapterError.invalidConfiguration }
        var parser: Yams.YamlSequence<Node>
        do { parser = try Yams.compose_all(yaml: source) }
        catch { throw HarnessAdapterError.invalidConfiguration }
        var documents: [Node] = []
        while let node = parser.next() { documents.append(node) }
        guard parser.error == nil, documents.count <= 1 else { throw HarnessAdapterError.invalidConfiguration }
        guard let document = documents.first else { return Inventory() }
        if document.null != nil { return Inventory() }
        guard let sequence = document.sequence, sequence.count <= 256 else { throw HarnessAdapterError.invalidConfiguration }
        var inventory = Inventory(); inventory.empty = sequence.isEmpty
        var nodes = 0, entries = 0
        func visit(_ node: Node, depth: Int) throws {
            nodes += 1
            guard depth <= 24, nodes <= 10_000, node.anchor == nil else { throw HarnessAdapterError.invalidConfiguration }
            if case .alias = node { throw HarnessAdapterError.invalidConfiguration }
            if let mapping = node.mapping {
                var keys = Set<String>()
                for pair in mapping {
                    guard let key = pair.key.string, key != "<<", keys.insert(key).inserted else { throw HarnessAdapterError.invalidConfiguration }
                    if ["id", "serverName", "providerName", "toolName"].contains(key) {
                        // Вычисляемые идентификаторы нельзя доказать свободными,
                        // поэтому отказываем, не вычисляя доверенное выражение.
                        guard let value = pair.value.string,
                              !pair.value.tag.rawValue.contains("js") else { throw HarnessAdapterError.conflict }
                        switch key {
                        case "id":
                            entries += 1
                            guard entries <= 256 else { throw HarnessAdapterError.invalidConfiguration }
                            // Cordis повторно адресует один id в последовательных
                            // patch-операциях; разные child scopes также могут
                            // иметь одинаковые локальные id. Это не дубликат YAML-
                            // ключа. Собираем множество и ниже проверяем только
                            // пересечение с именами, которыми будем управлять.
                            inventory.ids.insert(value)
                        case "serverName": inventory.servers.insert(value)
                        case "providerName": inventory.providers.insert(value)
                        default: inventory.tools.insert(value)
                        }
                    }
                    try visit(pair.value, depth: depth + 1)
                }
            } else if let sequence = node.sequence {
                for child in sequence { try visit(child, depth: depth + 1) }
            }
        }
        for operation in sequence {
            guard operation.mapping != nil else { throw HarnessAdapterError.invalidConfiguration }
            if let insert = operation["insert"] {
                guard let entries = insert.sequence,
                      entries.allSatisfy({ $0.mapping != nil }) else { throw HarnessAdapterError.invalidConfiguration }
            }
            try visit(operation, depth: 0)
        }
        return inventory
    }
    static func conflicts(_ inventory: Inventory, domain: HarnessAgentDomain) -> Bool {
        let name = domain.rawValue
        return ["mcp", "preset", "provider", "delegate"].contains { inventory.ids.contains("ecosystem-\(name)-\($0)") }
            || inventory.servers.contains(name) || inventory.providers.contains("ecosystem_" + name)
            || inventory.tools.contains("delegate_" + name)
            || inventory.ids.contains("ecosystem_" + name)
    }
    static func begin(_ domain: String) -> String { "\n# BEGIN ECOSYSTEM HARNESS \(domain) v1\n" }
    static func end(_ domain: String) -> String { "# END ECOSYSTEM HARNESS \(domain) v1\n" }
    static func block(configuration: HarnessAdapterConfiguration) -> String {
        let name = configuration.domain.rawValue
        let specialist = name == "ares" ? "Ты Арес, специалист по организации файлов." : "Ты Афина, специалист по диагностике Mac."
        let persona = specialist + " Используй только разрешённые инструменты собственного MCP-сервера. Сначала узнай agent.get_capabilities и agent.get_status. agent.get_capabilities вызывай с пустыми аргументами {}; не придумывай версию контракта. Наличие инструмента не выдаёт разрешения: при отказе попроси выдать доступ в отдельном приложении агента. Не меняй модель или провайдера пользователя. Для длительных операций сохраняй taskId, запрашивай task.get и task.get_result, обрабатывай курсоры страниц; успех сообщай только после подтверждённого результата. Отделяй факты от предположений и явно сообщай частичный результат, отказ и истечение срока. Отмена ожидания не отменяет задачу; task.cancel вызывай только по намерению пользователя. Для rule.run по событию inbox сначала обязательно получи глобальный processing claim через events.claim_processing; передавай eventID и processingToken вместе, а не по отдельности, и заверши через events.ack_processing. Не выдавай ручное поручение за событие inbox и не придумывай eventID/token. Не вызывай shell, сеть, другие MCP-серверы или делегирование другому специалисту. Возвращай родителю проверяемую сводку с taskId и ограничениями. Фильтр инструментов не заменяет разрешения runtime."
        if configuration.installedVersion == "0.2.1-rc.2" {
            return presetBlock(configuration: configuration, persona: persona)
        }
        let tools = rawTools(for: configuration.domain).map { "            - " + quote(publicToolName(server: name, rawName: $0)) }.joined(separator: "\n")
        return begin(name) + """
        - insert:
            - id: ecosystem-\(name)-mcp
              name: '@deepseek-ai/dsh-mcp-client'
              config:
                transport: stdio
                serverName: \(name)
                command: \(quote(configuration.helperURL.path))
                args: []
                toolCallTimeoutMs: 310000
                failOnStartupError: true
            - id: ecosystem-\(name)-provider
              name: '@deepseek-ai/dsh-subagent-spawn-in-process'
              config:
                providerName: ecosystem_\(name)
            - id: ecosystem-\(name)-delegate
              name: '@deepseek-ai/dsh-tool-subagent'
              config:
                provider: ecosystem_\(name)
                toolName: delegate_\(name)
                persona: \(quote(persona))
                toolFilter:
                  allow:
        \(tools)
                maxDepth: 1
                backgroundMode: continuable
        """ + "\n" + end(name)
    }
    /// В 0.2.1 инструменты принадлежат независимому preset scope. Запрет
    /// наследуемых tools сохраняет системную политику approval: он только
    /// сужает поверхность роли. Ограничение ставится в scope нового Agent,
    /// когда preset MCP уже готов; preset сам является его предком.
    /// Фиксированная функция не использует пользовательский YAML или секреты.
    private static func presetBlock(configuration: HarnessAdapterConfiguration, persona: String) -> String {
        let name = configuration.domain.rawValue
        // data: ESM — штатный Node loader, без отдельного изменяемого JS-файла.
        // Модуль целиком фиксирован; путь helper кодируется отдельно JSON-строкой.
        let restriction = "export function apply(ctx,config){ctx.on('agent/created',async({agent})=>{await agent.ctx.inject(['tools'],scoped=>{const allow=scoped.tools.schemas(agent).map(tool=>tool.name).filter(name=>name.startsWith('mcp__'+config.serverName+'__'));if(!allow.length)throw new Error('ECOSYSTEM_MCP_TOOLS_MISSING');scoped.tools.restrict({allow});}).await();});}"
        let restrictionModule = "data:text/javascript;base64," + Data(restriction.utf8).base64EncodedString()
        return begin(name) + """
        - insert:
            - id: ecosystem-\(name)-preset
              name: '@deepseek-ai/dsh-agent-preset'
              config:
                id: ecosystem_\(name)
                name: \(quote(name == "ares" ? "Арес" : "Афина"))
                plugins:
                  - id: ecosystem-\(name)-scope
                    name: \(quote(restrictionModule))
                    config:
                      serverName: \(name)
                  - id: ecosystem-\(name)-persona
                    name: '@deepseek-ai/dsh-persona'
                    config:
                      prefix: \(quote(persona))
                  - id: ecosystem-\(name)-mcp
                    name: '@deepseek-ai/dsh-mcp-client'
                    config:
                      transport: stdio
                      serverName: \(name)
                      command: \(quote(configuration.helperURL.path))
                      args: []
                      toolCallTimeoutMs: 310000
                      failOnStartupError: true
            - id: ecosystem-\(name)-provider
              name: '@deepseek-ai/dsh-subagent-spawn-in-process'
              config:
                providerName: ecosystem_\(name)
            - id: ecosystem-\(name)-delegate
              name: '@deepseek-ai/dsh-tool-subagent'
              config:
                provider: ecosystem_\(name)
                toolName: delegate_\(name)
                agentPreset: ecosystem_\(name)
                maxDepth: 1
        """ + "\n" + end(name)
    }
    static func quote(_ value: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }

    /// Для пустого flow-списка удаляем только [] и его внутренние пробелы.
    /// Комментарии остаются на месте, а общий registry хранит исходные байты
    /// до отключения последнего домена независимо от порядка Ares/Athena.
    static func normalizeEmpty(_ data: Data) throws -> Data {
        guard try inspect(data).empty, let source = String(data: data, encoding: .utf8) else { return data }
        guard let node = try? Yams.compose(yaml: source), let mark = node.mark else { return data }
        var lineStart = source.startIndex
        for _ in 1..<mark.line {
            guard let newline = source[lineStart...].firstIndex(of: "\n") else { throw HarnessAdapterError.invalidConfiguration }
            lineStart = source.index(after: newline)
        }
        guard let scalarStart = lineStart.samePosition(in: source.unicodeScalars),
              let position = source.unicodeScalars.index(scalarStart, offsetBy: mark.column - 1, limitedBy: source.unicodeScalars.endIndex),
              let start = position.samePosition(in: source), start < source.endIndex, source[start] == "[" else { return data }
        var end = source.index(after: start)
        while end < source.endIndex, source[end].isWhitespace { end = source.index(after: end) }
        guard end < source.endIndex, source[end] == "]" else { throw HarnessAdapterError.invalidConfiguration }
        var copy = source
        copy.remove(at: end)
        copy.remove(at: start)
        guard (try inspect(Data(copy.utf8))).empty else { throw HarnessAdapterError.invalidConfiguration }
        return Data(copy.utf8)
    }
}
