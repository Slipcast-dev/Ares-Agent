import Darwin
import Foundation
import EcosystemLocalIPC

/// Серверная граница локального режима. Все CRUD выполняет единственный owner;
/// admission и изменение grant/config дополнительно защищены от actor reentrancy.
public actor AresRuntimeService {
    private let container: AppContainer
    private let work: AresQueuedWork
    public let automation: LocalAutomationService?
    private let login: LocalLoginRegistration?
    private let history: LocalMCPHistory?
    private let instanceID = UUID()
    private var changing = false
    private var admitting = 0
    public init(container: AppContainer, work: AresQueuedWork, automation: LocalAutomationService? = nil, login: LocalLoginRegistration? = nil, history: LocalMCPHistory? = nil) { self.container = container; self.work = work; self.automation = automation; self.login = login; self.history = history }
    private func management<T>(_ operation: () async throws -> T) async throws -> T {
        guard !changing, admitting == 0 else { throw LocalRuntimeFailure.busy }
        changing = true; defer { changing = false }
        guard try await !work.queue.hasReservation("ares.domain") else { throw LocalRuntimeFailure.busy }
        return try await operation()
    }
    public func pollInternal(appLaunch: Bool) async {
        guard !(await automation?.paused() ?? false), !changing, let rules = try? await container.fileRepository.ruleObjects(AutomationRule.self, table: .rules), rules.contains(where: { $0.enabled }) else { return }
        admitting += 1; defer { admitting -= 1 }
        _ = try? await work.submit(AresSubmission(capability: "rule.poll", job: AresJob(appLaunch: appLaunch), key: UUID().uuidString), role: .worker)
    }
    private var watcher: LocalDirectoryWatcher?
    private var watchedPaths: [String] = []
    private var dirtyAt: Date?
    private var settleAt: Date?
    private var lastTick: Date = .distantPast
    private var ticking = false
    public func wake() async { lastTick = .distantPast; await tick() }
    private func filesChanged() { dirtyAt = Date() }
    public func tick(appLaunch: Bool = false) async {
        guard !ticking else { return }; ticking = true; defer { ticking = false }
        let now = Date()
        if appLaunch || now.timeIntervalSince(lastTick) >= 30 {
            var urls: [URL] = []
            if let rules = try? await container.fileRepository.ruleObjects(AutomationRule.self, table: .rules) {
                for id in Set(rules.filter(\.enabled).compactMap(\.rootID)).prefix(128) {
                    if let root = try? await container.fileRepository.root(withID: id), let url = try? await container.authorizedRootAccess.resolveURL(for: root) { urls.append(url) }
                }
            }
            let paths = urls.map(\.path).sorted()
            if paths != watchedPaths {
                if watcher == nil { watcher = LocalDirectoryWatcher { [weak self] in Task { await self?.filesChanged() } } }
                watcher?.replace(urls); watchedPaths = paths
            }
            lastTick = now; dirtyAt = nil
            await pollInternal(appLaunch: appLaunch)
            settleAt = now.addingTimeInterval(3)
        } else if let dirtyAt, now.timeIntervalSince(dirtyAt) >= 5 {
            self.dirtyAt = nil
            await pollInternal(appLaunch: false)
            settleAt = now.addingTimeInterval(3)
        } else if let settleAt, now >= settleAt {
            self.settleAt = nil
            await pollInternal(appLaunch: false)
        }
        guard let automation else { return }
        do {
            let runs = try await container.fileRepository.ruleObjects(RuleRun.self, table: .runs).sorted { $0.createdAt > $1.createdAt }.prefix(100)
            for run in runs where run.status != "running" {
                guard let rule = try await container.fileRepository.ruleObject(AutomationRule.self, id: run.ruleID.uuidString, table: .rules) else { continue }
                let failed = !["completed", "skipped"].contains(run.status)
                // Повтор недоступного диска объединяется в одно событие за 15мин.
                let id = failed ? LocalStableEventID.make("rule-failure:" + run.ruleID.uuidString + ":" + String(Int(run.createdAt.timeIntervalSince1970 / 900))) : run.id
                try await automation.record(id: id, kind: failed ? "rule.failure" : "rule.completed", capability: "rule.history", roots: rule.rootID.map { [$0] } ?? [], capturedAt: run.createdAt, significant: failed)
            }
            for task in try await work.queue.tasks(limit: 100) where task.status == .recoveryRequired {
                try await automation.record(id: task.id, kind: "task.recovery", capability: "file.get_audit_report", capturedAt: task.finishedAt ?? task.createdAt, significant: true)
            }
        } catch { /* Доменный журнал сохранён; следующий tick повторит доставку. */ }
        await automation.flushNotifications()
    }
    public func stopObservation() { watcher?.stop(); watcher = nil }
    public func handle(role: LocalRole, clientID: LocalMCPClient? = nil, request: LocalRPCRequest) async throws -> Data {
        if request.operation.hasPrefix("mcp.") {
            guard role == .mcp, let history else { throw LocalRuntimeFailure.denied }
            return try await history.handle(operation: request.operation, payload: request.payload, client: clientID ?? .legacy)
        }
        if request.operation == "automation.login_status" || request.operation == "automation.login_configure" {
            guard role == .gui, let login else { throw LocalRuntimeFailure.denied }
            if request.operation == "automation.login_status" {
                _ = try LocalWire.decode(LocalEmpty.self, request.payload, keys: [])
                return try LocalWire.encode(login.status())
            }
            struct Change: Decodable { let enabled: Bool }
            let value = try LocalWire.decode(Change.self, request.payload, keys: ["enabled"])
            return try LocalWire.encode(login.setEnabled(value.enabled))
        }
        if request.operation.hasPrefix("automation.") || request.operation.hasPrefix("events.") {
            guard let automation else { throw LocalRuntimeFailure.denied }
            var roots = Set<UUID>()
            for root in try await container.fileRepository.fetchRoots() where try await container.fileRepository.bookmarkData(forRootID: root.id)?.isEmpty == false { roots.insert(root.id) }
            return try await LocalAutomationControl.handle(service: automation, policy: work.policy, role: role, client: clientID, validRoots: roots, request: request)
        }
        if request.operation.hasPrefix("access."), let policy = work.policy {
            var roots: [LocalAccessScope.Root] = []
            for root in try await container.fileRepository.fetchRoots() where try await container.fileRepository.bookmarkData(forRootID: root.id)?.isEmpty == false {
                roots.append(LocalAccessScope.Root(id: root.id, name: root.displayName))
            }
            let result = try await LocalAccessControl.handle(policy: policy, scope: LocalAccessScope(roots: roots, capabilities: policy.capabilities), role: role, client: clientID, request: request)
            if request.operation == "access.approve" {
                let grant = try LocalWire.decode(LocalAccessGrant.self, result); try await work.cancelClient(grant.draft.client)
            } else if request.operation == "access.revoke", let value = try JSONSerialization.jsonObject(with: result) as? [String: Any], let text = value["client"] as? String, let client = LocalMCPClient(rawValue: text) { try await work.cancelClient(client) }
            return result
        }
        if role == .mcp, let policy = work.policy, !["runtime.status", "work.submit", "task.get", "task.cancel"].contains(request.operation) {
            let capability: String
            switch request.operation {
            case "repo.roots": capability = "file.list_roots"
            case "repo.events": capability = "file.get_audit_report"
            default:
                guard request.operation.hasPrefix("rule."), !["rule.approve", "rule.pending", "rule.plan_files"].contains(request.operation) else { throw LocalRuntimeFailure.denied }
                capability = request.operation
            }
            let ticket = try await policy.authorize(client: clientID ?? .legacy, capability: capability)
            var result = try await permittedHandle(role: role, clientID: clientID, accessTicket: ticket, request: request)
            if request.operation == "repo.roots" {
                let allowed = try await policy.check(ticket).draft.roots
                let roots = try LocalWire.decode([AuthorizedRoot].self, result).filter { allowed.contains($0.id) }
                result = try LocalWire.encode(roots)
            }
            if request.operation == "repo.events" {
                let events = try LocalWire.decode([AuditEvent].self, result)
                result = try LocalWire.encode(events.map { AuditEvent(id: $0.id, origin: $0.origin, eventType: $0.eventType, createdAt: $0.createdAt, summary: "Локальная операция") })
            }
            return try await policy.export(result, ticket: ticket)
        }
        return try await permittedHandle(role: role, clientID: clientID, accessTicket: nil, request: request)
    }
    private func permittedHandle(role: LocalRole, clientID: LocalMCPClient?, accessTicket: LocalAccessTicket?, request: LocalRPCRequest) async throws -> Data {
        let repository = container.fileRepository
        if request.operation.hasPrefix("recovery.") { return try await work.recovery.handle(role: role, request: request) }
        if request.operation.hasPrefix("rule.") {
            let control = RuleControlService(work: work, repository: repository, inbox: automation?.inbox)
            if ["rule.list", "rule.get", "rule.history", "rule.pending", "rule.plan_files", "rule.validate"].contains(request.operation) {
                return try await control.handle(role: role, clientID: clientID, accessTicket: accessTicket, request: request)
            }
            if ["rule.run", "rule.preview"].contains(request.operation) {
                guard !changing else { throw LocalRuntimeFailure.busy }
                admitting += 1; defer { admitting -= 1 }
                return try await control.handle(role: role, clientID: clientID, accessTicket: accessTicket, request: request)
            }
            if request.operation == "rule.disable" {
                guard !changing, admitting == 0 else { throw LocalRuntimeFailure.busy }
                changing = true; defer { changing = false }
                return try await control.handle(role: role, clientID: clientID, accessTicket: accessTicket, request: request)
            }
            let result = try await management { try await control.handle(role: role, clientID: clientID, accessTicket: accessTicket, request: request) }
            if request.operation == "rule.approve" { lastTick = .distantPast }
            return result
        }
        switch request.operation {
        case "runtime.status":
            _ = try LocalWire.decode(LocalEmpty.self, request.payload, keys: [])
            return try JSONSerialization.data(withJSONObject: ["domain": "ares", "processID": getpid(), "instanceID": instanceID.uuidString, "runtimeIntegrated": true, "healthy": await work.isHealthy()])
        case "work.submit":
            guard !changing else { throw LocalRuntimeFailure.busy }
            let submission = try LocalWire.decode(AresSubmission.self, request.payload, keys: ["capability", "job", "key", "deadlineAt"])
            // Неизвестные вложенные поля не допускаются; trusted роль назначается ниже.
            let object = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            guard let job = object?["job"] as? [String: Any], Set(job.keys).isSubset(of: ["ruleID", "planID", "rootID", "snapshotID", "query", "cursor", "pageSize", "rule", "paths", "appLaunch", "origin", "correlationID"]), submission.job.requesterRole == nil else { throw LocalRuntimeFailure.invalidRequest }
            var normalized = submission
            if submission.capability == "rule.poll" { normalized.job.appLaunch = false }
            admitting += 1; defer { admitting -= 1 }
            let task = try await work.submit(normalized, role: role, clientID: clientID)
            return try LocalWire.encode(LocalTaskID(task.id))
        case "task.get", "task.cancel":
            let value = try LocalWire.decode(LocalTaskID.self, request.payload, keys: ["id"])
            if request.operation == "task.cancel" {
                try await work.cancel(value.id, role: role, clientID: clientID); return try LocalWire.encode(LocalEmpty())
            }
            return try LocalWire.encode(try await work.authorizedTask(value.id, role: role, clientID: clientID))
        case "grant.pending":
            guard role == .gui else { throw LocalRuntimeFailure.denied }
            _ = try LocalWire.decode(LocalEmpty.self, request.payload, keys: [])
            var roots: [AuthorizedRoot] = []
            for root in try await repository.fetchRoots() where try await repository.bookmarkData(forRootID: root.id)?.isEmpty == true { roots.append(root) }
            return try LocalWire.encode(roots)
        case "grant.renew":
            guard role == .gui else { throw LocalRuntimeFailure.denied }
            let transfer = try LocalWire.decode(RootRenewal.self, request.payload, keys: ["id", "bookmark"])
            return try await management {
                var stale = false
                let url = try URL(resolvingBookmarkData: transfer.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, url.startAccessingSecurityScopedResource() else { throw LocalRuntimeFailure.denied }
                defer { url.stopAccessingSecurityScopedResource() }
                return try LocalWire.encode(try await container.authorizedRootAccess.renewRoot(transfer.id, from: url))
            }
        case "grant.add":
            guard role == .gui else { throw LocalRuntimeFailure.denied }
            let transfer = try LocalWire.decode(RootTransfer.self, request.payload, keys: ["bookmark"])
            return try await management {
                var stale = false
                let url = try URL(resolvingBookmarkData: transfer.bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, url.startAccessingSecurityScopedResource() else { throw LocalRuntimeFailure.denied }
                defer { url.stopAccessingSecurityScopedResource() }
                return try LocalWire.encode(try await container.authorizedRootAccess.addRoot(from: url))
            }
        case "grant.resolve":
            guard role == .gui else { throw LocalRuntimeFailure.denied }
            let id = try LocalWire.decode(LocalTaskID.self, request.payload, keys: ["id"]).id
            guard let root = try await repository.root(withID: id) else { throw LocalRuntimeFailure.denied }
            let url = try await container.authorizedRootAccess.resolveURL(for: root)
            guard url.startAccessingSecurityScopedResource() else { throw LocalRuntimeFailure.denied }
            defer { url.stopAccessingSecurityScopedResource() }
            // Возвращаем временный implicit bookmark для явного GUI-действия,
            // не приватный persistent bookmark из доменной БД.
            return try LocalWire.encode(try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        default: break
        }
        guard role != .worker else { throw LocalRuntimeFailure.denied }
        let keys: Set<String>
        switch request.operation {
        case "repo.roots", "repo.profiles": keys = []
        case "repo.root", "repo.removeRoot", "repo.task", "repo.deleteRule": keys = ["id"]
        case "repo.count", "repo.records": keys = ["rootID"]
        case "repo.search": keys = ["rootID", "query", "limit"]
        case "repo.events", "repo.tasks": keys = ["limit"]
        case "repo.ruleObjects": keys = ["table"]
        case "repo.ruleObject": keys = ["table", "objectID"]
        case "repo.saveRule": keys = ["table", "object", "objectID"]
        case "repo.saveProfile": keys = ["profile"]
        default: throw LocalRuntimeFailure.denied
        }
        let payload = try LocalWire.decode(RepositoryPayload.self, request.payload, keys: keys)
        if role == .mcp && !["repo.roots", "repo.root", "repo.count", "repo.records", "repo.search", "repo.events", "repo.task"].contains(request.operation) { throw LocalRuntimeFailure.denied }
        if let root = payload.rootID {
            guard try await repository.root(withID: root) != nil else { throw LocalRuntimeFailure.denied }
            if role == .mcp, try await repository.bookmarkData(forRootID: root)?.isEmpty != false { throw LocalRuntimeFailure.denied }
        }
        if request.operation == "repo.root", role == .mcp, let id = payload.id,
           try await repository.bookmarkData(forRootID: id)?.isEmpty != false { throw LocalRuntimeFailure.denied }
        switch request.operation {
        case "repo.roots":
            var roots: [AuthorizedRoot] = []
            for root in try await repository.fetchRoots() {
                if role == .gui { roots.append(root) }
                else if try await repository.bookmarkData(forRootID: root.id)?.isEmpty == false { roots.append(root) }
            }
            return try LocalWire.encode(roots)
        case "repo.root":
            guard let id = payload.id else { throw LocalRuntimeFailure.invalidRequest }
            return try LocalWire.encode(try await repository.root(withID: id))
        case "repo.count":
            guard let id = payload.rootID else { throw LocalRuntimeFailure.invalidRequest }
            return try LocalWire.encode(try await repository.indexedFileCount(forRootID: id))
        case "repo.records":
            guard let id = payload.rootID else { throw LocalRuntimeFailure.invalidRequest }
            return try LocalWire.encode(try await repository.records(forRootID: id))
        case "repo.search":
            guard let id = payload.rootID, let query = payload.query, query.count <= 120,
                  let limit = payload.limit, (1...100).contains(limit) else { throw LocalRuntimeFailure.invalidRequest }
            return try LocalWire.encode(try await repository.searchRecords(forRootID: id, query: query, limit: limit))
        case "repo.events":
            guard let limit = payload.limit, (1...100).contains(limit) else { throw LocalRuntimeFailure.invalidRequest }
            return try LocalWire.encode(try await repository.recentEvents(limit: limit))
        case "repo.task":
            guard let id = payload.id else { throw LocalRuntimeFailure.invalidRequest }
            let task = try await work.authorizedTask(id, role: role, clientID: clientID)
            return try LocalWire.encode(try await work.agentTask(task))
        case "repo.tasks":
            guard let limit = payload.limit, (1...100).contains(limit) else { throw LocalRuntimeFailure.invalidRequest }
            let tasks = try await work.queue.tasks(limit: limit)
            var result: [AgentTask] = []
            for task in tasks { if let value = try await work.agentTask(task) { result.append(value) } }
            return try LocalWire.encode(result)
        case "repo.profiles": return try LocalWire.encode(try await repository.fetchProviderProfiles())
        case "repo.ruleObjects", "repo.ruleObject":
            guard let table = payload.table, [.rules, .runs].contains(table) else { throw LocalRuntimeFailure.denied }
            if request.operation == "repo.ruleObjects" {
                if table == .rules { return try LocalWire.encode(try await repository.ruleObjects(AutomationRule.self, table: table)) }
                var runs = try await repository.ruleObjects(RuleRun.self, table: table)
                for index in runs.indices where runs[index].status == "running" {
                    if let taskID = runs[index].taskID, let task = try await work.queue.task(taskID), task.status.isTerminal { runs[index].status = task.status.rawValue }
                }
                return try LocalWire.encode(runs)
            }
            guard let id = payload.objectID, UUID(uuidString: id) != nil else { throw LocalRuntimeFailure.invalidRequest }
            if table == .rules { return try LocalWire.encode(try await repository.ruleObject(AutomationRule.self, id: id, table: table)) }
            return try LocalWire.encode(try await repository.ruleObject(RuleRun.self, id: id, table: table))
        case "repo.removeRoot":
            guard let id = payload.id else { throw LocalRuntimeFailure.invalidRequest }
            guard !changing, admitting == 0 else { throw LocalRuntimeFailure.busy }
            changing = true; defer { changing = false }
            // Отзыв не ждёт окончания потенциально зависшего callback. Исполнитель
            // получает отмену, а locks остаются до его реальной остановки/recovery.
            try await work.cancelForRevocation()
            try await repository.removeRoot(withID: id)
        case "repo.deleteRule":
            guard let id = payload.id else { throw LocalRuntimeFailure.invalidRequest }
            try await management { try await repository.deleteRule(id: id) }
        case "repo.saveProfile":
            guard let profile = payload.profile else { throw LocalRuntimeFailure.invalidRequest }
            try await management { try await repository.save(profile: profile) }
        case "repo.saveRule":
            guard payload.table == .rules, let data = payload.object, let id = payload.objectID else { throw LocalRuntimeFailure.invalidRequest }
            let rule = try LocalWire.decode(AutomationRule.self, data)
            guard id == rule.id.uuidString else { throw LocalRuntimeFailure.invalidRequest }
            try await management { _ = try await work.governance.save(rule, fromMCP: false) }
        default: throw LocalRuntimeFailure.denied
        }
        return try LocalWire.encode(LocalEmpty())
    }
}

public struct RootRenewal: Codable, Sendable { public let id: UUID; public let bookmark: Data
    public init(id: UUID, bookmark: Data) { self.id = id; self.bookmark = bookmark }
}
