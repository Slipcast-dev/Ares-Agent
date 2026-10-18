import Foundation

/// Условия проверяются над снимком. Исключения всегда применяются независимо
/// от режима OR, иначе «любое условие» могло бы вернуть служебный каталог.
public enum RuleMatching {
    public static func wildcard(_ value: String, pattern: String) -> Bool {
        // Динамическое программирование O(pattern × name) не имеет
        // экспоненциального regex backtracking на последовательностях *a*a*.
        guard value.count <= 4096, pattern.count <= 512 else { return false }
        let text = Array(value.lowercased()), mask = Array(pattern.lowercased())
        var previous = [Bool](repeating: false, count: text.count + 1); previous[0] = true
        for symbol in mask {
            var current = [Bool](repeating: false, count: text.count + 1)
            if symbol == "*" { current[0] = previous[0] }
            for index in text.indices {
                current[index + 1] = symbol == "*" ? previous[index + 1] || current[index] : previous[index] && (symbol == "?" || symbol == text[index])
            }
            previous = current
        }
        return previous[text.count]
    }
    public static func matches(_ file: RuleFileSnapshot, rule: AutomationRule) -> Bool {
        let parts = file.relativePath.split(separator: "/").map(String.init)
        guard rule.includeSubfolders || parts.count == 1 else { return false }
        let protected: Set<String> = ["library", "system", "applications", "node_modules", "pods", "vendor", "ares results", "file organizer results"]
        guard !parts.contains(where: { $0.hasPrefix(".") || protected.contains($0.lowercased()) || $0.lowercased().hasSuffix(".app") || $0.lowercased().hasSuffix(".framework") || $0.lowercased().hasSuffix(".bundle") }) else { return false }
        let conditions = rule.conditions
        guard !conditions.excludedPaths.contains(where: { file.relativePath == $0 || file.relativePath.hasPrefix($0 + "/") }),
              !conditions.excludedNames.contains(where: { wildcard((file.relativePath as NSString).lastPathComponent, pattern: $0) }) else { return false }
        let name = (file.relativePath as NSString).lastPathComponent
        var checks: [Bool] = []
        if !conditions.extensions.isEmpty { checks.append(conditions.extensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.contains((name as NSString).pathExtension.lowercased())) }
        if !conditions.name.isEmpty {
            let a = name.lowercased(), b = conditions.name.lowercased()
            switch conditions.nameMatch {
            case .contains: checks.append(a.contains(b))
            case .prefix: checks.append(a.hasPrefix(b))
            case .suffix: checks.append(a.hasSuffix(b))
            case .wildcard: checks.append(wildcard(name, pattern: conditions.name))
            }
        }
        if let min = conditions.minimumBytes { checks.append(file.byteSize >= min) }
        if let max = conditions.maximumBytes { checks.append(file.byteSize <= max) }
        if !conditions.requiredTag.isEmpty { checks.append(file.tags.contains(conditions.requiredTag)) }
        if !conditions.absentTag.isEmpty { checks.append(!file.tags.contains(conditions.absentTag)) }
        if let date = conditions.modifiedAfter { checks.append(file.modifiedAt.map { $0 >= date } ?? false) }
        if let date = conditions.createdAfter { checks.append(file.createdAt.map { $0 >= date } ?? false) }
        if let date = conditions.firstSeenAfter { checks.append(file.firstSeenAt >= date) }
        return checks.isEmpty || (conditions.allConditions ? checks.allSatisfy { $0 } : checks.contains(true))
    }
}
