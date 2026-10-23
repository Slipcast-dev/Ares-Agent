import Foundation
import EcosystemLocalization

/// Запрос разрешения возвращает план сразу. MCP не ждёт пользователя и не
/// получает approve/revoke; подтверждение остаётся локальным GUI действием.
public enum LocalAccessMCP {
    public static let names = ["access.status", "access.request"]
    public static var tools: [[String: Any]] {
        [
            ["name": "access.status", "description": RuntimeLocalization.bilingual("Мои действующие разрешения и ожидающие планы; без приватных данных других клиентов."), "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]],
            ["name": "access.request", "description": RuntimeLocalization.bilingual("Предложить ограниченный доступ и получить план для подтверждения в локальном окне агента. Не включает доступ автоматически."), "inputSchema": ["type": "object", "properties": ["draft": ["type": "object", "properties": ["roots": ["type": "array", "items": ["type": "string", "format": "uuid"], "maxItems": 128], "capabilities": ["type": "array", "items": ["type": "string"]], "dataClass": ["type": "string", "enum": ["aggregate", "fileMetadata"]], "maximumResultObjects": ["type": "integer", "minimum": 1, "maximum": 1000], "maximumResponseBytes": ["type": "integer", "minimum": 1024, "maximum": 524288], "maximumSourceObjects": ["type": "integer", "minimum": 1, "maximum": 1000], "maximumSourceBytes": ["type": "integer", "minimum": 1, "maximum": 1073741824], "maximumRequests": ["type": "integer", "minimum": 1, "maximum": 10000], "periodSeconds": ["type": "integer", "minimum": 60, "maximum": 86400], "lifetimeSeconds": ["type": "integer", "minimum": 60, "maximum": 2592000]], "additionalProperties": false, "required": ["capabilities"]]], "required": ["draft"], "additionalProperties": false]]
        ]
    }
    public static func call(_ name: String, args: [String: Any], client: LocalRPCClient) async throws -> [String: Any] {
        guard names.contains(name), Set(args.keys).isSubset(of: name == "access.request" ? ["draft"] : []) else { throw LocalRuntimeFailure.invalidRequest }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let result: Data
        if name == "access.status" { result = try encoder.encode(await client.call(name, LocalAccessRequest(), as: LocalAccessState.self)) }
        else {
            guard let input = args["draft"] as? [String: Any] else { throw LocalRuntimeFailure.invalidRequest }
            var defaults = try JSONSerialization.jsonObject(with: LocalWire.encode(LocalAccessDraft())) as! [String: Any]
            guard Set(input.keys).isSubset(of: Set(defaults.keys).subtracting(["client"])) else { throw LocalRuntimeFailure.invalidRequest }
            defaults.merge(input) { _, value in value }; defaults["client"] = (client.configuration.selectedMCPClient ?? .legacy).rawValue
            let draft = try LocalWire.decode(LocalAccessDraft.self, JSONSerialization.data(withJSONObject: defaults))
            result = try encoder.encode(await client.call(name, LocalAccessRequest(draft: draft), as: LocalAccessPlan.self))
        }
        return try JSONSerialization.jsonObject(with: result) as? [String: Any] ?? [:]
    }
}
