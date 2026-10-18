import CoreFoundation
import Foundation

/// Проверяет именно опубликованную MCP-схему до нормализации значений и RPC.
/// Неизвестные ограничения запрещены: обновление схемы не должно незаметно
/// расширять принимаемые данные при старом валидаторе.
public enum MCPInputSchemaValidator {
    public static func validate(arguments: Data, schema: Data) throws {
        guard arguments.count <= 1_048_576, schema.count <= 1_048_576 else { throw LocalRuntimeFailure.invalidRequest }
        do {
            let value = try JSONSerialization.jsonObject(with: arguments, options: [.fragmentsAllowed])
            let definition = try JSONSerialization.jsonObject(with: schema, options: [.fragmentsAllowed])
            var budget = 10_000
            try checkSchema(definition, depth: 0, budget: &budget)
            budget = 10_000
            try checkTree(value, depth: 0, budget: &budget)
            budget = 100_000
            guard matches(value, definition, depth: 0, budget: &budget), budget >= 0 else { throw LocalRuntimeFailure.invalidRequest }
        } catch { throw LocalRuntimeFailure.invalidRequest }
    }

    private static let keywords: Set<String> = ["$schema", "title", "description", "default", "examples", "type", "properties", "required", "additionalProperties", "items", "minItems", "maxItems", "uniqueItems", "minLength", "maxLength", "pattern", "format", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "enum", "const", "anyOf", "oneOf", "allOf"]
    private static let types: Set<String> = ["object", "array", "string", "integer", "number", "boolean", "null"]

    private static func checkTree(_ value: Any, depth: Int, budget: inout Int) throws {
        budget -= 1
        guard depth <= 16, budget >= 0 else { throw LocalRuntimeFailure.invalidRequest }
        if let object = value as? [String: Any] {
            for item in object.values { try checkTree(item, depth: depth + 1, budget: &budget) }
        } else if let array = value as? [Any] {
            for item in array { try checkTree(item, depth: depth + 1, budget: &budget) }
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func numeric(_ value: Any) -> NSNumber? {
        guard !isBoolean(value), let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number
    }

    /// Decimal сохраняет границу Int64: Double округляет Int64.max к 2^63.
    private static func integer(_ value: Any) -> Bool {
        guard let number = numeric(value) else { return false }
        var decimal = number.decimalValue
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 0, .plain)
        return decimal == rounded && decimal >= Decimal(Int64.min) && decimal <= Decimal(Int64.max)
    }

    private static func checkSchema(_ raw: Any, depth: Int, budget: inout Int) throws {
        budget -= 1
        guard depth <= 16, budget >= 0 else { throw LocalRuntimeFailure.invalidRequest }
        if isBoolean(raw) { return }
        guard let schema = raw as? [String: Any], Set(schema.keys).isSubset(of: keywords) else { throw LocalRuntimeFailure.invalidRequest }
        if let type = schema["type"] {
            let values = (type as? String).map { [$0] } ?? (type as? [String] ?? [])
            guard !values.isEmpty, Set(values).isSubset(of: types), Set(values).count == values.count else { throw LocalRuntimeFailure.invalidRequest }
        }
        if let rawProperties = schema["properties"] {
            guard let properties = rawProperties as? [String: Any] else { throw LocalRuntimeFailure.invalidRequest }
            for child in properties.values { try checkSchema(child, depth: depth + 1, budget: &budget) }
        }
        if let required = schema["required"] {
            guard let names = required as? [String], Set(names).count == names.count else { throw LocalRuntimeFailure.invalidRequest }
        }
        if let additional = schema["additionalProperties"] {
            // Схемы дополнительных свойств тоже поддержаны, без неявного приведения Bool/1.
            try checkSchema(additional, depth: depth + 1, budget: &budget)
        }
        if let items = schema["items"] { try checkSchema(items, depth: depth + 1, budget: &budget) }
        for key in ["minItems", "maxItems", "minLength", "maxLength"] {
            if let value = schema[key] { guard integer(value), (numeric(value)?.decimalValue ?? -1) >= 0 else { throw LocalRuntimeFailure.invalidRequest } }
        }
        for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
            if let value = schema[key], numeric(value) == nil { throw LocalRuntimeFailure.invalidRequest }
        }
        if let unique = schema["uniqueItems"], !isBoolean(unique) { throw LocalRuntimeFailure.invalidRequest }
        if let pattern = schema["pattern"] {
            guard let pattern = pattern as? String, pattern.utf8.count <= 1024,
                  (try? NSRegularExpression(pattern: pattern)) != nil else { throw LocalRuntimeFailure.invalidRequest }
        }
        if let format = schema["format"] {
            guard let format = format as? String, ["uuid", "date-time"].contains(format) else { throw LocalRuntimeFailure.invalidRequest }
        }
        if let values = schema["enum"] {
            guard let values = values as? [Any], !values.isEmpty else { throw LocalRuntimeFailure.invalidRequest }
            for value in values { try checkTree(value, depth: depth + 1, budget: &budget) }
        }
        if let value = schema["const"] { try checkTree(value, depth: depth + 1, budget: &budget) }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let rawBranches = schema[key] {
                guard let branches = rawBranches as? [Any], !branches.isEmpty, branches.count <= 32 else { throw LocalRuntimeFailure.invalidRequest }
                for child in branches { try checkSchema(child, depth: depth + 1, budget: &budget) }
            }
        }
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        if isBoolean(lhs) || isBoolean(rhs) {
            return isBoolean(lhs) && isBoolean(rhs) && (lhs as? NSNumber) == (rhs as? NSNumber)
        }
        if let left = numeric(lhs), let right = numeric(rhs) { return left.decimalValue == right.decimalValue }
        if lhs is NSNull || rhs is NSNull { return lhs is NSNull && rhs is NSNull }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        if let left = lhs as? [Any], let right = rhs as? [Any] { return left.count == right.count && zip(left, right).allSatisfy { equal($0, $1) } }
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] { return Set(left.keys) == Set(right.keys) && left.allSatisfy { key, value in right[key].map { equal(value, $0) } ?? false } }
        return false
    }

    private static func identity(_ value: Any) -> String {
        if isBoolean(value) { return "b:" + ((value as? NSNumber)?.boolValue == true ? "1" : "0") }
        if let number = numeric(value) { return "n:" + NSDecimalNumber(decimal: number.decimalValue).stringValue }
        if value is NSNull { return "null" }
        if let string = value as? String {
            let encoded = (try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed])) ?? Data()
            return "s:" + String(decoding: encoded, as: UTF8.self)
        }
        if let array = value as? [Any] { return "[" + array.map(identity).joined(separator: ",") + "]" }
        if let object = value as? [String: Any] {
            return "{" + object.keys.sorted().map { identity($0) + ":" + identity(object[$0]!) }.joined(separator: ",") + "}"
        }
        return "invalid"
    }

    private static func hasType(_ value: Any, _ type: String) -> Bool {
        switch type {
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "string": return value is String
        case "integer": return integer(value)
        case "number": return numeric(value) != nil
        case "boolean": return isBoolean(value)
        case "null": return value is NSNull
        default: return false
        }
    }

    private static func matches(_ value: Any, _ raw: Any, depth: Int, budget: inout Int) -> Bool {
        budget -= 1
        guard depth <= 16, budget >= 0 else { return false }
        if isBoolean(raw) { return (raw as? NSNumber)?.boolValue == true }
        guard let schema = raw as? [String: Any] else { return false }
        if let type = schema["type"] {
            let types = (type as? String).map { [$0] } ?? (type as? [String] ?? [])
            guard types.contains(where: { hasType(value, $0) }) else { return false }
        }
        if let constant = schema["const"], !equal(value, constant) { return false }
        if let choices = schema["enum"] as? [Any], !choices.contains(where: { equal(value, $0) }) { return false }
        for key in ["anyOf", "oneOf", "allOf"] {
            if let branches = schema[key] as? [Any] {
                let count = branches.filter { matches(value, $0, depth: depth + 1, budget: &budget) }.count
                if key == "anyOf" && count == 0 || key == "oneOf" && count != 1 || key == "allOf" && count != branches.count { return false }
            }
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            guard (schema["required"] as? [String] ?? []).allSatisfy({ object[$0] != nil }) else { return false }
            for (key, item) in object {
                if let child = properties[key] { if !matches(item, child, depth: depth + 1, budget: &budget) { return false } }
                else if let additional = schema["additionalProperties"], !matches(item, additional, depth: depth + 1, budget: &budget) { return false }
            }
        }
        if let array = value as? [Any] {
            if let minimum = schema["minItems"].flatMap(numeric), Decimal(array.count) < minimum.decimalValue { return false }
            if let maximum = schema["maxItems"].flatMap(numeric), Decimal(array.count) > maximum.decimalValue { return false }
            if let items = schema["items"], !array.allSatisfy({ matches($0, items, depth: depth + 1, budget: &budget) }) { return false }
            if (schema["uniqueItems"] as? NSNumber)?.boolValue == true {
                // Канонические ключи дают линейную проверку вместо O(n²),
                // сохраняя равенство 1/1.0 и различие true/1.
                var seen: Set<String> = []
                for item in array { if !seen.insert(identity(item)).inserted { return false } }
            }
        }
        if let string = value as? String {
            // JSON Schema считает Unicode scalars, а не UTF-8 байты или grapheme clusters.
            let length = Decimal(string.unicodeScalars.count)
            if let minimum = schema["minLength"].flatMap(numeric), length < minimum.decimalValue { return false }
            if let maximum = schema["maxLength"].flatMap(numeric), length > maximum.decimalValue { return false }
            if let pattern = schema["pattern"] as? String, string.range(of: pattern, options: .regularExpression) == nil { return false }
            if let format = schema["format"] as? String {
                if format == "uuid" && UUID(uuidString: string) == nil { return false }
                if format == "date-time" {
                    guard string.hasSuffix("Z"), string.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$"#, options: .regularExpression) != nil else { return false }
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let fractional = formatter.date(from: string)
                    formatter.formatOptions = [.withInternetDateTime]
                    guard let date = fractional ?? formatter.date(from: string) else { return false }
                    // Foundation может нормализовать невозможный день месяца;
                    // обратное преобразование не позволяет принять 30 февраля.
                    guard formatter.string(from: date) == String(string.prefix(19)) + "Z" else { return false }
                }
            }
        }
        if let number = numeric(value) {
            for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
                if let limit = schema[key].flatMap(numeric) {
                    let number = number.decimalValue, bound = limit.decimalValue
                    if key == "minimum" && number < bound || key == "maximum" && number > bound || key == "exclusiveMinimum" && number <= bound || key == "exclusiveMaximum" && number >= bound { return false }
                }
            }
        }
        return true
    }
}
