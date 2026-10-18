import Foundation
import EcosystemRuntimeSupport

/// Только GUI получает эти локальные проекции. Request/result задачи и bookmarks
/// не включаются в список: для сверки достаточно контекста записанного действия.
public struct RecoveryItem: Codable, Sendable, Identifiable {
    public let id: UUID
    public let capability: String
    public let revision: Int64
    public let canConfirm: Bool
}
public struct RecoveryReceipt: Codable, Sendable, Identifiable {
    public let id: UUID
    public let summary: String
    public let state: ReceiptState
}
public struct RecoveryPage: Codable, Sendable {
    public let items: [RecoveryItem]
    public let nextOffset: Int64?
}
public struct RecoveryDetails: Codable, Sendable {
    public let item: RecoveryItem
    public let receipts: [RecoveryReceipt]
    public let nextOffset: Int64?
}
public struct RecoveryListRequest: Codable, Sendable { public let offset: Int64; public init(offset: Int64 = 0) { self.offset = offset } }
public struct RecoveryInspectRequest: Codable, Sendable {
    public let id: UUID; public let offset: Int64
    public init(id: UUID, offset: Int64 = 0) { self.id = id; self.offset = offset }
}
public struct RecoveryDecision: Codable, Sendable {
    public let receiptID: UUID
    public let state: ReceiptState
    public let note: String
    public init(receiptID: UUID, state: ReceiptState, note: String) { self.receiptID = receiptID; self.state = state; self.note = note }
}
public struct RecoveryConfirmation: Codable, Sendable {
    public let id: UUID; public let revision: Int64; public let decisions: [RecoveryDecision]
    public init(id: UUID, revision: Int64, decisions: [RecoveryDecision]) { self.id = id; self.revision = revision; self.decisions = decisions }
}

/// Сериализует подтверждения и требует сверить каждое started действие. Это
/// операторская аттестация фактов, а не автоматическое доказательство состояния ФС.
public actor LocalRecoveryService {
    private let queue: DurableTaskQueue
    private let executor: DurableTaskExecutor
    private let beforeRelease: @Sendable ([ActionReceipt], [RecoveryDecision]) async throws -> Void
    private var confirming = false
    public init(queue: DurableTaskQueue, executor: DurableTaskExecutor,
                beforeRelease: @escaping @Sendable ([ActionReceipt], [RecoveryDecision]) async throws -> Void = { _, _ in }) {
        self.queue = queue; self.executor = executor; self.beforeRelease = beforeRelease
    }
    private func item(_ task: DurableTask) async -> RecoveryItem {
        RecoveryItem(id: task.id, capability: task.capabilityID, revision: task.revision, canConfirm: await executor.canReconcile(task.id))
    }
    private func pending(_ id: UUID) async throws -> DurableTask {
        guard let task = try await queue.task(id), task.status == .recoveryRequired, task.reconciledAt == nil else { throw LocalRuntimeFailure.conflict }
        return task
    }
    public func handle(role: LocalRole, request: LocalRPCRequest) async throws -> Data {
        guard role == .gui else { throw LocalRuntimeFailure.denied }
        switch request.operation {
        case "recovery.list":
            let value = try LocalWire.decode(RecoveryListRequest.self, request.payload, keys: ["offset"])
            let tasks = try await queue.recoveryTasks(offset: value.offset)
            var items: [RecoveryItem] = []
            for task in tasks { items.append(await item(task)) }
            return try LocalWire.encode(RecoveryPage(items: items, nextOffset: tasks.count == 100 ? value.offset + 100 : nil))
        case "recovery.inspect":
            let value = try LocalWire.decode(RecoveryInspectRequest.self, request.payload, keys: ["id", "offset"])
            let task = try await pending(value.id)
            let receipts = try await queue.receipts(value.id, limit: 100, offset: value.offset)
            return try LocalWire.encode(RecoveryDetails(item: await item(task), receipts: receipts.map {
                RecoveryReceipt(id: $0.id, summary: $0.summary ?? "Действие прежней версии: сверяйте файл и журнал правила вручную.", state: $0.state)
            }, nextOffset: receipts.count == 100 ? value.offset + 100 : nil))
        case "recovery.confirm":
            guard !confirming else { throw LocalRuntimeFailure.busy }
            let value = try LocalWire.decode(RecoveryConfirmation.self, request.payload, keys: ["id", "revision", "decisions"])
            let raw = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            guard let rawDecisions = raw?["decisions"] as? [[String: Any]], rawDecisions.allSatisfy({ Set($0.keys).isSubset(of: ["receiptID", "state", "note"]) }) else { throw LocalRuntimeFailure.invalidRequest }
            confirming = true; defer { confirming = false }
            let task = try await pending(value.id)
            guard task.revision == value.revision else { throw LocalRuntimeFailure.conflict }
            guard await executor.canReconcile(value.id) else { throw LocalRuntimeFailure.busy }
            var unresolved: [ActionReceipt] = []; var offset: Int64 = 0
            while true {
                let page = try await queue.receipts(value.id, limit: 500, offset: offset)
                unresolved += page.filter { $0.state == .started }
                if page.count < 500 { break }; offset += 500
            }
            guard value.decisions.count == unresolved.count, Set(value.decisions.map(\.receiptID)) == Set(unresolved.map(\.id)) else { throw LocalRuntimeFailure.invalidRequest }
            var resolutions: [UUID: ReceiptResolution] = [:]
            for decision in value.decisions {
                let note = decision.note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard decision.state != .started, decision.note.count <= 2000, (20...2000).contains(note.count) else { throw LocalRuntimeFailure.invalidRequest }
                let evidence = try LocalWire.encode(RecoveryDecision(receiptID: decision.receiptID, state: decision.state, note: note))
                resolutions[decision.receiptID] = try ReceiptResolution(state: decision.state, evidence: evidence)
            }
            // Доменный журнал изменяется ещё под quarantine. Если БД откажет,
            // locks сохраняются; повтор подтверждения идемпотентно завершает сверку.
            try await beforeRelease(unresolved, value.decisions)
            _ = try await executor.reconcile(value.id, resolutions: resolutions)
            return try LocalWire.encode(LocalEmpty())
        default: throw LocalRuntimeFailure.denied
        }
    }
}
