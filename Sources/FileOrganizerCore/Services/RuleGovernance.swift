import Foundation
import EcosystemLocalIPC
import EcosystemRuntimeSupport

/// Управление разрешениями живёт у единственного runtime. MCP может предложить
/// выключенное правило и запросить план; подтверждает только проверенная GUI роль.
actor RuleGovernance {
    let repository: any FileRepository
    let access: AuthorizedRootAccessService
    let coordinator: RuleCoordinator
    private let policy: LocalAccessPolicy?
    init(repository: any FileRepository, access: AuthorizedRootAccessService, coordinator: RuleCoordinator, policy: LocalAccessPolicy? = nil) {
        self.policy = policy
        self.repository = repository; self.access = access; self.coordinator = coordinator
    }
    func summary(_ plan: RulePlan) async throws -> RulePlanSummary {
        let rule = try await saved(plan.ruleID)
        let source = try await repository.root(withID: rule.rootID!)?.displayName ?? ""
        var destinations: [String] = []
        for id in Set(rule.actions.compactMap(\.destinationRootID)) {
            if let root = try await repository.root(withID: id) { destinations.append(root.displayName) }
        }
        return RulePlanSummary(id: plan.id, ruleID: rule.id, name: rule.name, kind: plan.kind, revision: plan.revision,
            fingerprint: plan.fingerprint, expiresAt: plan.expiresAt, fileCount: plan.files.count,
            byteSize: try RulePolicy.quotas(plan.files, rule: rule), maximumFiles: rule.maximumFiles ?? 1000,
            maximumBytes: rule.maximumBytes ?? 1_073_741_824, sourceRootID: rule.rootID!, destinationRootIDs: Array(Set(rule.actions.compactMap(\.destinationRootID))), source: source, destinations: destinations.sorted(),
            actions: rule.actions.map { $0.kind.title }, files: plan.files.prefix(100).map(\.relativePath), approved: plan.approvedAt != nil)
    }
    func validate(_ rule: AutomationRule) async throws {
        guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rule.name.count <= 200,
              (1...32).contains(rule.actions.count), Set(rule.actions.map(\.id)).count == rule.actions.count,
              rule.days > 0, rule.threshold >= 0, rule.intervalSeconds >= 30,
              rule.conditions.name.count <= 120, rule.conditions.excludedNames.count <= 100, rule.conditions.excludedPaths.count <= 100,
              rule.conditions.excludedNames.allSatisfy({ $0.count <= 120 }),
              rule.conditions.excludedPaths.allSatisfy({ Self.validPath($0) }),
              rule.conditions.minimumBytes.map({ $0 >= 0 }) ?? true,
              rule.conditions.maximumBytes.map({ $0 >= (rule.conditions.minimumBytes ?? 0) }) ?? true else { throw RulePolicyError.invalid }
        if let zone = rule.scheduleTimeZone, TimeZone(identifier: zone) == nil { throw RulePolicyError.invalid }
        _ = try RulePolicy.quotas([], rule: rule)
        try await granted(rule.rootID)
        if [.tagAdded, .tagRemoved, .textContains, .imageText, .documentType].contains(rule.event), rule.eventValue.isEmpty { throw RulePolicyError.invalid }
        for action in rule.actions {
            if [.copy, .archive].contains(action.kind) { try await granted(action.destinationRootID) }
            if [.addTag, .removeTag].contains(action.kind), action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action.value.contains("\0") || action.value.contains("\n") || action.value.count > 200 { throw RulePolicyError.invalid }
            if action.kind == .createDirectories {
                let paths = action.value.split(separator: "\n", omittingEmptySubsequences: false)
                guard !paths.isEmpty, paths.count <= 100, paths.allSatisfy({ Self.validPath(String($0)) }) else { throw RulePolicyError.invalid }
            }
            if action.kind != .runRule, action.nextRuleID != nil { throw RulePolicyError.invalid }
            if action.kind == .runRule, action.nextRuleID == nil { throw RulePolicyError.invalid }
        }
        var rules = try await repository.ruleObjects(AutomationRule.self, table: .rules).filter { $0.id != rule.id }; rules.append(rule)
        let known = Set(rules.map(\.id)); var graph: [UUID: [UUID]] = [:]
        for entry in rules {
            for next in entry.actions.filter({ $0.kind == .runRule }).compactMap(\.nextRuleID) {
                graph[entry.id, default: []].append(next)
            }
            if [.ruleSucceeded, .ruleFailed].contains(entry.event) {
                guard let source = entry.sourceRuleID else { if entry.id == rule.id { throw RulePolicyError.invalid }; continue }
                graph[source, default: []].append(entry.id)
            }
        }
        var depths: [UUID: Int] = [:]
        func visit(_ id: UUID, path: Set<UUID>) throws -> Int {
            guard known.contains(id), !path.contains(id), path.count < 8 else { throw RulePolicyError.invalid }
            if let depth = depths[id] { return depth }
            var depth = 1
            for next in graph[id] ?? [] { depth = max(depth, 1 + (try visit(next, path: path.union([id])))) }
            guard depth <= 8 else { throw RulePolicyError.invalid }
            depths[id] = depth; return depth
        }
        _ = try visit(rule.id, path: [])
    }
    /// Консервативная защита от неявных tag-event циклов. Фоновое разрешение
    /// не допускает противоположные действия над одним тегом в пересекающихся
    /// папках. Одноразовый ручной план остаётся доступным.
    func automaticTagsAllowed(_ rule: AutomationRule) async throws {
        let ownTags = rule.actions.filter { [.addTag, .removeTag].contains($0.kind) }
        guard !ownTags.isEmpty else { return }
        let others = try await repository.ruleObjects(AutomationRule.self, table: .rules).filter { $0.enabled && $0.id != rule.id } + [rule]
        var paths: [UUID: String] = [:]
        func path(_ id: UUID?) async throws -> String {
            guard let id, let root = try await repository.root(withID: id) else { throw RulePolicyError.permission }
            if let cached = paths[id] { return cached }
            let value = try await access.resolveURL(for: root).path.lowercased()
            paths[id] = value; return value
        }
        for action in ownTags {
            for other in others where other.actions.contains(where: { [.addTag, .removeTag].contains($0.kind) && $0.kind != action.kind && $0.value == action.value }) {
                let ownPath = try await path(rule.rootID), otherPath = try await path(other.rootID)
                if ownPath == otherPath || ownPath.hasPrefix(otherPath + "/") || otherPath.hasPrefix(ownPath + "/") { throw RulePolicyError.invalid }
            }
        }
    }

    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 1024 && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    func granted(_ id: UUID?) async throws {
        guard let id, try await repository.root(withID: id) != nil, try await repository.bookmarkData(forRootID: id)?.isEmpty == false else { throw RulePolicyError.permission }
    }
    func saved(_ id: UUID) async throws -> AutomationRule {
        guard let value = try await repository.ruleObject(AutomationRule.self, id: id.uuidString, table: .rules) else { throw RulePolicyError.invalid }
        try await granted(value.rootID)
        for action in value.actions where [.copy, .archive].contains(action.kind) { try await granted(action.destinationRootID) }
        return value
    }
    func save(_ rule: AutomationRule, fromMCP: Bool) async throws -> AutomationRule {
        var value = rule
        // Новый или изменённый проект никогда не наследует действующее право.
        if fromMCP { value.id = UUID(); value.enabled = false; value.allowContentReading = false }
        try await validate(value)
        let previous = try await repository.ruleObject(AutomationRule.self, id: value.id.uuidString, table: .rules)
        let permission = try await repository.ruleObject(RulePermission.self, id: value.id.uuidString, table: .permissions)
        let revision = try RulePolicy.revision(value)
        if let previous, try RulePolicy.revision(previous) != revision {
            // Возврат A → B → A не восстанавливает старые планы/approval.
            for var plan in try await repository.ruleObjects(RulePlan.self, table: .plans) where plan.ruleID == value.id && plan.consumedAt == nil {
                plan.consumedAt = Date(); try await repository.saveRuleObject(plan, id: plan.id.uuidString, table: .plans)
            }
            try await repository.saveRuleObject(RulePermission(revision: "revoked", approvedAt: Date()), id: value.id.uuidString, table: .permissions)
        }
        value.enabled = !fromMCP && value.enabled && previous?.enabled == true && permission?.revision == revision
        try await repository.saveRuleObject(value, id: value.id.uuidString, table: .rules)
        return value
    }
    func prepare(_ id: UUID, kind: String, accessTicket: LocalAccessTicket? = nil, context: QueueExecutionContext? = nil) async throws -> RulePlan {
        let rule = try await saved(id); try await validate(rule)
        guard !RulePolicy.requiresGUI(rule) else { throw RulePolicyError.guiRequired }
        if [.textContains, .imageText, .documentType].contains(rule.event), !rule.allowContentReading { throw RuleExecutionError.contentConsentRequired }
        // Цепочки выполняются только между уже отдельно включёнными правилами.
        if kind == "enable" { try await automaticTagsAllowed(rule) }
        let files = kind == "run" ? try await coordinator.preview(rule, context: context) : []
        _ = try RulePolicy.quotas(files, rule: rule)
        var plan = RulePlan(id: UUID(), ruleID: id, revision: try RulePolicy.revision(rule), kind: kind,
            createdAt: Date(), expiresAt: Date().addingTimeInterval(300), files: files)
        plan.accessTicket = accessTicket
        try await repository.saveRuleObject(plan, id: plan.id.uuidString, table: .plans)
        return plan
    }
    func checkedPlan(_ id: UUID, fingerprint: String? = nil) async throws -> RulePlan {
        guard let plan = try await repository.ruleObject(RulePlan.self, id: id.uuidString, table: .plans),
              plan.expiresAt > Date(), fingerprint.map({ $0 == plan.fingerprint }) ?? true else { throw RulePolicyError.stale }
        let rule = try await saved(plan.ruleID)
        guard try RulePolicy.revision(rule) == plan.revision else { throw RulePolicyError.stale }
        if let ticket = plan.accessTicket, let policy { _ = try await policy.check(ticket) }
        return plan
    }
    func approve(_ id: UUID, fingerprint: String, role: LocalRole) async throws -> RulePlan {
        guard role == .gui else { throw RulePolicyError.permission }
        var plan = try await checkedPlan(id, fingerprint: fingerprint)
        guard plan.consumedAt == nil, plan.expiresAt > Date() else { throw RulePolicyError.stale }
        let rule = try await saved(plan.ruleID); try await validate(rule)
        if plan.kind == "run" { try await coordinator.verifyPlanVersions(rule, files: plan.files) }
        plan.approvedAt = Date()
        // Между созданием двух планов другой автоматизм мог получить разрешение.
        // Повторная проверка при подтверждении закрывает это окно гонки.
        if plan.kind == "enable" {
            let enabledRules = try await repository.ruleObjects(AutomationRule.self, table: .rules).filter { $0.enabled && $0.id != rule.id }
            guard enabledRules.count < 32 else { throw RulePolicyError.quota }
            try await automaticTagsAllowed(rule)
            let permission = RulePermission(revision: plan.revision, approvedAt: Date())
            try await repository.saveRuleObject(permission, id: rule.id.uuidString, table: .permissions)
            var enabled = rule; enabled.enabled = true
            try await repository.saveRuleObject(enabled, id: rule.id.uuidString, table: .rules)
            plan.consumedAt = Date()
        }
        try await repository.saveRuleObject(plan, id: id.uuidString, table: .plans)
        return plan
    }
    func execution(_ id: UUID, planID: UUID?) async throws -> (AutomationRule, RulePlan?) {
        let rule = try await saved(id); try await validate(rule)
        guard !RulePolicy.requiresGUI(rule) else { throw RulePolicyError.guiRequired }
        if [.textContains, .imageText, .documentType].contains(rule.event), !rule.allowContentReading { throw RuleExecutionError.contentConsentRequired }
        try await checkChain(rule, path: [])
        if let planID {
            let plan = try await checkedPlan(planID)
            guard plan.ruleID == id, plan.kind == "run", plan.approvedAt != nil else { throw RulePolicyError.permission }
            return (rule, plan)
        }
        try await authorized(rule)
        return (rule, nil)
    }
    func authorized(_ rule: AutomationRule) async throws {
        guard rule.enabled, !RulePolicy.requiresGUI(rule),
              let permission = try await repository.ruleObject(RulePermission.self, id: rule.id.uuidString, table: .permissions),
              permission.revision == (try RulePolicy.revision(rule)) else { throw RulePolicyError.permission }
        try await validate(rule)
        try await automaticTagsAllowed(rule)
    }
    private func checkChain(_ rule: AutomationRule, path: Set<UUID>) async throws {
        guard !path.contains(rule.id), path.count < 8 else { throw RulePolicyError.invalid }
        let explicit = Set(rule.actions.filter { $0.kind == .runRule }.compactMap(\.nextRuleID))
        let all = try await repository.ruleObjects(AutomationRule.self, table: .rules)
        for child in all where explicit.contains(child.id) || (child.enabled && child.sourceRuleID == rule.id && [.ruleSucceeded, .ruleFailed].contains(child.event)) {
            try await authorized(child)
            try await checkChain(child, path: path.union([rule.id]))
        }
    }
    func consume(_ plan: RulePlan) async throws {
        guard plan.consumedAt == nil, plan.expiresAt > Date() else { throw RulePolicyError.stale }
        var consumed = plan; consumed.consumedAt = Date()
        // Сначала расходуем одноразовое право. При crash оно не запускается заново;
        // receipt/queue recovery определит фактический исход начавшихся действий.
        try await repository.saveRuleObject(consumed, id: consumed.id.uuidString, table: .plans)
    }
    func disable(_ id: UUID) async throws {
        var value = try await saved(id); value.enabled = false
        try await repository.saveRuleObject(value, id: id.uuidString, table: .rules)
        try await repository.saveRuleObject(RulePermission(revision: "revoked", approvedAt: Date()), id: id.uuidString, table: .permissions)
        for var plan in try await repository.ruleObjects(RulePlan.self, table: .plans) where plan.ruleID == id && plan.consumedAt == nil {
            plan.consumedAt = Date(); try await repository.saveRuleObject(plan, id: plan.id.uuidString, table: .plans)
        }
    }
    func plans() async throws -> [RulePlan] {
        try await repository.ruleObjects(RulePlan.self, table: .plans).filter { $0.expiresAt > Date() && $0.consumedAt == nil }.prefix(100).map { $0 }
    }
}
