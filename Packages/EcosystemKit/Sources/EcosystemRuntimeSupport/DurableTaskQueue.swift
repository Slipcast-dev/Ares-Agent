import EcosystemContracts
import Foundation

/// Единственный процесс владеет SQLite и системным lock; actor сериализует
/// операции внутри процесса. Здесь нет await между проверкой и SQL COMMIT.
public struct LocalTaskHistoryRow: Sendable {
    public let id: UUID
    public let position: Int64
}

public actor DurableTaskQueue {
    public nonisolated let maximumConcurrentTasks: Int
    private let store: QueueStore
    public init(directory: URL, agentID: AgentID, maximumConcurrentTasks: Int? = nil,
                clock: @escaping @Sendable () -> Date = { Date() },
                fault: (@Sendable (QueueFaultPoint) throws -> Void)? = nil) throws {
        self.maximumConcurrentTasks = maximumConcurrentTasks ?? (agentID == .ares ? 1 : 2)
        store = try QueueStore(directory: directory, agentID: agentID,
            maximumConcurrentTasks: maximumConcurrentTasks ?? (agentID == .ares ? 1 : 2), clock: clock, fault: fault)
    }
    /// Проверка используется только доверенным runtime перед изменением grants/config.
    public func hasReservation(_ resource: String) throws -> Bool { try store.hasReservation(resource) }
    public func purgeExpiredReadHistory(retentionDays: Int = 90, limit: Int = 100) throws -> Int {
        try store.purgeExpiredReadHistory(retentionDays: retentionDays, limit: limit)
    }
    public func taskReserving(_ resource: String) throws -> DurableTask? { try store.taskReserving(resource) }
    public func accept(_ submission: QueueSubmission, retrying previousTaskID: UUID? = nil) throws -> DurableTask { try store.accept(submission, retrying: previousTaskID) }
    /// Активные callbacks не теряются за страницами новых queued/terminal задач.
    public func executingTasks() throws -> [DurableTask] { try store.executingTasks() }
    public func task(_ id: UUID, includeResult: Bool = true) throws -> DurableTask? { try store.task(id, includeResult: includeResult) }
    /// Keyset не сдвигается при добавлении новых строк между страницами.
    public func history(before: Int64? = nil, limit: Int = 500) throws -> [LocalTaskHistoryRow] { try store.history(before: before, limit: limit) }
    public func tasks(limit: Int = 100, offset: Int = 0) throws -> [DurableTask] { try store.tasks(limit: limit, offset: offset) }
    /// Отдельная выборка: старый карантин нельзя скрыть сотней новых чтений.
    public func recoveryTasks(offset: Int64 = 0) throws -> [DurableTask] { try store.recoveryTasks(offset: offset) }
    public func nextQueuedTask() throws -> DurableTask? { try store.nextQueuedTask() }
    public func claim(_ id: UUID, leaseSeconds: TimeInterval = 30) throws -> QueueLease { try store.claim(id, seconds: leaseSeconds) }
    public func heartbeat(_ token: QueueLease, leaseSeconds: TimeInterval = 30) throws -> QueueLease { try store.heartbeat(token, seconds: leaseSeconds) }
    public func checkpoint(_ token: QueueLease) throws { _ = try store.checked(token, cancellation: true, deadline: true) }
    public func reportProgress(_ token: QueueLease, progress: TaskProgress) throws { try store.reportProgress(token, progress: progress) }
    public func requestCancellation(_ id: UUID) throws -> DurableTask { try store.cancel(id) }
    public func beginReceipt(_ token: QueueLease, actionKey: String, summary: String? = nil) throws -> ActionReceipt { try store.beginReceipt(token, actionKey: actionKey, summary: summary) }
    public func completeReceipt(_ token: QueueLease, receiptID: UUID, evidence: Data) throws { try store.completeReceipt(token, receiptID: receiptID, evidence: evidence) }
    public func confirmNoEffect(_ token: QueueLease, receiptID: UUID, evidence: Data) throws {
        try store.completeReceipt(token, receiptID: receiptID, evidence: evidence, outcome: .confirmedNoEffect)
    }
    public func receipts(_ id: UUID, limit: Int = 100, offset: Int64 = 0) throws -> [ActionReceipt] { try store.receipts(id, limit: limit, offset: offset) }
    public func finish(_ token: QueueLease, status: TaskStatus, result: Data? = nil,
                       errorCode: KnownErrorCode? = nil) throws -> DurableTask {
        try store.finish(token, status: status, result: result, errorCode: errorCode)
    }
    public func recoverExpiredLeases() throws { try store.recover(allActive: false) }
    public func reconcile(_ id: UUID, resolutions: [UUID: ReceiptResolution]) throws -> DurableTask {
        try store.reconcile(id, resolutions: resolutions)
    }
}

/// Store доступен только из actor и во время его синхронного init. Отдельный
/// тип позволяет атомарно восстановить БД до публикации нового владельца.
private final class QueueStore: @unchecked Sendable {
    private let ownership: RuntimeOwnershipLease
    private let database: QueueDatabase
    private let agentID: AgentID
    private let maximumConcurrentTasks: Int
    private let clock: @Sendable () -> Date
    private let fault: (@Sendable (QueueFaultPoint) throws -> Void)?
    private let ownerID = UUID()
    private var ownerEpoch: Int64 = 0
    private var retentionCursor: Int64 = 0

    init(directory: URL, agentID: AgentID, maximumConcurrentTasks: Int,
         clock: @escaping @Sendable () -> Date, fault: (@Sendable (QueueFaultPoint) throws -> Void)?) throws {
        guard (1...8).contains(maximumConcurrentTasks) else { throw QueueFailure.invalidArgument }
        ownership = try RuntimeOwnershipLease(directory: directory)
        database = try QueueDatabase(directory: directory)
        self.agentID = agentID; self.maximumConcurrentTasks = maximumConcurrentTasks
        self.clock = clock; self.fault = fault
        try database.transaction {
            try database.query("CREATE TABLE IF NOT EXISTS queue_meta (id INTEGER PRIMARY KEY CHECK(id=1), agent TEXT NOT NULL, epoch INTEGER NOT NULL, fence INTEGER NOT NULL)")
            try database.query("CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, idempotency_key TEXT UNIQUE NOT NULL, fingerprint TEXT NOT NULL, status TEXT NOT NULL, created REAL NOT NULL, deadline REAL, document BLOB NOT NULL)")
            try database.query("CREATE INDEX IF NOT EXISTS tasks_status ON tasks(status)")
            try database.query("CREATE INDEX IF NOT EXISTS tasks_retention ON tasks(status, created)")
            try database.query("CREATE TABLE IF NOT EXISTS resource_locks (resource TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id))")
            try database.query("CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES tasks(id), action_key TEXT NOT NULL, state TEXT NOT NULL, document BLOB NOT NULL, UNIQUE(task_id, action_key))")
            try database.query("CREATE INDEX IF NOT EXISTS receipts_state ON receipts(task_id, state)")
            try database.query("CREATE INDEX IF NOT EXISTS tasks_deadline ON tasks(status, deadline)")
            if let metadata = try database.query("SELECT * FROM queue_meta WHERE id=1").first {
                guard try metadata.text("agent") == agentID.rawValue else { throw QueueFailure.wrongDomain }
                let epoch = try metadata.integer("epoch")
                guard epoch >= 0, epoch < Int64.max else { throw QueueFailure.corruptStorage }
                ownerEpoch = epoch + 1
                try database.query("UPDATE queue_meta SET epoch=? WHERE id=1", [.integer(ownerEpoch)])
            } else {
                ownerEpoch = 1
                try database.query("INSERT INTO queue_meta VALUES (1, ?, 1, 0)", [.text(agentID.rawValue)])
            }
        }
        try recover(allActive: true)
    }

    private func now() throws -> Date {
        let value = clock()
        guard value.timeIntervalSince1970.isFinite else { throw QueueFailure.invalidArgument }
        return value
    }
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(type, from: data) }
        catch { throw QueueFailure.corruptStorage }
    }
    /// Удаляем только доказанно завершённое чтение старше срока. Мутации,
    /// receipts, recoveryRequired и старые записи без finishedAt сохраняются.
    /// Cursor ограничивает работу batch даже при большом числе защищённых строк.
    func purgeExpiredReadHistory(retentionDays: Int, limit: Int) throws -> Int {
        guard (90...3650).contains(retentionDays), (1...500).contains(limit) else { throw QueueFailure.invalidArgument }
        let cutoff = try now().addingTimeInterval(-Double(retentionDays) * 86_400)
        return try database.transaction {
            let rows = try database.query("SELECT rowid AS cursor, id FROM tasks WHERE rowid>? AND created<? AND status IN ('completed','partial','failed','cancelled','interrupted') ORDER BY rowid LIMIT ?",
                [.integer(retentionCursor), .real(cutoff.timeIntervalSince1970), .integer(Int64(limit))])
            if rows.isEmpty { retentionCursor = 0; return 0 }
            var removed = 0
            for row in rows {
                retentionCursor = try row.integer("cursor")
                guard let id = UUID(uuidString: try row.text("id")) else { throw QueueFailure.corruptStorage }
                let value = try requireTask(id)
                guard !value.mutating, let finished = value.finishedAt, finished < cutoff,
                      try database.query("SELECT 1 FROM receipts WHERE task_id=? LIMIT 1", [.text(id.uuidString)]).isEmpty,
                      try database.query("SELECT 1 FROM resource_locks WHERE task_id=? LIMIT 1", [.text(id.uuidString)]).isEmpty else { continue }
                try database.query("DELETE FROM tasks WHERE id=?", [.text(id.uuidString)])
                removed += 1
            }
            return removed
        }
    }
    func taskReserving(_ resource: String) throws -> DurableTask? {
        try ContractValidation.identifier(resource)
        guard let row = try database.query("SELECT task_id FROM resource_locks WHERE resource=?", [.text(resource)]).first,
              let id = UUID(uuidString: try row.text("task_id")) else { return nil }
        return try requireTask(id)
    }
    func hasReservation(_ resource: String) throws -> Bool {
        try ContractValidation.identifier(resource)
        return try !database.query("SELECT 1 FROM resource_locks WHERE resource=? LIMIT 1", [.text(resource)]).isEmpty
    }
    func history(before: Int64?, limit: Int) throws -> [LocalTaskHistoryRow] {
        guard (1...500).contains(limit), before == nil || before! > 0 else { throw QueueFailure.invalidArgument }
        let query = before == nil ? "SELECT rowid AS position,id FROM tasks ORDER BY rowid DESC LIMIT ?" : "SELECT rowid AS position,id FROM tasks WHERE rowid<? ORDER BY rowid DESC LIMIT ?"
        return try database.query(query, before.map { [.integer($0), .integer(Int64(limit))] } ?? [.integer(Int64(limit))]).map {
            guard let id = UUID(uuidString: try $0.text("id")) else { throw QueueFailure.corruptStorage }
            return LocalTaskHistoryRow(id: id, position: try $0.integer("position"))
        }
    }
    func task(_ id: UUID, includeResult: Bool = true) throws -> DurableTask? {
        // SQLite удаляет base64 результата до копирования BLOB в Swift: история
        // не декодирует многомегабайтные результаты ради проверки доступа.
        let projection = includeResult ? "document" : "CAST(json_remove(CAST(document AS TEXT), '$.result') AS BLOB) AS document"
        guard let row = try database.query("SELECT status, " + projection + " FROM tasks WHERE id=?", [.text(id.uuidString)]).first else { return nil }
        let value = try decode(DurableTask.self, row.blob("document"))
        guard value.id == id, value.agentID == agentID, value.status.rawValue == (try row.text("status")) else {
            throw QueueFailure.corruptStorage
        }
        return value
    }
    private func requireTask(_ id: UUID) throws -> DurableTask {
        guard let value = try task(id) else { throw QueueFailure.taskNotFound }; return value
    }
    func executingTasks() throws -> [DurableTask] {
        try database.query("SELECT id FROM tasks WHERE status IN ('running','cancelling') ORDER BY rowid", []).map {
            guard let id = UUID(uuidString: try $0.text("id")) else { throw QueueFailure.corruptStorage }; return try requireTask(id)
        }
    }
    func tasks(limit: Int, offset: Int = 0) throws -> [DurableTask] {
        guard (0...1_000_000).contains(offset), (1...500).contains(limit) else { throw QueueFailure.invalidArgument }
        return try database.query("SELECT id FROM tasks ORDER BY rowid DESC LIMIT ? OFFSET ?", [.integer(Int64(limit)), .integer(Int64(offset))]).map {
            guard let id = UUID(uuidString: try $0.text("id")) else { throw QueueFailure.corruptStorage }
            return try requireTask(id)
        }
    }
    func recoveryTasks(offset: Int64) throws -> [DurableTask] {
        guard offset >= 0 else { throw QueueFailure.invalidArgument }
        return try database.query("SELECT id FROM tasks WHERE status='recoveryRequired' AND EXISTS (SELECT 1 FROM resource_locks WHERE task_id=tasks.id) ORDER BY rowid LIMIT 100 OFFSET ?", [.integer(offset)]).map {
            guard let id = UUID(uuidString: try $0.text("id")) else { throw QueueFailure.corruptStorage }; return try requireTask(id)
        }
    }
    private func save(_ task: inout DurableTask) throws {
        guard task.revision < Int64.max else { throw QueueFailure.corruptStorage }
        task.revision += 1
        try database.query("UPDATE tasks SET status=?, document=? WHERE id=?", [
            .text(task.status.rawValue), .blob(try encode(task)), .text(task.id.uuidString)])
    }
    private func releaseResources(_ id: UUID) throws {
        try database.query("DELETE FROM resource_locks WHERE task_id=?", [.text(id.uuidString)])
    }
    func accept(_ submission: QueueSubmission, retrying previousTaskID: UUID?) throws -> DurableTask {
        guard submission.agentID == agentID else { throw QueueFailure.wrongDomain }
        let time = try now()
        let accepted = try database.transaction {
            if let previousTaskID {
                let previous = try requireTask(previousTaskID)
                guard !submission.mutating, !previous.mutating,
                      [.failed, .interrupted].contains(previous.status),
                      previous.capabilityID == submission.capabilityID,
                      previous.resources == submission.resources,
                      previous.idempotencyKey != submission.idempotencyKey else { throw QueueFailure.invalidState }
            }
            if let existing = try database.query("SELECT id, fingerprint FROM tasks WHERE idempotency_key=?", [.text(submission.idempotencyKey)]).first {
                guard try existing.text("fingerprint") == submission.fingerprint else { throw QueueFailure.idempotencyConflict }
                guard let id = UUID(uuidString: try existing.text("id")) else { throw QueueFailure.corruptStorage }
                return try requireTask(id)
            }
            if let deadline = submission.deadline, deadline <= time { throw QueueFailure.deadlineExceeded }
            // Ограничиваем именно pending, не удаляем старые ключи ради приёма.
            let count = try database.query("SELECT COUNT(*) AS count FROM tasks WHERE status IN ('queued','running','cancelling')").first?.integer("count") ?? 0
            guard count < 256 else { throw QueueFailure.capacityReached }
            for resource in submission.resources {
                guard try database.query("SELECT 1 FROM resource_locks WHERE resource=?", [.text(resource)]).isEmpty else { throw QueueFailure.resourceBusy }
            }
            let value = DurableTask(id: UUID(), agentID: agentID, capabilityID: submission.capabilityID,
                idempotencyKey: submission.idempotencyKey, fingerprint: submission.fingerprint,
                request: submission.request, resources: submission.resources, mutating: submission.mutating,
                createdAt: time, deadline: submission.deadline, parentAttemptID: previousTaskID, status: .queued,
                revision: 0, lease: nil, progress: nil, cancellationRequestedAt: nil,
                cancellationTooLate: false, result: nil, errorCode: nil, reconciledAt: nil)
            try database.query("INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?)", [
                .text(value.id.uuidString), .text(value.idempotencyKey), .text(value.fingerprint),
                .text(value.status.rawValue), .real(time.timeIntervalSince1970), value.deadline.map { .real($0.timeIntervalSince1970) } ?? .null, .blob(try encode(value))])
            for resource in value.resources {
                try database.query("INSERT INTO resource_locks VALUES (?, ?)", [.text(resource), .text(value.id.uuidString)])
            }
            try fault?(.beforeAdmissionCommit)
            return value
        }
        try fault?(.afterAdmissionCommit)
        return accepted
    }
    func nextQueuedTask() throws -> DurableTask? {
        try expireQueued()
        guard let row = try database.query("SELECT id FROM tasks WHERE status='queued' ORDER BY rowid LIMIT 1").first,
              let id = UUID(uuidString: try row.text("id")) else { return nil }
        return try requireTask(id)
    }
    private func expireQueued() throws {
        let time = try now()
        try database.transaction {
            for row in try database.query("SELECT id FROM tasks WHERE status='queued' AND deadline IS NOT NULL AND deadline<=?", [.real(time.timeIntervalSince1970)]) {
                guard let id = UUID(uuidString: try row.text("id")) else { throw QueueFailure.corruptStorage }
                var value = try requireTask(id)
                if let deadline = value.deadline, deadline <= time {
                    value.status = .failed; value.errorCode = .deadlineExceeded; value.finishedAt = time
                    try save(&value); try releaseResources(id)
                }
            }
        }
    }
    func claim(_ id: UUID, seconds: TimeInterval) throws -> QueueLease {
        guard seconds.isFinite, (1...3600).contains(seconds) else { throw QueueFailure.invalidArgument }
        try recover(allActive: false); try expireQueued()
        return try database.transaction {
            var value = try requireTask(id)
            guard value.status == .queued else { throw QueueFailure.invalidState }
            guard try database.query("SELECT id FROM tasks WHERE status IN ('running','cancelling')").count < maximumConcurrentTasks else {
                throw QueueFailure.capacityReached
            }
            guard let metadata = try database.query("SELECT fence FROM queue_meta WHERE id=1").first else { throw QueueFailure.corruptStorage }
            let previous = try metadata.integer("fence")
            guard previous >= 0, previous < Int64.max else { throw QueueFailure.corruptStorage }
            let token = QueueLease(taskID: id, ownerID: ownerID, ownerEpoch: ownerEpoch,
                fencingToken: previous + 1, expiresAt: try now().addingTimeInterval(seconds))
            try database.query("UPDATE queue_meta SET fence=? WHERE id=1", [.integer(token.fencingToken)])
            value.status = .running; value.lease = token
            try save(&value)
            return token
        }
    }
    func checked(_ token: QueueLease, cancellation: Bool, deadline: Bool) throws -> DurableTask {
        let value = try requireTask(token.taskID)
        let time = try now()
        guard [.running, .cancelling].contains(value.status), let current = value.lease,
              current.ownerID == token.ownerID, current.ownerID == ownerID,
              current.ownerEpoch == ownerEpoch, token.ownerEpoch == ownerEpoch,
              current.fencingToken == token.fencingToken, current.expiresAt > time else {
            throw QueueFailure.staleLease
        }
        if cancellation && value.cancellationRequestedAt != nil { throw QueueFailure.cancelled }
        if deadline, let limit = value.deadline, limit <= time { throw QueueFailure.deadlineExceeded }
        return value
    }
    func heartbeat(_ token: QueueLease, seconds: TimeInterval) throws -> QueueLease {
        guard seconds.isFinite, (1...3600).contains(seconds) else { throw QueueFailure.invalidArgument }
        return try database.transaction {
            var value = try checked(token, cancellation: false, deadline: false)
            let renewed = QueueLease(taskID: token.taskID, ownerID: ownerID, ownerEpoch: ownerEpoch,
                fencingToken: token.fencingToken, expiresAt: try now().addingTimeInterval(seconds))
            value.lease = renewed; try save(&value); return renewed
        }
    }
    func reportProgress(_ token: QueueLease, progress: TaskProgress) throws {
        try progress.validate()
        try database.transaction {
            var value = try checked(token, cancellation: true, deadline: true)
            if let previous = value.progress, previous.phase == progress.phase,
               previous.processed.value > progress.processed.value { throw QueueFailure.invalidArgument }
            value.progress = progress; try save(&value)
        }
    }
    func cancel(_ id: UUID) throws -> DurableTask {
        try database.transaction {
            var value = try requireTask(id)
            guard !value.status.isTerminal else { return value }
            if value.cancellationRequestedAt == nil { value.cancellationRequestedAt = try now() }
            if value.status == .queued {
                value.status = .cancelled; value.errorCode = .cancelled; value.finishedAt = try now()
                try releaseResources(id)
            } else { value.status = .cancelling }
            try save(&value); return value
        }
    }
    func receipts(_ id: UUID, limit: Int = 100, offset: Int64 = 0) throws -> [ActionReceipt] {
        guard (1...500).contains(limit), offset >= 0 else { throw QueueFailure.invalidArgument }
        _ = try requireTask(id)
        return try database.query("SELECT document FROM receipts WHERE task_id=? ORDER BY rowid LIMIT ? OFFSET ?", [.text(id.uuidString), .integer(Int64(limit)), .integer(offset)]).map {
            try decode(ActionReceipt.self, $0.blob("document"))
        }
    }
    func beginReceipt(_ token: QueueLease, actionKey: String, summary: String?) throws -> ActionReceipt {
        if let summary, summary.utf8.count > 4096 { throw QueueFailure.invalidArgument }
        try ContractValidation.identifier(actionKey)
        let receipt = try database.transaction {
            let value = try checked(token, cancellation: true, deadline: true)
            guard value.mutating else { throw QueueFailure.invalidState }
            guard try database.query("SELECT 1 FROM receipts WHERE task_id=? AND action_key=?", [
                .text(value.id.uuidString), .text(actionKey)]).isEmpty else { throw QueueFailure.receiptAlreadyExists }
            guard try database.query("SELECT 1 FROM receipts WHERE task_id=? AND state='started' LIMIT 1",
                                     [.text(value.id.uuidString)]).isEmpty else { throw QueueFailure.invalidState }
            let receipt = ActionReceipt(summary: summary, id: UUID(), taskID: value.id, actionKey: actionKey,
                fencingToken: token.fencingToken, startedAt: try now(), state: .started, finishedAt: nil, evidence: nil)
            try database.query("INSERT INTO receipts VALUES (?, ?, ?, ?, ?)", [
                .text(receipt.id.uuidString), .text(value.id.uuidString), .text(actionKey), .text(receipt.state.rawValue), .blob(try encode(receipt))])
            try fault?(.beforeReceiptCommit); return receipt
        }
        try fault?(.afterReceiptCommit); return receipt
    }
    func completeReceipt(_ token: QueueLease, receiptID: UUID, evidence: Data, outcome: ReceiptState = .done) throws {
        guard outcome != .started, !evidence.isEmpty, evidence.count <= ContractCodec.maximumBytes else { throw QueueFailure.invalidArgument }
        try database.transaction {
            _ = try checked(token, cancellation: false, deadline: false)
            guard let row = try database.query("SELECT document FROM receipts WHERE id=? AND task_id=?",
                [.text(receiptID.uuidString), .text(token.taskID.uuidString)]).first else { throw QueueFailure.invalidState }
            var receipt = try decode(ActionReceipt.self, row.blob("document"))
            guard receipt.state == .started, receipt.fencingToken == token.fencingToken else { throw QueueFailure.invalidState }
            receipt.state = outcome; receipt.finishedAt = try now(); receipt.evidence = evidence
            try database.query("UPDATE receipts SET state=?, document=? WHERE id=?", [.text(receipt.state.rawValue), .blob(try encode(receipt)), .text(receiptID.uuidString)])
            try fault?(.beforeReceiptCompletionCommit)
        }
        try fault?(.afterReceiptCompletionCommit)
    }
    func finish(_ token: QueueLease, status: TaskStatus, result: Data?, errorCode: KnownErrorCode?) throws -> DurableTask {
        guard [.completed, .partial, .failed, .cancelled].contains(status),
              result.map({ $0.count <= ContractCodec.maximumBytes }) ?? true else { throw QueueFailure.invalidArgument }
        if [.completed, .partial].contains(status) && result == nil { throw QueueFailure.invalidArgument }
        if status == .failed && errorCode == nil { throw QueueFailure.invalidArgument }
        let finished = try database.transaction {
            var value = try checked(token, cancellation: false, deadline: false)
            if status == .cancelled && value.cancellationRequestedAt == nil { throw QueueFailure.invalidState }
            let unresolved = try !database.query("SELECT 1 FROM receipts WHERE task_id=? AND state='started' LIMIT 1", [.text(value.id.uuidString)]).isEmpty
            if unresolved {
                // Нельзя выдавать failed/cancelled/completed за доказанный исход,
                // когда эффект мог произойти. Ресурсы остаются в карантине.
                value.status = .recoveryRequired; value.errorCode = .recoveryRequired
            } else {
                value.status = status; value.errorCode = errorCode; value.result = result
                if [.completed, .partial].contains(status), let deadline = value.deadline, deadline <= (try now()) {
                    value.status = .failed; value.errorCode = .deadlineExceeded
                }
                value.cancellationTooLate = value.cancellationRequestedAt != nil && [.completed, .partial].contains(value.status)
                try releaseResources(value.id)
            }
            value.lease = nil; value.finishedAt = try now(); try save(&value); try fault?(.beforeResultCommit)
            return value
        }
        try fault?(.afterResultCommit); return finished
    }
    func recover(allActive: Bool) throws {
        let time = try now()
        try database.transaction {
            for row in try database.query("SELECT id FROM tasks WHERE status IN ('running','cancelling')") {
                guard let id = UUID(uuidString: try row.text("id")) else { throw QueueFailure.corruptStorage }
                var value = try requireTask(id)
                guard let lease = value.lease else { throw QueueFailure.corruptStorage }
                guard allActive || lease.expiresAt <= time else { continue }
                // Даже все done receipts без committed result требуют проверки:
                // повтор того же действия после рестарта уже небезопасен.
                let hasReceipts = try !database.query("SELECT 1 FROM receipts WHERE task_id=? LIMIT 1", [.text(id.uuidString)]).isEmpty
                if value.mutating && hasReceipts {
                    value.status = .recoveryRequired; value.errorCode = .recoveryRequired
                } else {
                    value.status = .interrupted; value.errorCode = .recoveryRequired
                    try releaseResources(id)
                }
                value.lease = nil; value.finishedAt = time; try save(&value)
            }
        }
        try expireQueued()
    }
    func reconcile(_ id: UUID, resolutions: [UUID: ReceiptResolution]) throws -> DurableTask {
        try database.transaction {
            var value = try requireTask(id)
            guard value.status == .recoveryRequired, value.reconciledAt == nil else { throw QueueFailure.invalidState }
            let all = try database.query("SELECT document FROM receipts WHERE task_id=? AND state='started'", [.text(id.uuidString)])
                .map { try decode(ActionReceipt.self, $0.blob("document")) }
            guard Set(resolutions.keys) == Set(all.map(\.id)) else {
                throw QueueFailure.recoveryRequired
            }
            for var receipt in all where receipt.state == .started {
                guard let resolution = resolutions[receipt.id] else { throw QueueFailure.recoveryRequired }
                receipt.state = resolution.state; receipt.evidence = resolution.evidence; receipt.finishedAt = try now()
                try database.query("UPDATE receipts SET state=?, document=? WHERE id=?", [.text(receipt.state.rawValue), .blob(try encode(receipt)), .text(receipt.id.uuidString)])
            }
            value.reconciledAt = try now(); try save(&value); try releaseResources(id)
            return value
        }
    }
}
