import CryptoKit
import EcosystemContracts
import Foundation

public protocol QueueDomainError: Error { var knownCode: KnownErrorCode { get } }

public enum QueueFailure: Error, Equatable {
    case invalidArgument, ownerBusy, unsafeStorage, incompatibleStorage, corruptStorage
    case storageFailure, storageFull, wrongDomain, resourceBusy, idempotencyConflict, taskNotFound
    case invalidState, staleLease, capacityReached, cancelled, deadlineExceeded
    case receiptAlreadyExists, recoveryRequired, emergencyStopped
}

/// Только доверенный runtime строит submission после проверки capability/grant.
/// Это локальный storage API, а не публичный endpoint с самостоятельной авторизацией.
public struct QueueSubmission: Sendable {
    public let agentID: AgentID
    public let capabilityID: String
    public let idempotencyKey: String
    public let request: Data
    public let fingerprint: String
    public let resources: [String]
    public let mutating: Bool
    public let deadline: Date?

    public init<P>(request: TaskRequest<P>, resources: [String], mutating: Bool) throws {
        let encoded = try ContractCodec.encode(request)
        guard !resources.isEmpty, resources.count <= 512, Set(resources).count == resources.count else { throw QueueFailure.invalidArgument }
        try resources.forEach { try ContractValidation.identifier($0) }
        self.agentID = request.agentID; capabilityID = request.capabilityID
        idempotencyKey = request.idempotencyKey; self.request = encoded
        self.resources = resources.sorted(); self.mutating = mutating
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        if request.deadlineAt?.value.contains(".") == true { formatter.formatOptions.insert(.withFractionalSeconds) }
        deadline = request.deadlineAt.flatMap { formatter.date(from: $0.value) }
        guard var semantic = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { throw QueueFailure.invalidArgument }
        // Correlation/time получения и заявленные labels не меняют смысл повтора.
        // Parameters заранее нормализуются доменной Codable-моделью/схемой.
        for key in ["requestId", "workflowId", "parentTaskId", "createdAt", "origin", "clientContext", "idempotencyKey"] {
            semantic.removeValue(forKey: key)
        }
        semantic["resources"] = self.resources; semantic["mutating"] = mutating
        let canonical = try JSONSerialization.data(withJSONObject: semantic, options: [.sortedKeys])
        fingerprint = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}

public struct QueueLease: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let ownerID: UUID
    public let ownerEpoch: Int64
    public let fencingToken: Int64
    public let expiresAt: Date
}

/// Внутренняя запись содержит параметры/результат; MCP обязан выдавать только
/// разрешённую проекцию после проверки доступа. Сам taskID не является grant.
public struct DurableTask: Codable, Sendable {
    public let id: UUID
    public let agentID: AgentID
    public let capabilityID: String
    public let idempotencyKey: String
    public let fingerprint: String
    public let request: Data
    public let resources: [String]
    public let mutating: Bool
    public let createdAt: Date
    public let deadline: Date?
    public let parentAttemptID: UUID?
    public var status: TaskStatus
    public var revision: Int64
    public var lease: QueueLease?
    public var progress: TaskProgress?
    public var cancellationRequestedAt: Date?
    public var cancellationTooLate: Bool
    public var result: Data?
    public var errorCode: KnownErrorCode?
    public var reconciledAt: Date?
    public var finishedAt: Date? = nil
}

public enum ReceiptState: String, Codable, Sendable { case started, done, confirmedNoEffect }
public struct ActionReceipt: Codable, Sendable {
    /// Человекочитаемый контекст фиксируется до эффекта; старые receipts его не имеют.
    public var summary: String? = nil
    public let id: UUID
    public let taskID: UUID
    public let actionKey: String
    public let fencingToken: Int64
    public let startedAt: Date
    public var state: ReceiptState
    public var finishedAt: Date?
    public var evidence: Data?
}
public struct ReceiptResolution: Sendable {
    public let state: ReceiptState
    public let evidence: Data
    public init(state: ReceiptState, evidence: Data) throws {
        guard state != .started, !evidence.isEmpty, evidence.count <= ContractCodec.maximumBytes else {
            throw QueueFailure.invalidArgument
        }
        self.state = state; self.evidence = evidence
    }
}

/// Fault hook не включается входным запросом. Он нужен проверочному executable
/// для настоящего _exit между SQL-записью/COMMIT/внешним эффектом.
public enum QueueFaultPoint: String, Sendable {
    case beforeAdmissionCommit, afterAdmissionCommit, beforeReceiptCommit, afterReceiptCommit
    case beforeReceiptCompletionCommit, afterReceiptCompletionCommit
    case beforeResultCommit, afterResultCommit
}

public extension DurableTask {
    /// Внешнему клиенту нужны статус/результат, но не внутренний запрос,
    /// lease/fencing, ресурсы, idempotency key или fingerprint admission.
    func forExternalClient() -> Self {
        Self(id: id, agentID: agentID, capabilityID: capabilityID, idempotencyKey: "", fingerprint: "", request: Data(), resources: [], mutating: mutating, createdAt: createdAt, deadline: deadline, parentAttemptID: nil, status: status, revision: revision, lease: nil, progress: progress, cancellationRequestedAt: cancellationRequestedAt, cancellationTooLate: cancellationTooLate, result: result, errorCode: errorCode, reconciledAt: reconciledAt, finishedAt: finishedAt)
    }
}

/// Только счётчики: экспорт не раскрывает параметры, идентификаторы или пути.
/// activeCallbacks учитывает физическую работу даже после истечения lease.
public struct QueueEmergencyStatus: Codable, Sendable {
    public var stopped: Bool
    public let pendingTasks: Int
    public let recoveryTasks: Int
    public var activeCallbacks: Int
    public init(stopped: Bool, pendingTasks: Int, recoveryTasks: Int, activeCallbacks: Int = 0) {
        self.stopped = stopped; self.pendingTasks = pendingTasks
        self.recoveryTasks = recoveryTasks; self.activeCallbacks = activeCallbacks
    }
}
