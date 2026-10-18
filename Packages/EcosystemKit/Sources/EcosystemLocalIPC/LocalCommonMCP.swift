import Foundation
import EcosystemContracts

/// Единый внешний словарь двух независимых агентов. Runtime продолжает
/// проверять grant по проверенному XPC listener; clientInfo из MCP не даёт прав.
public enum LocalCommonMCP {
    public static let names = ["agent.get_capabilities", "agent.get_status", "task.get", "task.list",
                               "task.get_result", "task.cancel", "event.list", "audit.list"]
    public static var tools: [[String: Any]] {
        names.map { name in
            var properties: [String: Any] = [:], required: [String] = []
            if ["task.get", "task.get_result", "task.cancel"].contains(name) {
                properties["taskId"] = ["type": "string", "format": "uuid"]; required = ["taskId"]
            } else if ["task.list", "event.list", "audit.list"].contains(name) {
                properties["pageSize"] = ["type": "integer", "minimum": 1, "maximum": 100]
                properties["cursor"] = ["type": "string", "minLength": 1, "maxLength": 4095]
                if name == "audit.list" {
                    properties["capability"] = ["type": "string", "minLength": 1, "maxLength": 128]
                    properties["status"] = ["type": "string", "enum": TaskStatus.allCases.map(\.rawValue)]
                    properties["since"] = ["type": "string", "format": "date-time"]
                }
            } else if name == "agent.get_capabilities" {
                properties["contractVersion"] = ["type": "object", "additionalProperties": false,
                    "properties": ["major": ["type": "integer", "minimum": 0], "minor": ["type": "integer", "minimum": 0]], "required": ["major"]]
            }
            return ["name": name, "description": "Общая операция локального агента: " + name,
                    "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
    }
    public static func call(_ name: String, arguments: [String: Any], domain: String,
                            toolNames: [String], client: LocalRPCClient,
                            resultProjection: @Sendable (UUID) async throws -> [String: Any]) async throws -> [String: Any] {
        guard names.contains(name) else { throw LocalRuntimeFailure.invalidRequest }
        if name == "agent.get_capabilities" {
            if let requested = arguments["contractVersion"] as? [String: Any], (requested["major"] as? Int) != 1 {
                return ["error": ["code": "INCOMPATIBLE_VERSION", "message": "Поддерживается major 1.", "retryable": false, "correlationId": UUID().uuidString]]
            }
            return ["agentId": domain, "contractVersion": ["major": 1, "minor": 0],
                "protocolVersions": ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"],
                "tools": toolNames, "limits": ["frameBytes": 1_048_576, "concurrentRequests": 8, "pageSize": 100, "requestSeconds": 310],
                "taskPolicy": ["continueOnDisconnect": true, "cancelRequiresExplicitTool": true],
                "authorization": "local-grant-and-operating-system", "nativeMCPTasks": false]
        }
        if name == "agent.get_status" {
            let value = try await exchange("runtime.status", arguments: [:], client: client)
            return ["agentId": domain, "healthy": value["healthy"] ?? false,
                    "runtimeIntegrated": value["runtimeIntegrated"] ?? false]
        }
        if ["task.list", "event.list", "audit.list"].contains(name) {
            return try await exchange("mcp." + name, arguments: arguments, client: client)
        }
        guard let text = arguments["taskId"] as? String, let id = UUID(uuidString: text) else { throw LocalRuntimeFailure.invalidRequest }
        if name == "task.cancel" {
            let _: LocalEmpty = try await client.call("task.cancel", LocalTaskID(id))
        }
        var metadata = try await exchange("mcp.task.get", arguments: ["id": text], client: client)
        if name == "task.cancel" { metadata["cancellationRequested"] = true }
        if name == "task.get_result" {
            // Проекция результата проходит прежний доменный ACL и quota повторно.
            // Отдельный metadata endpoint доступен и при слишком большом result.
            let projection = try await resultProjection(id)
            metadata["available"] = projection["result"] != nil
            metadata["data"] = projection["result"] ?? NSNull()
        }
        return metadata
    }
    private static func exchange(_ operation: String, arguments: [String: Any], client: LocalRPCClient) async throws -> [String: Any] {
        struct Reply: Decodable { let version: Int; let domain: String; let result: Data?; let error: LocalRuntimeFailure? }
        let request = LocalRPCRequest(domain: client.configuration.domain, operation: operation,
            payload: try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
        let reply = try LocalWire.decode(Reply.self, await client.exchange(LocalWire.encode(request)))
        guard reply.version == 1, reply.domain == client.configuration.domain else { throw LocalRuntimeFailure.invalidRequest }
        if let error = reply.error { throw error }
        guard let data = reply.result, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LocalRuntimeFailure.operationFailed }
        return object
    }
    public static func result(_ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": String(decoding: payload, as: UTF8.self)]],
            "structuredContent": object, "isError": object["error"] != nil], options: [.sortedKeys])
    }
    public static func failure(_ error: Error) -> Data {
        let safe = LocalRuntimeFailure.safe(error)
        return (try? result(["error": ["code": safe.knownCode.rawValue,
            "message": safe.errorDescription ?? "Ошибка локального агента.",
            "retryable": [LocalRuntimeFailure.busy, .unavailable].contains(safe),
            "correlationId": UUID().uuidString, "suggestedAction": "Проверьте состояние агента и локальные разрешения."]])) ?? Data()
    }
}
