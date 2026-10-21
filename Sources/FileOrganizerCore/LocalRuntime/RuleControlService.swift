import Foundation
import EcosystemLocalIPC

/// Серверный API не выдаёт private receipt summaries/bookmarks. Результаты
/// history ограничены страницей, ошибки действий не экспортируют raw NSError.
struct RuleControlService {
    let work: AresQueuedWork
    let repository: any FileRepository
    var inbox: LocalEventInbox? = nil
    func handle(role: LocalRole, clientID: LocalMCPClient? = nil, accessTicket: LocalAccessTicket? = nil, request: LocalRPCRequest) async throws -> Data {
        guard role != .worker else { throw LocalRuntimeFailure.denied }
        let keys: Set<String>
        switch request.operation {
        case "rule.list": keys = ["offset"]
        case "rule.history": keys = ["ruleID", "runID", "offset", "cursor"]
        case "rule.get", "rule.preview", "rule.request_enable", "rule.disable": keys = ["ruleID"]
        case "rule.validate", "rule.propose": keys = ["rule"]
        case "rule.run": keys = ["ruleID", "planID", "key", "eventID", "processingToken"]
        case "rule.plan_files": keys = ["planID", "offset"]
        case "rule.pending": keys = []
        case "rule.approve": keys = ["planID", "fingerprint"]
        default: throw LocalRuntimeFailure.denied
        }
        let value = try LocalWire.decode(RuleControlRequest.self, request.payload, keys: keys)
        func scoped(_ rule: AutomationRule) async throws {
            if role == .mcp, let policy = work.policy {
                guard let ticket = accessTicket else { throw LocalRuntimeFailure.denied }
                let roots = rule.rootID.map { [$0] } ?? []
                for root in roots + rule.actions.compactMap(\.destinationRootID) { _ = try await policy.check(ticket, root: root) }
            }
        }
        if let rule = value.rule { try Self.strictRule(request.payload, rule: rule) }
        if let rule = value.rule { try await scoped(rule) }
        if let id = value.ruleID { try await scoped(work.governance.saved(id)) }

        switch request.operation {
        case "rule.validate":
            guard let rule = value.rule else { throw LocalRuntimeFailure.invalidRequest }
            try await work.governance.validate(rule)
            return try JSONSerialization.data(withJSONObject: ["valid": true, "revision": RulePolicy.revision(rule), "requiresGUI": RulePolicy.requiresGUI(rule)])
        case "rule.propose":
            guard let rule = value.rule else { throw LocalRuntimeFailure.invalidRequest }
            let saved = try await work.governance.save(rule, fromMCP: role == .mcp)
            return try LocalWire.encode(saved)
        case "rule.preview":
            guard let id = value.ruleID else { throw LocalRuntimeFailure.invalidRequest }
            let task = try await work.submit(AresSubmission(capability: "rule.preview", job: AresJob(ruleID: id), key: UUID().uuidString), role: role, clientID: clientID, acceptedTicket: accessTicket)
            return try LocalWire.encode(LocalTaskID(task.id))
        case "rule.request_enable":
            guard let id = value.ruleID else { throw LocalRuntimeFailure.invalidRequest }
            let plan = try await work.governance.prepare(id, kind: "enable", accessTicket: accessTicket)
            return try LocalWire.encode(try await work.governance.summary(plan))
        case "rule.approve":
            guard role == .gui, let id = value.planID, let fingerprint = value.fingerprint else { throw LocalRuntimeFailure.denied }
            let plan = try await work.governance.approve(id, fingerprint: fingerprint, role: role)
            return try LocalWire.encode(try await work.governance.summary(plan))
        case "rule.plan_files":
            guard role == .gui, let id = value.planID else { throw LocalRuntimeFailure.denied }
            let plan = try await work.governance.checkedPlan(id)
            let offset = value.offset ?? 0
            guard (0...plan.files.count).contains(offset) else { throw LocalRuntimeFailure.invalidRequest }
            let files = Array(plan.files.dropFirst(offset).prefix(100).map(\.relativePath))
            return try LocalWire.encode(RulePlanFilesPage(files: files, nextOffset: offset + files.count < plan.files.count ? offset + files.count : nil))
        case "rule.pending":
            guard role == .gui else { throw LocalRuntimeFailure.denied }
            var result: [RulePlanSummary] = []
            for plan in try await work.governance.plans() {
                // Отозванные grants/изменённые правила не восстанавливаются UI.
                if let checked = try? await work.governance.checkedPlan(plan.id), let row = try? await work.governance.summary(checked) { result.append(row) }
            }
            return try LocalWire.encode(result)
        case "rule.run":
            guard let id = value.ruleID, (value.eventID == nil) == (value.processingToken == nil) else { throw LocalRuntimeFailure.invalidRequest }
            let rule = try await work.governance.saved(id)
            let key: String
            if let eventID = value.eventID, let token = value.processingToken {
                guard role == .mcp, value.key == nil, let inbox, let policy = work.policy,
                      let accessTicket, let event = await inbox.event(id: eventID), event.expiresAt > Date()
                else { throw LocalRuntimeFailure.denied }
                // Право читать событие и право запускать правило независимы.
                // Проверяются capability события, его корни и сохранённые bookmarks.
                let eventTicket = try await policy.authorize(client: clientID ?? .legacy, capability: "events.read", roots: event.rootIDs)
                let grant = try await policy.check(eventTicket)
                guard grant.id == accessTicket.grantID, grant.draft.capabilities.contains(event.capability) else { throw LocalRuntimeFailure.denied }
                for root in event.rootIDs {
                    guard try await repository.root(withID: root) != nil,
                          try await repository.bookmarkData(forRootID: root)?.isEmpty == false else { throw LocalRuntimeFailure.denied }
                }
                key = "event.rule." + RulePolicy.digest(Data((eventID.uuidString + ":" + id.uuidString + ":" + (try RulePolicy.revision(rule)) + ":rule.run").utf8))
                // Резерв не отдаёт чужой taskId даже после lease expiry/regrant.
                do {
                    try await inbox.reserveProcessingEffect(id: eventID, client: clientID ?? .legacy,
                        token: token, authorizationID: grant.id, key: key)
                } catch LocalRuntimeFailure.conflict {
                    // Владение чужим effect не раскрывается через сведения о задаче.
                    throw LocalRuntimeFailure.denied
                }
                _ = try await policy.check(eventTicket)
                _ = try await policy.check(accessTicket)
            } else {
                guard let supplied = value.key, !supplied.isEmpty, supplied.utf8.count <= 128 else { throw LocalRuntimeFailure.invalidRequest }
                key = supplied
            }
            var job = AresJob(ruleID: id, planID: value.planID, rootID: rule.rootID)
            job.sourceEventID = value.eventID
            var submission = AresSubmission(capability: "rule.run", job: job, key: key)
            if let planID = value.planID, let plan = try await repository.ruleObject(RulePlan.self, id: planID.uuidString, table: .plans) {
                let formatter = ISO8601DateFormatter(); submission.deadlineAt = formatter.string(from: plan.expiresAt)
            }
            let task = try await work.submit(submission, role: role, clientID: clientID, acceptedTicket: accessTicket)
            return try LocalWire.encode(LocalTaskID(task.id))
        case "rule.disable":
            guard let id = value.ruleID else { throw LocalRuntimeFailure.invalidRequest }
            try await work.governance.disable(id)
            let requested = try await work.cancelRule(id)
            return try JSONSerialization.data(withJSONObject: ["enabled": false, "currentTaskCancellationRequested": requested, "completedEffectsRolledBack": false])
        case "rule.get":
            guard let id = value.ruleID else { throw LocalRuntimeFailure.invalidRequest }
            let rule = try await work.governance.saved(id)
            let encoded = try LocalWire.encode(rule)
            return try JSONSerialization.data(withJSONObject: ["rule": JSONSerialization.jsonObject(with: encoded), "revision": RulePolicy.revision(rule), "requiresGUI": RulePolicy.requiresGUI(rule)])
        case "rule.list":
            let offset = value.offset ?? 0; guard (0...100_000).contains(offset), value.ruleID == nil else { throw LocalRuntimeFailure.invalidRequest }
            var rows: [AutomationRule] = []
            for rule in try await repository.ruleObjects(AutomationRule.self, table: .rules) {
                if (try? await work.governance.saved(rule.id)) != nil, (try? await scoped(rule)) != nil { rows.append(rule) }
            }
            let page = rows.sorted { $0.id.uuidString < $1.id.uuidString }.dropFirst(offset).prefix(100)
            return try JSONSerialization.data(withJSONObject: ["rules": try page.map { ["id": $0.id.uuidString, "name": $0.name, "enabled": $0.enabled, "revision": try RulePolicy.revision($0), "requiresGUI": RulePolicy.requiresGUI($0)] }, "nextOffset": offset + page.count < rows.count ? (offset + page.count) as Any : NSNull()])
        case "rule.history":
            guard let id = value.ruleID else { throw LocalRuntimeFailure.invalidRequest }
            _ = try await work.governance.saved(id)
            let offset = value.offset ?? 0; guard (0...100_000).contains(offset) else { throw LocalRuntimeFailure.invalidRequest }
            let history: RuleHistoryPage
            do { history = try await repository.ruleHistoryPage(ruleID: id, runID: value.runID, offset: offset, cursor: value.cursor) }
            catch RuleHistoryFailure.invalidRequest { throw LocalRuntimeFailure.invalidRequest }
            catch RuleHistoryFailure.missingRun { throw LocalRuntimeFailure.denied }
            // Повторная проверка после await не позволяет отзыву grant/root
            // между выборкой и выдачей страницы раскрыть кэшированный результат.
            let checkedRule = try await work.governance.saved(id)
            try await scoped(checkedRule)
            if let runID = value.runID {
                var safeReceipts: [[String: String]] = []
                if let taskID = history.runTaskID {
                    safeReceipts = try await work.queue.receipts(taskID, limit: 100, offset: Int64(offset)).map {
                        ["id": $0.id.uuidString, "state": $0.state.rawValue, "actionKey": $0.actionKey]
                    }
                }
                let results = history.items.compactMap { row -> [String: String]? in
                    guard let kind = row.kind else { return nil }
                    return ["kind": kind.rawValue, "relativePath": row.relativePath, "status": row.status]
                }
                let finalRule = try await work.governance.saved(id)
                try await scoped(finalRule)
                let nextOffset = history.nextOffset ?? (safeReceipts.count == 100 ? offset + 100 : nil)
                return try JSONSerialization.data(withJSONObject: ["runId": runID.uuidString, "results": results,
                    "receipts": safeReceipts, "nextOffset": nextOffset as Any? ?? NSNull()])
            }
            var items: [[String: Any]] = []
            let formatter = ISO8601DateFormatter()
            for row in history.items {
                var status = row.runStatus
                if status == "running", let taskID = row.taskID, let task = try await work.queue.task(taskID), task.status.isTerminal { status = task.status.rawValue }
                var item: [String: Any] = ["runId": row.runID.uuidString, "taskId": row.taskID?.uuidString as Any? ?? NSNull(),
                    "runStatus": status, "createdAt": formatter.string(from: row.createdAt),
                    "kind": row.kind?.rawValue as Any? ?? NSNull(), "relativePath": row.relativePath, "status": row.kind == nil ? status : row.status]
                if let action = row.actionID { item["actionId"] = action.uuidString }
                items.append(item)
            }
            let finalRule = try await work.governance.saved(id)
            try await scoped(finalRule)
            return try JSONSerialization.data(withJSONObject: ["items": items,
                "nextOffset": history.nextOffset as Any? ?? NSNull(), "nextCursor": history.nextCursor as Any? ?? NSNull()])
        default: throw LocalRuntimeFailure.denied
        }
    }
    private static func strictRule(_ data: Data, rule: AutomationRule) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["rule"] as? [String: Any] else { throw LocalRuntimeFailure.invalidRequest }
        let allowed: Set<String> = ["id", "name", "rootID", "enabled", "maximumFiles", "maximumBytes", "includeSubfolders", "processExisting", "allowContentReading", "event", "eventValue", "threshold", "days", "schedule", "scheduleDate", "scheduleTimeZone", "intervalSeconds", "catchUpOnce", "sourceRuleID", "conditions", "actions"]
        let conditionKeys: Set<String> = ["extensions", "name", "nameMatch", "minimumBytes", "maximumBytes", "requiredTag", "absentTag", "excludedPaths", "excludedNames", "modifiedAfter", "createdAfter", "firstSeenAfter", "allConditions"]
        guard Set(value.keys).isSubset(of: allowed), let conditions = value["conditions"] as? [String: Any], Set(conditions.keys).isSubset(of: conditionKeys), let actions = value["actions"] as? [[String: Any]], actions.allSatisfy({ Set($0.keys).isSubset(of: ["id", "kind", "value", "destinationRootID", "nextRuleID", "archiveTogether"]) }) else { throw LocalRuntimeFailure.invalidRequest }
    }
}
