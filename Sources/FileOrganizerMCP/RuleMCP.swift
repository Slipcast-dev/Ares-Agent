import CoreFoundation
import Foundation
import FileOrganizerCore
import EcosystemLocalIPC
import EcosystemLocalization

/// MCP может создавать выключенный проект, но не подтверждать план.
/// Нормализация default значений выполняется до строгого server decoding.
enum RuleMCP {
    /// Нормализация внутренних моделей обязана получать JSON-объект. Модель
    /// может позднее изменить Encodable и выдать массив/скаляр: такой сбой
    /// возвращается как штатная ошибка MCP, а не завершает весь stdio-процесс.
    /// Подробности Encoder не раскрываем клиенту: они относятся к внутренней
    /// реализации, а не к некорректным аргументам пользователя.
    static func encodedModelObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        do {
            let data = try JSONEncoder().encode(value)
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard let dictionary = object as? [String: Any] else {
                throw LocalRuntimeFailure.operationFailed
            }
            return dictionary
        } catch {
            throw LocalRuntimeFailure.operationFailed
        }
    }

    private struct Reply: Decodable { let version: Int; let domain: String; let result: Data?; let error: LocalRuntimeFailure? }
    static let names = ["rule.list", "rule.get", "rule.validate", "rule.preview", "rule.propose", "rule.run", "rule.request_enable", "rule.disable", "rule.history"]
    static func call(_ name: String, args: [String: Any], client: LocalRPCClient, context: MCPCallContext? = nil) async throws -> [String: Any] {
        let allowed: Set<String>
        switch name {
        case "rule.list": allowed = ["offset"]
        case "rule.validate", "rule.propose": allowed = ["rule"]
        case "rule.run": allowed = ["ruleId", "planId", "idempotencyKey", "eventID", "processingToken"]
        case "rule.history": allowed = ["ruleId", "runId", "offset", "cursor"]
        default: allowed = ["ruleId"]
        }
        guard names.contains(name), Set(args.keys).isSubset(of: allowed) else { throw LocalRuntimeFailure.invalidRequest }
        var wire: [String: Any] = [:]
        for (external, local) in [("ruleId", "ruleID"), ("planId", "planID"), ("runId", "runID")] {
            if let value = args[external] { guard let text = value as? String, UUID(uuidString: text) != nil else { throw LocalRuntimeFailure.invalidRequest }; wire[local] = text }
        }
        if let cursor = args["cursor"] {
            guard let cursor = cursor as? String, !cursor.isEmpty, cursor.utf8.count <= 2048, args["offset"] == nil, args["runId"] == nil else { throw LocalRuntimeFailure.invalidRequest }
            wire["cursor"] = cursor
        }
        if let offset = args["offset"] {
            guard let number = offset as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue, (0...100_000).contains(number.intValue) else { throw LocalRuntimeFailure.invalidRequest }
            wire["offset"] = number.intValue
        }
        if name == "rule.run" {
            guard (args["eventID"] == nil) == (args["processingToken"] == nil) else { throw LocalRuntimeFailure.invalidRequest }
            if let event = args["eventID"], let token = args["processingToken"] {
                guard args["idempotencyKey"] == nil,
                      let event = event as? String, UUID(uuidString: event) != nil,
                      let token = token as? String, UUID(uuidString: token) != nil else { throw LocalRuntimeFailure.invalidRequest }
                wire["eventID"] = event; wire["processingToken"] = token
            } else {
                let key = args["idempotencyKey"] ?? UUID().uuidString
                guard let key = key as? String, !key.isEmpty, key.utf8.count <= 128 else { throw LocalRuntimeFailure.invalidRequest }
                wire["key"] = key
            }
        }
        if ["rule.validate", "rule.propose"].contains(name) {
            guard let draft = args["rule"] as? [String: Any] else { throw LocalRuntimeFailure.invalidRequest }
            // Запрещаем передавать permission/enabled/content consent как аргументы.
            var normalized = try encodedModelObject(AutomationRule())
            guard Set(draft.keys).isSubset(of: Set(normalized.keys).union(["rootID", "maximumFiles", "maximumBytes", "sourceRuleID", "scheduleTimeZone"]).subtracting(["id", "enabled", "allowContentReading"])) else { throw LocalRuntimeFailure.invalidRequest }
            for (key, value) in draft { normalized[key] = value }
            if let conditions = draft["conditions"] as? [String: Any] {
                var defaults = try encodedModelObject(RuleConditions())
                let optional: Set<String> = ["minimumBytes", "maximumBytes", "modifiedAfter", "createdAfter", "firstSeenAfter"]
                guard Set(conditions.keys).isSubset(of: Set(defaults.keys).union(optional)) else { throw LocalRuntimeFailure.invalidRequest }
                defaults.merge(conditions) { _, value in value }; normalized["conditions"] = defaults
            }
            if let actions = draft["actions"] as? [[String: Any]] {
                normalized["actions"] = try actions.map { action -> [String: Any] in
                    guard Set(action.keys).isSubset(of: ["kind", "value", "destinationRootID", "nextRuleID", "archiveTogether"]) else { throw LocalRuntimeFailure.invalidRequest }
                    var defaults = try encodedModelObject(RuleAction(kind: .log))
                    defaults.merge(action) { _, value in value }; return defaults
                }
            }
            // Внешние даты ISO 8601; numeric reference dates не принимаются.
            let formatter = ISO8601DateFormatter()
            func referenceDate(_ value: Any) throws -> Double {
                guard let text = value as? String else { throw LocalRuntimeFailure.invalidRequest }
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let date = formatter.date(from: text)
                formatter.formatOptions = [.withInternetDateTime]
                guard let result = date ?? formatter.date(from: text), text.hasSuffix("Z") else { throw LocalRuntimeFailure.invalidRequest }
                return result.timeIntervalSinceReferenceDate
            }
            if let date = draft["scheduleDate"] { normalized["scheduleDate"] = try referenceDate(date) }
            if let supplied = draft["conditions"] as? [String: Any], var conditions = normalized["conditions"] as? [String: Any] {
                for key in ["modifiedAfter", "createdAfter", "firstSeenAfter"] {
                    if let date = supplied[key] { conditions[key] = try referenceDate(date) }
                }
                normalized["conditions"] = conditions
            }
            wire["rule"] = normalized
        }
        let payload = try JSONDecoder().decode(RuleControlRequest.self, from: JSONSerialization.data(withJSONObject: wire))
        let request = LocalRPCRequest(domain: "ares", operation: name, payload: try LocalWire.encode(payload))
        let reply = try LocalWire.decode(Reply.self, await client.exchange(LocalWire.encode(request)))
        guard reply.version == 1, reply.domain == "ares" else { throw LocalRuntimeFailure.invalidRequest }
        if let error = reply.error { throw error }
        guard let data = reply.result else { throw LocalRuntimeFailure.invalidRequest }
        var resultData = data
        if name == "rule.preview" {
            let id = try LocalWire.decode(LocalTaskID.self, data)
            let plan: RulePlanSummary = try await client.waitForResult(id.id, cancelOnCancellation: false, onProgress: { progress in
                if let progress { await context?.progress(Double(progress.processed.value), progress.total.map { Double($0.value) }, AgentLocalization(language: RuntimeLocalization.clientLanguage).runtimeText("Выполнение")) }
            })
            resultData = try LocalWire.encode(plan)
        }
        let object = try JSONSerialization.jsonObject(with: resultData)
        if name == "rule.run", let result = object as? [String: Any] { return ["taskId": result["id"] ?? NSNull(), "status": "accepted"] }
        if name == "rule.propose", let result = object as? [String: Any] { return ["ruleId": result["id"] ?? NSNull(), "enabled": false] }
        guard var result = object as? [String: Any] else { throw LocalRuntimeFailure.operationFailed }
        if let date = result["expiresAt"] as? Double {
            let formatter = ISO8601DateFormatter(); result["expiresAt"] = formatter.string(from: Date(timeIntervalSinceReferenceDate: date))
        }
        if var rule = result["rule"] as? [String: Any] {
            let formatter = ISO8601DateFormatter()
            if let date = rule["scheduleDate"] as? Double { rule["scheduleDate"] = formatter.string(from: Date(timeIntervalSinceReferenceDate: date)) }
            if var conditions = rule["conditions"] as? [String: Any] {
                for key in ["modifiedAfter", "createdAfter", "firstSeenAfter"] {
                    if let date = conditions[key] as? Double { conditions[key] = formatter.string(from: Date(timeIntervalSinceReferenceDate: date)) }
                }
                rule["conditions"] = conditions
            }
            result["rule"] = rule
        }
        return result
    }
    /// Полная вложенная схема даёт клиенту тот же набор полей, который затем
    /// нормализуется в AutomationRule. Идентичность и локальное согласие в неё
    /// намеренно не входят; серверная проверка прав остаётся обязательной.
    private static var ruleSchema: [String: Any] {
        let uuid: [String: Any] = ["type": "string", "format": "uuid"]
        let date: [String: Any] = ["type": "string", "format": "date-time"]
        let size: [String: Any] = ["type": "integer", "minimum": 0, "maximum": Int64.max]
        func text(_ maximum: Int) -> [String: Any] { ["type": "string", "maxLength": maximum] }
        func strings(_ maximumItems: Int, _ maximumLength: Int) -> [String: Any] {
            ["type": "array", "maxItems": maximumItems, "items": text(maximumLength)]
        }
        let conditions: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [
            "extensions": strings(1000, 255), "name": text(120),
            "nameMatch": ["type": "string", "enum": RuleNameMatch.allCases.map(\.rawValue)],
            "minimumBytes": size, "maximumBytes": size,
            "requiredTag": text(200), "absentTag": text(200),
            "excludedPaths": strings(100, 4096), "excludedNames": strings(100, 120),
            "modifiedAfter": date, "createdAfter": date, "firstSeenAfter": date,
            "allConditions": ["type": "boolean"]
        ]]
        let action: [String: Any] = ["type": "object", "additionalProperties": false, "properties": [
            "kind": ["type": "string", "enum": RuleActionKind.allCases.map(\.rawValue), "default": "log"],
            "value": text(409600), "destinationRootID": uuid, "nextRuleID": uuid,
            "archiveTogether": ["type": "boolean"]
        ]]
        return ["type": "object", "additionalProperties": false,
            "description": RuntimeLocalization.bilingual("Выключенный проект правила. Подтверждение действий и чтения содержимого выполняется в локальном интерфейсе."),
            "properties": [
                "name": ["type": "string", "minLength": 1, "maxLength": 200], "rootID": uuid,
                "maximumFiles": ["type": "integer", "minimum": 1, "maximum": 1000],
                "maximumBytes": ["type": "integer", "minimum": 1, "maximum": 1073741824],
                "includeSubfolders": ["type": "boolean"], "processExisting": ["type": "boolean"],
                "event": ["type": "string", "enum": RuleEvent.allCases.map(\.rawValue)], "eventValue": text(409600),
                "threshold": size, "days": ["type": "integer", "minimum": 1, "maximum": Int64.max],
                "schedule": ["type": "string", "enum": RuleSchedule.allCases.map(\.rawValue)],
                "scheduleDate": date, "intervalSeconds": ["type": "integer", "minimum": 30, "maximum": Int64.max],
                "scheduleTimeZone": ["type": "string", "minLength": 1, "maxLength": 100],
                "catchUpOnce": ["type": "boolean"], "sourceRuleID": uuid,
                "conditions": conditions,
                "actions": ["type": "array", "minItems": 1, "maxItems": 32, "items": action]
            ]]
    }

    static var definitions: [[String: Any]] {
        names.map { name in
            var properties: [String: Any] = [:]; var required: [String] = []
            if ["rule.validate", "rule.propose"].contains(name) {
                properties["rule"] = ruleSchema
                required = ["rule"]
            } else if name != "rule.list" { properties["ruleId"] = ["type": "string", "format": "uuid"]; required = ["ruleId"] }
            if name == "rule.run" {
                properties["planId"] = ["type": "string", "format": "uuid"]
                properties["idempotencyKey"] = ["type": "string", "minLength": 1, "maxLength": 128]
                properties["eventID"] = ["type": "string", "format": "uuid"]
                properties["processingToken"] = ["type": "string", "format": "uuid"]
            }
            if name == "rule.history" { properties["runId"] = ["type": "string", "format": "uuid"]; properties["cursor"] = ["type": "string", "minLength": 1, "maxLength": 2048] }
            if ["rule.list", "rule.history"].contains(name) { properties["offset"] = ["type": "integer", "minimum": 0, "maximum": 100000] }
            return ["name": name, "description": RuntimeLocalization.bilingual("Правила Ares: %@. Мутации требуют локально утверждённого плана или включённого правила; MCP не выдаёт подтверждение.", name), "inputSchema": ["type": "object", "additionalProperties": false, "properties": properties, "required": required]]
        }
    }
}
