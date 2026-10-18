import Foundation
import EcosystemContracts
import EcosystemRuntimeSupport
import EcosystemLocalIPC

/// Только runtime создаёт эту композицию. Реестр фиксирован Swift-кодом;
/// входной запрос не может выбрать shell, SQLite-файл или handler.
public actor AresQueuedWork {
    public let queue: DurableTaskQueue
    public let recovery: LocalRecoveryService
    public let policy: LocalAccessPolicy?
    let governance: RuleGovernance
    private let executor: DurableTaskExecutor
    private let repository: any FileRepository
    public init(queue: DurableTaskQueue, repository: any FileRepository,
                access: AuthorizedRootAccessService, rules: RuleCoordinator, policy: LocalAccessPolicy? = nil) throws {
        self.queue = queue; self.repository = repository; self.policy = policy
        let governance = RuleGovernance(repository: repository, access: access, coordinator: rules, policy: policy)
        self.governance = governance
        let indexing = FileIndexingService()
        var operations: [String: RegisteredQueueOperation] = [:]
        operations["file.scan"] = RegisteredQueueOperation(mutating: false) { data, context in
            let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: data).parameters
            guard let id = job.rootID, let root = try await repository.root(withID: id) else { throw LocalRuntimeFailure.denied }
            let url = try await access.resolveURL(for: root)
            guard url.startAccessingSecurityScopedResource() else { throw AuthorizedRootAccessError.accessDenied }
            defer { url.stopAccessingSecurityScopedResource() }
            let result = try await indexing.scan(root: root, rootURL: url) { progress in
                // Progress не раскрывает путь и одновременно проверяет lease.
                try await context.authorizeBudget(objects: progress.indexedFileCount + progress.skippedItemCount, bytes: 0)
                try await context.progress(TaskProgress(phase: "scan", processed: NonnegativeInt(Int64(progress.indexedFileCount))))
            }
            try await context.authorizeBudget(objects: result.records.count + result.summary.skippedItemCount, bytes: 0)
            try await context.checkpoint()
            guard try await repository.root(withID: id) != nil else { throw LocalRuntimeFailure.denied }
            let snapshot = try await repository.publishSnapshot(records: result.records, summary: result.summary)
            return try LocalWire.encode(ScanSummary(rootID: id, indexedFileCount: result.summary.indexedFileCount,
                skippedItemCount: result.summary.skippedItemCount, totalByteSize: result.summary.totalByteSize,
                snapshotID: snapshot.header.id, indexGeneration: snapshot.header.generation))
        }
        let snapshots = FileSnapshotOperations(repository: repository, access: access)
        for capability in ["file.search", "file.analyze_storage", "file.compute_duplicates", "file.find_duplicates"] {
            operations[capability] = RegisteredQueueOperation(mutating: false) { data, context in
                let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: data).parameters
                return try await snapshots.perform(capability: capability, job: job, context: context)
            }
        }
        operations["rule.preview"] = RegisteredQueueOperation(mutating: false) { data, context in
            let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: data).parameters
            guard let id = job.ruleID else { throw LocalRuntimeFailure.invalidRequest }
            let plan = try await governance.prepare(id, kind: "run", accessTicket: job.accessTicket, context: context)
            try await context.checkpoint()
            return try LocalWire.encode(try await governance.summary(plan))
        }
        operations["rule.run"] = RegisteredQueueOperation(mutating: true) { data, context in
            let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: data).parameters
            guard let id = job.ruleID else { throw LocalRuntimeFailure.invalidRequest }
            let (rule, plan) = try await governance.execution(id, planID: job.planID)
            if let plan {
                try await rules.verifyPlan(rule, files: plan.files, context: context)
                try await governance.consume(plan)
            }
            return try LocalWire.encode(try await rules.run(rule, context: context, plannedFiles: plan?.files))
        }
        operations["rule.check"] = RegisteredQueueOperation(mutating: false) { data, context in
            let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: data).parameters
            guard let rule = job.rule else { throw LocalRuntimeFailure.invalidRequest }
            let result = try await rules.check(rule)
            try await context.checkpoint()
            return try LocalWire.encode(result)
        }
        operations["rule.poll"] = RegisteredQueueOperation(mutating: true) { data, context in
            let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: data).parameters
            try await rules.poll(appLaunch: job.appLaunch ?? false, context: context)
            return try LocalWire.encode(LocalEmpty())
        }
        if let policy {
            operations = operations.mapValues { operation in
                RegisteredQueueOperation(mutating: operation.mutating) { data, context in
                    let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: data).parameters
                    guard job.requesterRole == .mcp else { return try await operation.perform(data, context) }
                    guard let ticket = job.accessTicket, ticket.client == job.requesterClientID else { throw LocalRuntimeFailure.denied }
                    let checked = context.withAuthorization { check in
                        switch check {
                        case .checkpoint: _ = try await policy.check(ticket)
                        case .root(let root): _ = try await policy.check(ticket, root: root)
                        case .budget(let objects, let bytes): _ = try await policy.check(ticket, objects: objects, bytes: bytes)
                        }
                    }
                    try await checked.checkpoint()
                    let result = try await operation.perform(data, checked)
                    try await checked.checkpoint(); return result
                }
            }
        }
        executor = try DurableTaskExecutor(queue: queue, operations: operations)
        recovery = LocalRecoveryService(queue: queue, executor: executor) { receipts, decisions in
            // Сверка не должна запустить background poll с прежним enabled rule.
            // Оператор отдельно разрешит следующее выполнение после проверки.
            for var rule in try await repository.ruleObjects(AutomationRule.self, table: .rules) where rule.enabled {
                rule.enabled = false
                try await repository.saveRuleObject(rule, id: rule.id.uuidString, table: .rules)
            }
            for (receipt, decision) in zip(receipts.sorted { $0.id.uuidString < $1.id.uuidString }, decisions.sorted { $0.receiptID.uuidString < $1.receiptID.uuidString }) {
                guard receipt.actionKey.hasPrefix("rule.") else { continue }
                let key = String(receipt.actionKey.dropFirst(5))
                try await repository.saveRuleObject(decision.state == .done ? "done" : "failed", id: key, table: .receipts)
            }
        }
    }
    public func shutdown() async { _ = try? await executor.drain() }
    public func isHealthy() async -> Bool { await executor.isHealthy() }
    public func resume() async throws { await executor.startSupervision(); try await executor.resumeQueuedTasks() }
    func submit(_ submission: AresSubmission, role: LocalRole, clientID: LocalMCPClient? = nil, acceptedTicket: LocalAccessTicket? = nil) async throws -> DurableTask {
        var job = submission.job
        if job.sourceEventID != nil {
            // Поле формирует только RuleControlService после проверки события.
            // work.submit отвергает его на внешней RPC-границе.
            guard submission.capability == "rule.run", role == .mcp,
                  acceptedTicket != nil else { throw LocalRuntimeFailure.denied }
        }
        job.requesterRole = role
        if role == .mcp { job.requesterClientID = clientID ?? .legacy }
        // Origin клиента — только label. Роль в хранимой записи назначает сервер.
        if role == .mcp { job.origin = clientID == .deepseekHarness ? .deepSeekHarness : .codex }
        if role == .worker { job.origin = .localRule }
        let mutating = ["rule.run", "rule.poll"].contains(submission.capability)
        guard ["file.scan", "file.search", "file.analyze_storage", "file.compute_duplicates", "file.find_duplicates", "rule.preview", "rule.run", "rule.check", "rule.poll"].contains(submission.capability) else { throw LocalRuntimeFailure.denied }
        if role == .mcp && !["file.scan", "file.search", "file.analyze_storage", "file.compute_duplicates", "file.find_duplicates", "rule.preview", "rule.run"].contains(submission.capability) { throw LocalRuntimeFailure.denied }
        if role == .worker && submission.capability != "rule.poll" { throw LocalRuntimeFailure.denied }
        if let query = job.query, query.count > 120 || query.contains("\0") { throw LocalRuntimeFailure.invalidRequest }
        if let size = job.pageSize, !(1...100).contains(size) { throw LocalRuntimeFailure.invalidRequest }
        if let cursor = job.cursor, cursor.utf8.count >= 4096 { throw LocalRuntimeFailure.invalidRequest }
        if submission.capability == "file.scan", job.snapshotID != nil || job.query != nil || job.cursor != nil || job.pageSize != nil { throw LocalRuntimeFailure.invalidRequest }
        if submission.capability == "file.compute_duplicates", job.query != nil || job.cursor != nil || job.pageSize != nil { throw LocalRuntimeFailure.invalidRequest }
        if submission.capability != "file.search", job.query != nil { throw LocalRuntimeFailure.invalidRequest }
        if submission.capability.hasPrefix("rule."), job.snapshotID != nil || job.cursor != nil || job.pageSize != nil { throw LocalRuntimeFailure.invalidRequest }
        if submission.capability.hasPrefix("file.") {
            guard let rootID = job.rootID, try await repository.root(withID: rootID) != nil,
                  job.rule == nil, job.paths == nil, job.appLaunch == nil, job.ruleID == nil, job.planID == nil else { throw LocalRuntimeFailure.invalidRequest }
            guard try await repository.bookmarkData(forRootID: rootID)?.isEmpty == false else { throw LocalRuntimeFailure.denied }
        }
        if ["rule.run", "rule.preview"].contains(submission.capability) {
            if submission.capability == "rule.preview", job.planID != nil { throw LocalRuntimeFailure.invalidRequest }
            guard let id = job.ruleID, job.rule == nil, job.paths == nil, job.appLaunch == nil else { throw LocalRuntimeFailure.invalidRequest }
            let rule = try await governance.saved(id)
            job.rootID = rule.rootID
        } else if job.ruleID != nil || job.planID != nil { throw LocalRuntimeFailure.invalidRequest }
        if let rule = job.rule {
            guard let id = rule.rootID, try await repository.root(withID: id) != nil else { throw LocalRuntimeFailure.denied }
            guard try await repository.bookmarkData(forRootID: id)?.isEmpty == false else { throw LocalRuntimeFailure.denied }
            job.rootID = id
        }
        if role == .mcp, let policy {
            var roots = job.rootID.map { [$0] } ?? []
            if let ruleID = job.ruleID {
                let rule = try await governance.saved(ruleID)
                roots += rule.actions.compactMap(\.destinationRootID)
            }
            if let acceptedTicket {
                guard acceptedTicket.client == (clientID ?? .legacy), acceptedTicket.capability == submission.capability else { throw LocalRuntimeFailure.denied }
                _ = try await policy.check(acceptedTicket)
                for root in roots { _ = try await policy.check(acceptedTicket, root: root) }
                job.accessTicket = acceptedTicket
            } else { job.accessTicket = try await policy.authorize(client: clientID ?? .legacy, capability: submission.capability, roots: roots) }
            if submission.capability == "rule.run", let id = job.planID {
                guard let plan = try await repository.ruleObject(RulePlan.self, id: id.uuidString, table: .plans),
                      plan.accessTicket?.client == job.requesterClientID, plan.accessTicket?.grantID == job.accessTicket?.grantID else { throw LocalRuntimeFailure.denied }
            }
        }
        let formatter = ISO8601DateFormatter()
        var deadline = submission.deadlineAt
        if submission.capability == "rule.run", let id = job.planID {
            guard let plan = try await repository.ruleObject(RulePlan.self, id: id.uuidString, table: .plans), plan.ruleID == job.ruleID else { throw RulePolicyError.permission }
            let expiry = formatter.string(from: plan.expiresAt)
            if let requested = deadline {
                _ = try UTCTimestamp(requested)
                let parser = ISO8601DateFormatter()
                if requested.contains(".") { parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
                guard let date = parser.date(from: requested) else { throw LocalRuntimeFailure.invalidRequest }
                deadline = date < plan.expiresAt ? requested : expiry
            } else { deadline = expiry }
        }
        if let ticket = job.accessTicket, let policy {
            let expiry = formatter.string(from: try await policy.check(ticket).expiresAt)
            if let current = deadline {
                if try UTCTimestamp(current) > UTCTimestamp(expiry) { deadline = expiry }
            } else { deadline = expiry }
        }
        let request = try TaskRequest(requestID: UUID(), agentID: .ares, capabilityID: submission.capability,
            parameters: job, origin: .user, idempotencyKey: submission.key, rootID: job.rootID,
            createdAt: UTCTimestamp(formatter.string(from: Date())), deadlineAt: try deadline.map { try UTCTimestamp($0) })
        // Единый доменный ресурс консервативно сериализует scan/hash/rule, включая
        // назначения и цепочки. Расширение независимой параллельности — отдельно.
        return try await executor.submit(QueueSubmission(request: request, resources: ["ares.domain"], mutating: mutating))
    }
    public func authorizedTask(_ id: UUID, role: LocalRole, clientID: LocalMCPClient? = nil, includeResult: Bool = true) async throws -> DurableTask {
        guard var value = try await queue.task(id, includeResult: includeResult) else { throw LocalRuntimeFailure.invalidRequest }
        let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: value.request).parameters
        guard role == .gui || job.requesterRole == role else { throw LocalRuntimeFailure.denied }
        if role == .mcp {
            guard (job.requesterClientID ?? .legacy) == (clientID ?? .legacy) else { throw LocalRuntimeFailure.denied }
            if let policy {
                guard let ticket = job.accessTicket else { throw LocalRuntimeFailure.denied }; _ = try await policy.check(ticket)
                if let result = value.result { value.result = try await policy.export(result, ticket: ticket) }
                value = value.forExternalClient()
            }
        }
        if role != .gui, let root = job.rootID, try await repository.bookmarkData(forRootID: root)?.isEmpty != false { throw LocalRuntimeFailure.denied }
        if role != .gui, let ruleID = job.ruleID {
            let rule = try await governance.saved(ruleID)
            if role == .mcp, let policy, let ticket = job.accessTicket {
                for root in ([rule.rootID].compactMap { $0 } + rule.actions.compactMap(\.destinationRootID)) { _ = try await policy.check(ticket, root: root) }
            }
        }
        if role == .mcp, let policy, let ticket = job.accessTicket {
            var roots = job.rootID.map { [$0] } ?? []
            if let rule = job.rule { roots += [rule.rootID].compactMap { $0 } + rule.actions.compactMap(\.destinationRootID) }
            for root in roots {
                guard try await repository.bookmarkData(forRootID: root)?.isEmpty == false else { throw LocalRuntimeFailure.denied }
                _ = try await policy.check(ticket, root: root)
            }
            // Последний actor hop повторно проверяет ticket после OS-проверок.
            _ = try await policy.check(ticket)
        }
        return value
    }
    public func cancelClient(_ client: LocalMCPClient) async throws {
        for task in try await queue.executingTasks() {
            let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: task.request).parameters
            if job.requesterRole == .mcp && (job.requesterClientID ?? .legacy) == client { try await executor.cancel(task.id) }
        }
    }
    func cancelRule(_ id: UUID) async throws -> Bool {
        guard let task = try await queue.taskReserving("ares.domain"), !task.status.isTerminal else { return false }
        let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: task.request).parameters
        guard task.capabilityID == "rule.poll" || job.ruleID == id else { return false }
        try await executor.cancel(task.id); return true
    }
    func cancelForRevocation() async throws {
        if let value = try await queue.taskReserving("ares.domain"), !value.status.isTerminal {
            try await executor.cancel(value.id)
        }
    }
    func cancel(_ id: UUID, role: LocalRole, clientID: LocalMCPClient? = nil) async throws { _ = try await authorizedTask(id, role: role, clientID: clientID); try await executor.cancel(id) }
    func agentTask(_ value: DurableTask) throws -> AgentTask? {
        let job = try ContractCodec.decode(TaskRequest<AresJob>.self, from: value.request).parameters
        guard let root = job.rootID, let status = AgentTaskStatus(rawValue: value.status.rawValue) else { return nil }
        return AgentTask(id: value.id, rootID: root, origin: job.origin ?? .user, correlationID: job.correlationID, status: status, createdAt: value.createdAt)
    }
}
