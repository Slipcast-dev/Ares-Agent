import Foundation
import FileOrganizerCore
import EcosystemLocalIPC
import EcosystemLocalization

/// stdio-only MCP сервер. Он принимает только идентификаторы объектов из
/// локальной базы и поэтому не становится каналом доступа к произвольным путям.
@main
struct FileOrganizerMCP {
    static func main() {
        if LocalizationProbe.runIfRequested() { return }
        if Array(CommandLine.arguments.dropFirst()) == ["--mcp-localization-probe"] {
            let value = ["local": localDefinitions + LocalCommonMCP.tools, "legacy": definitions]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        let container = AppContainer(databaseURL: AppContainer.defaultApplicationSupportDatabaseURL(), localRole: .mcp)
        guard (try? container.preparePersistentStore()) != nil else { return }
        let tools = container.isLocalRuntimeClient ? localDefinitions + LocalCommonMCP.tools : definitions
        let names = tools.compactMap { $0["name"] as? String }
        MCPStdioTransport.run(serverName: "ares", serverVersion: FileOrganizerProduct.version, tools: tools,
            experimental: ["ecosystemContracts": AresEcosystem.experimentalCapability(runtimeIntegrated: container.isLocalRuntimeClient)]) { name, data, context in
            do {
                guard let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LocalRuntimeFailure.invalidRequest }
                if let remote = container.localRuntimeClient {
                    let client = try remote.get()
                    if LocalCommonMCP.names.contains(name) {
                        let result = try await LocalCommonMCP.call(name, arguments: args, domain: "ares", toolNames: names, client: client) { id in
                            try await SnapshotMCP.call("file.get_task", args: ["taskId": id.uuidString], client: client)
                        }
                        return try LocalCommonMCP.result(result)
                    }
                    if RuleMCP.names.contains(name) { return try LocalCommonMCP.result(await RuleMCP.call(name, args: args, client: client, context: context)) }
                    if LocalInboxMCP.names.contains(name) { return try LocalCommonMCP.result(await LocalInboxMCP.call(name, args: args, client: client)) }
                    if LocalAccessMCP.names.contains(name) { return try LocalCommonMCP.result(await LocalAccessMCP.call(name, args: args, client: client)) }
                    if name == "file.list_roots" {
                        let roots = try await container.fileRepository.fetchRoots()
                        return try LocalCommonMCP.result(["roots": roots.map { ["id": $0.id.uuidString, "name": $0.displayName] }])
                    }
                    if name == "file.get_audit_report" {
                        let events = try await container.fileRepository.recentEvents(limit: 100)
                        return try LocalCommonMCP.result(["events": events.map { ["id": $0.id.uuidString, "origin": $0.origin.rawValue, "type": $0.eventType, "summary": $0.summary] }])
                    }
                    return try LocalCommonMCP.result(await SnapshotMCP.call(name, args: args, client: client, context: context))
                }
                var value = await call(name, args, container)
                if let blocks = value["content"] as? [[String: Any]], let text = blocks.first?["text"] as? String,
                   let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    value["structuredContent"] = object
                }
                return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            } catch is CancellationError {
                // Отмена Swift-ожидания подавляется сеансом. Отменённая другим
                // запросом durable job — обычный доменный отказ CANCELLED.
                if Task.isCancelled { throw CancellationError() }
                return LocalCommonMCP.failure(LocalRuntimeFailure.cancelled)
            } catch { return LocalCommonMCP.failure(error) }
        }
    }

    private static func call(_ name: String, _ args: [String: Any], _ container: AppContainer) async -> [String: Any] {
        if name == "file.list_roots" {
            guard args.isEmpty else { return toolError("Инструмент не принимает параметры.") }
            guard let roots = try? await container.fileRepository.fetchRoots() else { return toolError("Не удалось прочитать корни.") }
            return toolResult(["roots": roots.map { ["id": $0.id.uuidString, "name": $0.displayName] }])
        }
        if name == "file.get_audit_report" {
            guard args.isEmpty, let events = try? await container.fileRepository.recentEvents(limit: 100) else { return toolError("Не удалось прочитать аудит.") }
            return toolResult(["events": events.map { ["id": $0.id.uuidString, "origin": $0.origin.rawValue, "type": $0.eventType, "summary": $0.summary] }])
        }
        if name == "file.get_task" {
            guard args.keys.allSatisfy({ $0 == "taskId" }), let id = (args["taskId"] as? String).flatMap(UUID.init(uuidString:)), let task = try? await container.taskCoordinator.task(withID: id) else { return toolError("Задача не найдена или параметры некорректны.") }
            return toolResult(["taskId": task.id.uuidString, "rootId": task.rootID.uuidString, "status": task.status.rawValue])
        }
        guard let rootID = (args["rootId"] as? String).flatMap(UUID.init(uuidString:)), let _ = try? await container.fileRepository.root(withID: rootID) else { return toolError("rootId не разрешён или некорректен.") }
        if name == "file.scan" {
            guard args.keys.allSatisfy({ ["rootId", "correlationId", "idempotencyKey"].contains($0) }),
                  args["correlationId"] == nil || args["correlationId"] is String,
                  args["idempotencyKey"] == nil || args["idempotencyKey"] is String else { return toolError("Некорректные параметры сканирования.") }
            do {
                let task = try await container.taskCoordinator.scan(rootID: rootID, origin: .codex,
                    correlationID: args["correlationId"] as? String,
                    idempotencyKey: args["idempotencyKey"] as? String ?? UUID().uuidString)
                return toolResult(["taskId": task.id.uuidString, "status": task.status.rawValue])
            } catch { return toolError(error) }
        }
        if name == "file.search" {
            guard args.keys.allSatisfy({ ["rootId", "query"].contains($0) }), let query = args["query"] as? String, query.count <= 120, let records = try? await container.fileRepository.searchRecords(forRootID: rootID, query: query) else { return toolError("Некорректный поисковый запрос.") }
            return toolResult(["records": records.map(recordPayload)])
        }
        if name == "file.analyze_storage" {
            guard args.keys.allSatisfy({ $0 == "rootId" }), let records = try? await container.fileRepository.records(forRootID: rootID) else { return toolError("Некорректные параметры.") }
            return toolResult(["fileCount": records.count, "totalByteSize": records.reduce(Int64(0)) { $0 + $1.byteSize }])
        }
        if name == "file.find_duplicates" {
            guard args.keys.allSatisfy({ $0 == "rootId" }), let records = try? await container.fileRepository.records(forRootID: rootID) else { return toolError("Некорректные параметры.") }
            let groups = Dictionary(grouping: records.filter { $0.contentHash != nil }, by: { $0.contentHash! }).values.filter { $0.count > 1 }
            return toolResult(["groups": groups.map { ["hash": $0[0].contentHash!, "records": $0.map(recordPayload)] }])
        }
        return toolError("Инструмент не разрешён. Сканирование запускается только из интерфейса приложения.")
    }

    private static var localDefinitions: [[String: Any]] {
        definitions.map { original in
            var definition = original
            guard let name = definition["name"] as? String, ["file.scan", "file.get_task", "file.search", "file.analyze_storage", "file.find_duplicates"].contains(name),
                  var schema = definition["inputSchema"] as? [String: Any], var properties = schema["properties"] as? [String: Any] else { return definition }
            if ["file.scan", "file.get_task"].contains(name) {
                schema["required"] = [name == "file.get_task" ? "taskId" : "rootId"]; definition["inputSchema"] = schema; return definition
            }
            properties["snapshotId"] = ["type": "string", "format": "uuid"]
            properties["cursor"] = ["type": "string", "maxLength": 4095]
            properties["pageSize"] = ["type": "integer", "minimum": 1, "maximum": 100]
            schema["properties"] = properties; schema["required"] = ["rootId"]; definition["inputSchema"] = schema
            return definition
        } + [definition("file.compute_duplicates", "Вычисляет SHA-256 для версий файлов текущего снимка; возвращает taskId.",
            ["rootId": ["type": "string", "format": "uuid"], "snapshotId": ["type": "string", "format": "uuid"], "idempotencyKey": ["type": "string", "maxLength": 128]], required: ["rootId"])] + RuleMCP.definitions + LocalAccessMCP.tools + LocalInboxMCP.tools
    }
    private static let definitions: [[String: Any]] = [
        definition("file.list_roots", "Список разрешённых папок; только чтение.", [:]),
        definition("file.scan", "Запускает индексирование уже разрешённой папки.", ["rootId": ["type": "string", "format": "uuid"], "correlationId": ["type": "string"], "idempotencyKey": ["type": "string", "maxLength": 128]]),
        definition("file.get_task", "Статус фоновой задачи.", ["taskId": ["type": "string", "format": "uuid"]]),
        definition("file.search", "Поиск в локальном индексе.", ["rootId": ["type": "string", "format": "uuid"], "query": ["type": "string", "maxLength": 120]]),
        definition("file.find_duplicates", "Сохранённые результаты SHA-256.", ["rootId": ["type": "string", "format": "uuid"]]),
        definition("file.analyze_storage", "Сводка локального индекса.", ["rootId": ["type": "string", "format": "uuid"]]),
        definition("file.get_audit_report", "Обезличенный журнал.", [:])
    ]
    private static func definition(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] { ["name": name, "description": RuntimeLocalization.bilingual(description), "inputSchema": ["type": "object", "additionalProperties": false, "properties": properties, "required": required]] }
    private static func recordPayload(_ record: FileRecord) -> [String: Any] { ["id": record.id.uuidString, "relativePath": record.relativePath, "name": record.fileName, "byteSize": record.byteSize] }
    private static func toolResult(_ object: [String: Any]) -> [String: Any] { ["content": [["type": "text", "text": json(object)]], "isError": false] }
    private static func toolError(_ key: String) -> [String: Any] {
        ["content": [["type": "text", "text": AgentLocalization(language: RuntimeLocalization.clientLanguage).runtimeText(key)]], "isError": true]
    }
    /// Произвольный localizedDescription не становится ключом или ответом клиенту.
    private static func toolError(_ error: Error) -> [String: Any] {
        ["content": [["type": "text", "text": AgentLocalization(language: RuntimeLocalization.clientLanguage).runtimeError(error)]], "isError": true]
    }
    private static func json(_ object: [String: Any]) -> String { guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }; return String(data: data, encoding: .utf8) ?? "{}" }
}
