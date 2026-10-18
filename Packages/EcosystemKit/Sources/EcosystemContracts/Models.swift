import Foundation

/// Общая wire-модель ClientContext; межполевые условия проверяет ContractCodec.
public struct ClientContext: EcosystemContract {
    public let clientID: String
    public let sessionID: UUID?
    public init(clientID: String,
                sessionID: UUID? = nil) throws {
        self.clientID = clientID
        self.sessionID = sessionID
        try validate()
    }
    public init(from decoder: Decoder) throws {
        try ContractValidation.rejectUnknownFields(decoder, allowed: Self.allowedRequestKeys ?? [])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            clientID: try c.decode(String.self, forKey: .clientID),
            sessionID: try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        )
    }
    private enum CodingKeys: String, CodingKey {
        case clientID = "clientId"
        case sessionID = "sessionId"
    }
    public static var allowedRequestKeys: Set<String>? { ["clientId", "sessionId"] }
    public func validate() throws {
        try ContractValidation.identifier(clientID)
    }
}

/// Общая wire-модель TaskProgress; межполевые условия проверяет ContractCodec.
public struct TaskProgress: EcosystemContract {
    public let phase: String
    public let processed: NonnegativeInt
    public let total: NonnegativeInt?
    public init(phase: String,
                processed: NonnegativeInt,
                total: NonnegativeInt? = nil) throws {
        self.phase = phase
        self.processed = processed
        self.total = total
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            phase: try c.decode(String.self, forKey: .phase),
            processed: try c.decode(NonnegativeInt.self, forKey: .processed),
            total: try c.decodeIfPresent(NonnegativeInt.self, forKey: .total)
        )
    }
    private enum CodingKeys: String, CodingKey {
        case phase
        case processed
        case total
    }
    public func validate() throws {
        try ContractValidation.boundedText(phase, maximum: 128)
        if let total, processed.value > total.value { throw ContractFailure.invalidArgument }
    }
}

/// Общая wire-модель TaskRequest; межполевые условия проверяет ContractCodec.
public struct TaskRequest<Parameters: Codable & Sendable>: EcosystemContract {
    public let schemaVersion: ContractVersion
    public let requestID: UUID
    public let workflowID: UUID?
    public let parentTaskID: UUID?
    public let agentID: AgentID
    public let capabilityID: String
    public let parameters: Parameters
    public let origin: TaskOrigin
    public let clientContext: ClientContext?
    public let idempotencyKey: String
    public let rootID: UUID?
    public let grantID: UUID?
    public let planID: UUID?
    public let planRevision: NonnegativeInt?
    public let createdAt: UTCTimestamp
    public let deadlineAt: UTCTimestamp?
    public let disconnectPolicy: DisconnectPolicy
    public init(schemaVersion: ContractVersion = .current,
                requestID: UUID,
                workflowID: UUID? = nil,
                parentTaskID: UUID? = nil,
                agentID: AgentID,
                capabilityID: String,
                parameters: Parameters,
                origin: TaskOrigin,
                clientContext: ClientContext? = nil,
                idempotencyKey: String,
                rootID: UUID? = nil,
                grantID: UUID? = nil,
                planID: UUID? = nil,
                planRevision: NonnegativeInt? = nil,
                createdAt: UTCTimestamp,
                deadlineAt: UTCTimestamp? = nil,
                disconnectPolicy: DisconnectPolicy = .continueOnDisconnect) throws {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.workflowID = workflowID
        self.parentTaskID = parentTaskID
        self.agentID = agentID
        self.capabilityID = capabilityID
        self.parameters = parameters
        self.origin = origin
        self.clientContext = clientContext
        self.idempotencyKey = idempotencyKey
        self.rootID = rootID
        self.grantID = grantID
        self.planID = planID
        self.planRevision = planRevision
        self.createdAt = createdAt
        self.deadlineAt = deadlineAt
        self.disconnectPolicy = disconnectPolicy
        try validate()
    }
    public init(from decoder: Decoder) throws {
        try ContractValidation.rejectUnknownFields(decoder, allowed: Self.allowedRequestKeys ?? [])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try c.decode(ContractVersion.self, forKey: .schemaVersion),
            requestID: try c.decode(UUID.self, forKey: .requestID),
            workflowID: try c.decodeIfPresent(UUID.self, forKey: .workflowID),
            parentTaskID: try c.decodeIfPresent(UUID.self, forKey: .parentTaskID),
            agentID: try c.decode(AgentID.self, forKey: .agentID),
            capabilityID: try c.decode(String.self, forKey: .capabilityID),
            parameters: try c.decode(Parameters.self, forKey: .parameters),
            origin: try c.decode(TaskOrigin.self, forKey: .origin),
            clientContext: try c.decodeIfPresent(ClientContext.self, forKey: .clientContext),
            idempotencyKey: try c.decode(String.self, forKey: .idempotencyKey),
            rootID: try c.decodeIfPresent(UUID.self, forKey: .rootID),
            grantID: try c.decodeIfPresent(UUID.self, forKey: .grantID),
            planID: try c.decodeIfPresent(UUID.self, forKey: .planID),
            planRevision: try c.decodeIfPresent(NonnegativeInt.self, forKey: .planRevision),
            createdAt: try c.decode(UTCTimestamp.self, forKey: .createdAt),
            deadlineAt: try c.decodeIfPresent(UTCTimestamp.self, forKey: .deadlineAt),
            disconnectPolicy: try c.decodeIfPresent(DisconnectPolicy.self, forKey: .disconnectPolicy) ?? .continueOnDisconnect
        )
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case requestID = "requestId"
        case workflowID = "workflowId"
        case parentTaskID = "parentTaskId"
        case agentID = "agentId"
        case capabilityID = "capabilityId"
        case parameters
        case origin
        case clientContext
        case idempotencyKey
        case rootID = "rootId"
        case grantID = "grantId"
        case planID = "planId"
        case planRevision
        case createdAt
        case deadlineAt
        case disconnectPolicy
    }
    public static var allowedRequestKeys: Set<String>? { ["schemaVersion", "requestId", "workflowId", "parentTaskId", "agentId", "capabilityId", "parameters", "origin", "clientContext", "idempotencyKey", "rootId", "grantId", "planId", "planRevision", "createdAt", "deadlineAt", "disconnectPolicy"] }
    public func validate() throws {
        try schemaVersion.requireCompatible(); try ContractValidation.identifier(capabilityID)
        try ContractValidation.boundedText(idempotencyKey, maximum: 128); try clientContext?.validate()
        if let deadlineAt, deadlineAt < createdAt { throw ContractFailure.invalidArgument }
        if planID == nil && planRevision != nil { throw ContractFailure.invalidArgument }
        if (capabilityID.hasPrefix("file.") || capabilityID.hasPrefix("rule.")) && agentID != .ares {
            throw ContractFailure.invalidArgument
        }
        if ["system.", "diagnostics.", "storage.", "monitor."].contains(where: capabilityID.hasPrefix) && agentID != .athena { throw ContractFailure.invalidArgument }
        if capabilityID.hasPrefix("file.") && capabilityID != "file.list_roots" && rootID == nil { throw ContractFailure.invalidArgument }
    }
}

/// Общая wire-модель TaskRecord; межполевые условия проверяет ContractCodec.
public struct TaskRecord<Parameters: Codable & Sendable>: EcosystemContract {
    public let schemaVersion: ContractVersion
    public let taskID: UUID
    public let request: TaskRequest<Parameters>
    public let originVerification: OriginVerification
    public let status: TaskStatus
    public let revision: NonnegativeInt
    public let progress: TaskProgress?
    public let cancellationRequestedAt: UTCTimestamp?
    public init(schemaVersion: ContractVersion = .current,
                taskID: UUID,
                request: TaskRequest<Parameters>,
                originVerification: OriginVerification = .unverified,
                status: TaskStatus,
                revision: NonnegativeInt,
                progress: TaskProgress? = nil,
                cancellationRequestedAt: UTCTimestamp? = nil) throws {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.request = request
        self.originVerification = originVerification
        self.status = status
        self.revision = revision
        self.progress = progress
        self.cancellationRequestedAt = cancellationRequestedAt
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try c.decode(ContractVersion.self, forKey: .schemaVersion),
            taskID: try c.decode(UUID.self, forKey: .taskID),
            request: try c.decode(TaskRequest<Parameters>.self, forKey: .request),
            originVerification: try c.decodeIfPresent(OriginVerification.self, forKey: .originVerification) ?? .unverified,
            status: try c.decode(TaskStatus.self, forKey: .status),
            revision: try c.decode(NonnegativeInt.self, forKey: .revision),
            progress: try c.decodeIfPresent(TaskProgress.self, forKey: .progress),
            cancellationRequestedAt: try c.decodeIfPresent(UTCTimestamp.self, forKey: .cancellationRequestedAt)
        )
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case taskID = "taskId"
        case request
        case originVerification
        case status
        case revision
        case progress
        case cancellationRequestedAt
    }
    public func validate() throws {
        try schemaVersion.requireCompatible(); try request.validate(); try progress?.validate()
        if status == .cancelling && cancellationRequestedAt == nil { throw ContractFailure.invalidArgument }
    }
}

/// Общая wire-модель ContractError; межполевые условия проверяет ContractCodec.
public struct ContractError: EcosystemContract {
    public let code: String
    public let scope: ErrorScope
    public let message: String
    public let retryable: Bool
    public let userAction: String?
    public let correlationID: UUID
    public init(code: String,
                scope: ErrorScope,
                message: String,
                retryable: Bool,
                userAction: String? = nil,
                correlationID: UUID) throws {
        self.code = code
        self.scope = scope
        self.message = message
        self.retryable = retryable
        self.userAction = userAction
        self.correlationID = correlationID
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            code: try c.decode(String.self, forKey: .code),
            scope: try c.decode(ErrorScope.self, forKey: .scope),
            message: try c.decode(String.self, forKey: .message),
            retryable: try c.decode(Bool.self, forKey: .retryable),
            userAction: try c.decodeIfPresent(String.self, forKey: .userAction),
            correlationID: try c.decode(UUID.self, forKey: .correlationID)
        )
    }
    private enum CodingKeys: String, CodingKey {
        case code
        case scope
        case message
        case retryable
        case userAction
        case correlationID = "correlationId"
    }
    public func validate() throws {
        guard code.range(of: "^[A-Z][A-Z0-9_]{0,63}\\z", options: .regularExpression) != nil else {
            throw ContractFailure.invalidArgument
        }
        try ContractValidation.boundedText(message)
        if let userAction { try ContractValidation.boundedText(userAction) }
    }
}

/// Общая wire-модель TaskResult; межполевые условия проверяет ContractCodec.
public struct TaskResult<Payload: Codable & Sendable>: EcosystemContract {
    public let schemaVersion: ContractVersion
    public let taskID: UUID
    public let status: TaskStatus
    public let summary: String
    public let data: Payload
    public let warnings: [String]
    public let errors: [ContractError]
    public let startedAt: UTCTimestamp?
    public let finishedAt: UTCTimestamp
    public let dataClassification: DataClassification
    public let completeness: Completeness
    public let resultRevision: NonnegativeInt
    public let snapshotID: UUID?
    public let measuredAt: UTCTimestamp?
    public let indexGeneration: NonnegativeInt?
    public let skippedCount: NonnegativeInt?
    public let cancellationTooLate: Bool
    public let stale: Bool
    public let nextCursor: String?
    public let artifacts: [String]
    public let actionReceipts: [UUID]
    public let limitations: [String]
    public init(schemaVersion: ContractVersion = .current,
                taskID: UUID,
                status: TaskStatus,
                summary: String,
                data: Payload,
                warnings: [String] = [],
                errors: [ContractError] = [],
                startedAt: UTCTimestamp?,
                finishedAt: UTCTimestamp,
                dataClassification: DataClassification,
                completeness: Completeness,
                resultRevision: NonnegativeInt,
                snapshotID: UUID? = nil,
                measuredAt: UTCTimestamp? = nil,
                indexGeneration: NonnegativeInt? = nil,
                skippedCount: NonnegativeInt? = nil,
                cancellationTooLate: Bool = false,
                stale: Bool = false,
                nextCursor: String? = nil,
                artifacts: [String] = [],
                actionReceipts: [UUID] = [],
                limitations: [String] = []) throws {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.status = status
        self.summary = summary
        self.data = data
        self.warnings = warnings
        self.errors = errors
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.dataClassification = dataClassification
        self.completeness = completeness
        self.resultRevision = resultRevision
        self.snapshotID = snapshotID
        self.measuredAt = measuredAt
        self.indexGeneration = indexGeneration
        self.skippedCount = skippedCount
        self.cancellationTooLate = cancellationTooLate
        self.stale = stale
        self.nextCursor = nextCursor
        self.artifacts = artifacts
        self.actionReceipts = actionReceipts
        self.limitations = limitations
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // startedAt присутствует даже у не начавшейся задачи (null).
        guard c.contains(.startedAt) else { throw ContractFailure.invalidArgument }
        try self.init(
            schemaVersion: try c.decode(ContractVersion.self, forKey: .schemaVersion),
            taskID: try c.decode(UUID.self, forKey: .taskID),
            status: try c.decode(TaskStatus.self, forKey: .status),
            summary: try c.decode(String.self, forKey: .summary),
            data: try c.decode(Payload.self, forKey: .data),
            warnings: try c.decode([String].self, forKey: .warnings),
            errors: try c.decode([ContractError].self, forKey: .errors),
            startedAt: try c.decodeIfPresent(UTCTimestamp.self, forKey: .startedAt),
            finishedAt: try c.decode(UTCTimestamp.self, forKey: .finishedAt),
            dataClassification: try c.decode(DataClassification.self, forKey: .dataClassification),
            completeness: try c.decode(Completeness.self, forKey: .completeness),
            resultRevision: try c.decode(NonnegativeInt.self, forKey: .resultRevision),
            snapshotID: try c.decodeIfPresent(UUID.self, forKey: .snapshotID),
            measuredAt: try c.decodeIfPresent(UTCTimestamp.self, forKey: .measuredAt),
            indexGeneration: try c.decodeIfPresent(NonnegativeInt.self, forKey: .indexGeneration),
            skippedCount: try c.decodeIfPresent(NonnegativeInt.self, forKey: .skippedCount),
            cancellationTooLate: try c.decodeIfPresent(Bool.self, forKey: .cancellationTooLate) ?? false,
            stale: try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false,
            nextCursor: try c.decodeIfPresent(String.self, forKey: .nextCursor),
            artifacts: try c.decodeIfPresent([String].self, forKey: .artifacts) ?? [],
            actionReceipts: try c.decodeIfPresent([UUID].self, forKey: .actionReceipts) ?? [],
            limitations: try c.decodeIfPresent([String].self, forKey: .limitations) ?? []
        )
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(taskID, forKey: .taskID)
        try c.encode(status, forKey: .status)
        try c.encode(summary, forKey: .summary)
        try c.encode(data, forKey: .data)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(errors, forKey: .errors)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(finishedAt, forKey: .finishedAt)
        try c.encode(dataClassification, forKey: .dataClassification)
        try c.encode(completeness, forKey: .completeness)
        try c.encode(resultRevision, forKey: .resultRevision)
        try c.encodeIfPresent(snapshotID, forKey: .snapshotID)
        try c.encodeIfPresent(measuredAt, forKey: .measuredAt)
        try c.encodeIfPresent(indexGeneration, forKey: .indexGeneration)
        try c.encodeIfPresent(skippedCount, forKey: .skippedCount)
        try c.encode(cancellationTooLate, forKey: .cancellationTooLate)
        try c.encode(stale, forKey: .stale)
        try c.encodeIfPresent(nextCursor, forKey: .nextCursor)
        try c.encode(artifacts, forKey: .artifacts)
        try c.encode(actionReceipts, forKey: .actionReceipts)
        try c.encode(limitations, forKey: .limitations)
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case taskID = "taskId"
        case status
        case summary
        case data
        case warnings
        case errors
        case startedAt
        case finishedAt
        case dataClassification
        case completeness
        case resultRevision
        case snapshotID = "snapshotId"
        case measuredAt
        case indexGeneration
        case skippedCount
        case cancellationTooLate
        case stale
        case nextCursor
        case artifacts
        case actionReceipts
        case limitations
    }
    public func validate() throws {
        try schemaVersion.requireCompatible(); try ContractValidation.boundedText(summary)
        guard status.isTerminal, dataClassification.exportableInFirstVersion else { throw ContractFailure.invalidArgument }
        if let startedAt, finishedAt < startedAt { throw ContractFailure.invalidArgument }
        if status == .partial && completeness != .partial { throw ContractFailure.invalidArgument }
        if cancellationTooLate && ![TaskStatus.completed, .partial].contains(status) { throw ContractFailure.invalidArgument }
        if status == .failed && errors.isEmpty { throw ContractFailure.invalidArgument }
        try errors.forEach { try $0.validate() }
        try (warnings + artifacts + limitations).forEach { try ContractValidation.boundedText($0) }
    }
}

/// Общая wire-модель CapabilityDescriptor; межполевые условия проверяет ContractCodec.
public struct CapabilityDescriptor: EcosystemContract {
    public let implementationStatus: ImplementationStatus
    public let id: String
    public let version: ContractVersion
    public let agentID: AgentID
    public let inputSchema: String
    public let outputSchema: String
    public let mode: CapabilityMode
    public let readsContent: Bool
    public let dataClassifications: [DataClassification]
    public let supportsAsync: Bool
    public let supportsCancel: Bool
    public let maximumInputBytes: NonnegativeInt
    public let maximumPageSize: NonnegativeInt
    public let requiresGrant: Bool
    public init(implementationStatus: ImplementationStatus = .planned, id: String,
                version: ContractVersion = .current,
                agentID: AgentID,
                inputSchema: String,
                outputSchema: String,
                mode: CapabilityMode,
                readsContent: Bool,
                dataClassifications: [DataClassification],
                supportsAsync: Bool,
                supportsCancel: Bool,
                maximumInputBytes: NonnegativeInt,
                maximumPageSize: NonnegativeInt,
                requiresGrant: Bool) throws {
        self.implementationStatus = implementationStatus
        self.id = id
        self.version = version
        self.agentID = agentID
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.mode = mode
        self.readsContent = readsContent
        self.dataClassifications = dataClassifications
        self.supportsAsync = supportsAsync
        self.supportsCancel = supportsCancel
        self.maximumInputBytes = maximumInputBytes
        self.maximumPageSize = maximumPageSize
        self.requiresGrant = requiresGrant
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            implementationStatus: try c.decodeIfPresent(ImplementationStatus.self, forKey: .implementationStatus) ?? .planned,
            id: try c.decode(String.self, forKey: .id),
            version: try c.decode(ContractVersion.self, forKey: .version),
            agentID: try c.decode(AgentID.self, forKey: .agentID),
            inputSchema: try c.decode(String.self, forKey: .inputSchema),
            outputSchema: try c.decode(String.self, forKey: .outputSchema),
            mode: try c.decode(CapabilityMode.self, forKey: .mode),
            readsContent: try c.decode(Bool.self, forKey: .readsContent),
            dataClassifications: try c.decode([DataClassification].self, forKey: .dataClassifications),
            supportsAsync: try c.decode(Bool.self, forKey: .supportsAsync),
            supportsCancel: try c.decode(Bool.self, forKey: .supportsCancel),
            maximumInputBytes: try c.decode(NonnegativeInt.self, forKey: .maximumInputBytes),
            maximumPageSize: try c.decode(NonnegativeInt.self, forKey: .maximumPageSize),
            requiresGrant: try c.decode(Bool.self, forKey: .requiresGrant)
        )
    }
    private enum CodingKeys: String, CodingKey {
        case implementationStatus
        case id
        case version
        case agentID = "agentId"
        case inputSchema
        case outputSchema
        case mode
        case readsContent
        case dataClassifications
        case supportsAsync
        case supportsCancel
        case maximumInputBytes
        case maximumPageSize
        case requiresGrant
    }
    public func validate() throws {
        try version.requireCompatible(); try ContractValidation.identifier(id)
        try ContractValidation.boundedText(inputSchema); try ContractValidation.boundedText(outputSchema)
        guard maximumInputBytes.value <= ContractCodec.maximumBytes,
              (1...500).contains(maximumPageSize.value), !dataClassifications.isEmpty,
              Set(dataClassifications).count == dataClassifications.count else { throw ContractFailure.invalidArgument }
        if mode == .mutating && !requiresGrant { throw ContractFailure.invalidArgument }
    }
}

/// Общая wire-модель GrantDescriptor; межполевые условия проверяет ContractCodec.
public struct GrantDescriptor: EcosystemContract {
    public let schemaVersion: ContractVersion
    public let grantID: UUID
    public let agentID: AgentID
    public let rootIDs: [UUID]
    public let objectIDs: [UUID]
    public let capabilityIDs: [String]
    public let dataClassification: DataClassification
    public let maximumBytes: NonnegativeInt
    public let maximumObjects: NonnegativeInt
    public let periodMilliseconds: NonnegativeInt
    public let revision: NonnegativeInt
    public let issuedAt: UTCTimestamp
    public let expiresAt: UTCTimestamp
    public let revokedAt: UTCTimestamp?
    public let authorizationBasis: String
    public init(schemaVersion: ContractVersion = .current,
                grantID: UUID,
                agentID: AgentID,
                rootIDs: [UUID] = [],
                objectIDs: [UUID] = [],
                capabilityIDs: [String],
                dataClassification: DataClassification,
                maximumBytes: NonnegativeInt,
                maximumObjects: NonnegativeInt,
                periodMilliseconds: NonnegativeInt,
                revision: NonnegativeInt,
                issuedAt: UTCTimestamp,
                expiresAt: UTCTimestamp,
                revokedAt: UTCTimestamp? = nil,
                authorizationBasis: String) throws {
        self.schemaVersion = schemaVersion
        self.grantID = grantID
        self.agentID = agentID
        self.rootIDs = rootIDs
        self.objectIDs = objectIDs
        self.capabilityIDs = capabilityIDs
        self.dataClassification = dataClassification
        self.maximumBytes = maximumBytes
        self.maximumObjects = maximumObjects
        self.periodMilliseconds = periodMilliseconds
        self.revision = revision
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.authorizationBasis = authorizationBasis
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try c.decode(ContractVersion.self, forKey: .schemaVersion),
            grantID: try c.decode(UUID.self, forKey: .grantID),
            agentID: try c.decode(AgentID.self, forKey: .agentID),
            rootIDs: try c.decodeIfPresent([UUID].self, forKey: .rootIDs) ?? [],
            objectIDs: try c.decodeIfPresent([UUID].self, forKey: .objectIDs) ?? [],
            capabilityIDs: try c.decode([String].self, forKey: .capabilityIDs),
            dataClassification: try c.decode(DataClassification.self, forKey: .dataClassification),
            maximumBytes: try c.decode(NonnegativeInt.self, forKey: .maximumBytes),
            maximumObjects: try c.decode(NonnegativeInt.self, forKey: .maximumObjects),
            periodMilliseconds: try c.decode(NonnegativeInt.self, forKey: .periodMilliseconds),
            revision: try c.decode(NonnegativeInt.self, forKey: .revision),
            issuedAt: try c.decode(UTCTimestamp.self, forKey: .issuedAt),
            expiresAt: try c.decode(UTCTimestamp.self, forKey: .expiresAt),
            revokedAt: try c.decodeIfPresent(UTCTimestamp.self, forKey: .revokedAt),
            authorizationBasis: try c.decode(String.self, forKey: .authorizationBasis)
        )
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case grantID = "grantId"
        case agentID = "agentId"
        case rootIDs = "rootIds"
        case objectIDs = "objectIds"
        case capabilityIDs = "capabilityIds"
        case dataClassification
        case maximumBytes
        case maximumObjects
        case periodMilliseconds
        case revision
        case issuedAt
        case expiresAt
        case revokedAt
        case authorizationBasis
    }
    public func validate() throws {
        try schemaVersion.requireCompatible()
        guard !capabilityIDs.isEmpty, expiresAt > issuedAt,
              Set(rootIDs).count == rootIDs.count, Set(objectIDs).count == objectIDs.count,
              Set(capabilityIDs).count == capabilityIDs.count else { throw ContractFailure.invalidArgument }
        try capabilityIDs.forEach { try ContractValidation.identifier($0) }
        if let revokedAt, revokedAt < issuedAt { throw ContractFailure.invalidArgument }
        try ContractValidation.boundedText(authorizationBasis, maximum: 128)
    }
}

/// Общая wire-модель AgentEvent; межполевые условия проверяет ContractCodec.
public struct AgentEvent<Payload: Codable & Sendable>: EcosystemContract {
    public let schemaVersion: ContractVersion
    public let eventID: UUID
    public let sequence: NonnegativeInt
    public let source: AgentID
    public let detectedAt: UTCTimestamp
    public let occurredAt: UTCTimestamp?
    public let taskID: UUID?
    public let workflowID: UUID?
    public let ruleID: UUID?
    public let type: String
    public let severity: EventSeverity
    public let dataClassification: DataClassification
    public let payload: Payload
    public init(schemaVersion: ContractVersion = .current,
                eventID: UUID,
                sequence: NonnegativeInt,
                source: AgentID,
                detectedAt: UTCTimestamp,
                occurredAt: UTCTimestamp? = nil,
                taskID: UUID? = nil,
                workflowID: UUID? = nil,
                ruleID: UUID? = nil,
                type: String,
                severity: EventSeverity,
                dataClassification: DataClassification,
                payload: Payload) throws {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.sequence = sequence
        self.source = source
        self.detectedAt = detectedAt
        self.occurredAt = occurredAt
        self.taskID = taskID
        self.workflowID = workflowID
        self.ruleID = ruleID
        self.type = type
        self.severity = severity
        self.dataClassification = dataClassification
        self.payload = payload
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: try c.decode(ContractVersion.self, forKey: .schemaVersion),
            eventID: try c.decode(UUID.self, forKey: .eventID),
            sequence: try c.decode(NonnegativeInt.self, forKey: .sequence),
            source: try c.decode(AgentID.self, forKey: .source),
            detectedAt: try c.decode(UTCTimestamp.self, forKey: .detectedAt),
            occurredAt: try c.decodeIfPresent(UTCTimestamp.self, forKey: .occurredAt),
            taskID: try c.decodeIfPresent(UUID.self, forKey: .taskID),
            workflowID: try c.decodeIfPresent(UUID.self, forKey: .workflowID),
            ruleID: try c.decodeIfPresent(UUID.self, forKey: .ruleID),
            type: try c.decode(String.self, forKey: .type),
            severity: try c.decode(EventSeverity.self, forKey: .severity),
            dataClassification: try c.decode(DataClassification.self, forKey: .dataClassification),
            payload: try c.decode(Payload.self, forKey: .payload)
        )
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case eventID = "eventId"
        case sequence
        case source
        case detectedAt
        case occurredAt
        case taskID = "taskId"
        case workflowID = "workflowId"
        case ruleID = "ruleId"
        case type
        case severity
        case dataClassification
        case payload
    }
    public func validate() throws {
        try schemaVersion.requireCompatible(); try ContractValidation.identifier(type)
        guard dataClassification.exportableInFirstVersion else { throw ContractFailure.invalidArgument }
    }
}

/// Общая wire-модель PageRequest; межполевые условия проверяет ContractCodec.
public struct PageRequest: EcosystemContract {
    public let limit: Int
    public let cursor: String?
    public init(limit: Int = 100,
                cursor: String? = nil) throws {
        self.limit = limit
        self.cursor = cursor
        try validate()
    }
    public init(from decoder: Decoder) throws {
        try ContractValidation.rejectUnknownFields(decoder, allowed: Self.allowedRequestKeys ?? [])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 100,
            cursor: try c.decodeIfPresent(String.self, forKey: .cursor)
        )
    }
    private enum CodingKeys: String, CodingKey {
        case limit
        case cursor
    }
    public static var allowedRequestKeys: Set<String>? { ["limit", "cursor"] }
    public func validate() throws {
        guard (1...500).contains(limit) else { throw ContractFailure.invalidArgument }
        if let cursor { try ContractValidation.boundedText(cursor, maximum: 4096) }
    }
}

/// Общая wire-модель SnapshotCursor; межполевые условия проверяет ContractCodec.
public struct SnapshotCursor: EcosystemContract {
    public let snapshotID: UUID
    public let filterFingerprint: String
    public let offset: NonnegativeInt
    public init(snapshotID: UUID,
                filterFingerprint: String,
                offset: NonnegativeInt) throws {
        self.snapshotID = snapshotID
        self.filterFingerprint = filterFingerprint
        self.offset = offset
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            snapshotID: try c.decode(UUID.self, forKey: .snapshotID),
            filterFingerprint: try c.decode(String.self, forKey: .filterFingerprint),
            offset: try c.decode(NonnegativeInt.self, forKey: .offset)
        )
    }
    private enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshotId"
        case filterFingerprint
        case offset
    }
    public func opaqueValue() throws -> String {
        try ContractCodec.encode(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    public static func decodeOpaque(_ value: String) throws -> Self {
        guard !value.isEmpty, value.utf8.count <= 4096,
              value.range(of: "^[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil else {
            throw ContractFailure.invalidArgument
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw ContractFailure.invalidArgument }
        return try ContractCodec.decode(Self.self, from: data)
    }
    /// Cursor не выдаёт прав: runtime повторно проверяет grant/доступ к snapshot.
    public func requireContext(snapshotID: UUID, filterFingerprint: String) throws {
        guard self.snapshotID == snapshotID, self.filterFingerprint == filterFingerprint else {
            throw ContractFailure.staleSnapshot
        }
    }
    public func validate() throws {
        guard filterFingerprint.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil else {
            throw ContractFailure.invalidArgument
        }
    }
}

/// Общая wire-модель ClientCapabilityFlags; межполевые условия проверяет ContractCodec.
public struct ClientCapabilityFlags: EcosystemContract {
    public let clientID: String
    public let localMCP: SupportLevel
    public let nativeDelegation: SupportLevel
    public let namedRoles: SupportLevel
    public let toolFiltering: SupportLevel
    public let hotReload: SupportLevel
    public let headlessRunner: SupportLevel
    public let resumableSessions: SupportLevel
    public init(clientID: String,
                localMCP: SupportLevel = .unknown,
                nativeDelegation: SupportLevel = .unknown,
                namedRoles: SupportLevel = .unknown,
                toolFiltering: SupportLevel = .unknown,
                hotReload: SupportLevel = .unknown,
                headlessRunner: SupportLevel = .unknown,
                resumableSessions: SupportLevel = .unknown) throws {
        self.clientID = clientID
        self.localMCP = localMCP
        self.nativeDelegation = nativeDelegation
        self.namedRoles = namedRoles
        self.toolFiltering = toolFiltering
        self.hotReload = hotReload
        self.headlessRunner = headlessRunner
        self.resumableSessions = resumableSessions
        try validate()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            clientID: try c.decode(String.self, forKey: .clientID),
            localMCP: try c.decodeIfPresent(SupportLevel.self, forKey: .localMCP) ?? .unknown,
            nativeDelegation: try c.decodeIfPresent(SupportLevel.self, forKey: .nativeDelegation) ?? .unknown,
            namedRoles: try c.decodeIfPresent(SupportLevel.self, forKey: .namedRoles) ?? .unknown,
            toolFiltering: try c.decodeIfPresent(SupportLevel.self, forKey: .toolFiltering) ?? .unknown,
            hotReload: try c.decodeIfPresent(SupportLevel.self, forKey: .hotReload) ?? .unknown,
            headlessRunner: try c.decodeIfPresent(SupportLevel.self, forKey: .headlessRunner) ?? .unknown,
            resumableSessions: try c.decodeIfPresent(SupportLevel.self, forKey: .resumableSessions) ?? .unknown
        )
    }
    private enum CodingKeys: String, CodingKey {
        case clientID = "clientId"
        case localMCP
        case nativeDelegation
        case namedRoles
        case toolFiltering
        case hotReload
        case headlessRunner
        case resumableSessions
    }
    public func validate() throws {
        try ContractValidation.identifier(clientID)
    }
}

/// Реестр является исходным планом capabilities. В MCP публикуются только
/// implemented после интеграции runtime; planned не разрешает выполнение.
public struct CapabilityRegistry: EcosystemContract {
    public let schemaVersion: ContractVersion
    public let capabilities: [CapabilityDescriptor]
    public init(schemaVersion: ContractVersion = .current, capabilities: [CapabilityDescriptor]) throws {
        self.schemaVersion = schemaVersion; self.capabilities = capabilities
        try validate()
    }
    public func validate() throws {
        try schemaVersion.requireCompatible()
        try capabilities.forEach { try $0.validate() }
        let keys = capabilities.map { $0.agentID.rawValue + ":" + $0.id }
        guard Set(keys).count == keys.count else { throw ContractFailure.invalidArgument }
    }
}
