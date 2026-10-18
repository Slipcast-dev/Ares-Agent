import Foundation
import XCTest
@testable import EcosystemContracts

final class ContractTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "result-v1", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func editedResult(_ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func request() throws -> TaskRequest<EmptyParameters> {
        try TaskRequest(requestID: UUID(), agentID: .athena, capabilityID: "system.get_metrics",
            parameters: EmptyParameters(), origin: .externalConnection, idempotencyKey: "request-1",
            createdAt: UTCTimestamp("2026-10-15T12:00:00Z"))
    }
    func testOldV1FixtureWithoutMinorDecodesAndRoundTrips() throws {
        let result = try ContractCodec.decode(TaskResult<EmptyParameters>.self, from: fixture())
        XCTAssertEqual(result.schemaVersion, .current)
        XCTAssertEqual(result.status, .completed)
        let decoded = try ContractCodec.decode(TaskResult<EmptyParameters>.self, from: ContractCodec.encode(result))
        XCTAssertEqual(decoded.taskID, result.taskID)
        XCTAssertEqual(decoded.finishedAt.value, "2026-10-15T12:00:01Z")
    }
    func testFutureMinorAndOptionalResponseFieldsRemainCompatible() throws {
        let data = try editedResult {
            $0["schemaVersion"] = ["major": 1, "minor": 8]
            $0["futureMeasurement"] = ["quality": "estimated"]
        }
        XCTAssertEqual(try ContractCodec.decode(TaskResult<EmptyParameters>.self, from: data).schemaVersion.minor, 8)
    }
    func testMajorMismatchIsRejected() throws {
        let data = try editedResult { $0["schemaVersion"] = ["major": 2, "minor": 0] }
        XCTAssertThrowsError(try ContractCodec.decode(TaskResult<EmptyParameters>.self, from: data)) {
            XCTAssertEqual($0 as? ContractFailure, .incompatibleVersion)
        }
    }
    func testMalformedAndOversizedInputRejected() {
        for input in [Data("broken".utf8), Data("[]".utf8), Data(repeating: 32, count: 1_048_577)] {
            XCTAssertThrowsError(try ContractCodec.decode(TaskResult<EmptyParameters>.self, from: input))
        }
    }
    func testRequestRoundTripAndUnknownPrivilegeFieldsRejected() throws {
        let data = try ContractCodec.encode(request())
        XCTAssertEqual(try ContractCodec.decode(TaskRequest<EmptyParameters>.self, from: data).agentID, .athena)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["approved"] = true
        XCTAssertThrowsError(try ContractCodec.decode(TaskRequest<EmptyParameters>.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }
    func testNestedClientLabelsCannotClaimVerification() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ContractCodec.encode(request())) as? [String: Any])
        object["clientContext"] = ["clientId": "hermes-future", "verified": true]
        XCTAssertThrowsError(try ContractCodec.decode(TaskRequest<EmptyParameters>.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }
    func testFileCapabilityRequiresRootAndCorrectDomain() throws {
        XCTAssertThrowsError(try TaskRequest(requestID: UUID(), agentID: .ares, capabilityID: "file.scan",
            parameters: EmptyParameters(), origin: .user, idempotencyKey: "k",
            createdAt: UTCTimestamp("2026-10-15T12:00:00Z")))
        XCTAssertThrowsError(try TaskRequest(requestID: UUID(), agentID: .ares, capabilityID: "system.get_metrics",
            parameters: EmptyParameters(), origin: .user, idempotencyKey: "k",
            createdAt: UTCTimestamp("2026-10-15T12:00:00Z")))
    }
    func testDeadlinesAndUTCFormattingAreValidated() throws {
        for value in ["yesterday", "2026-10-15T12:00:00+03:00", "2026-13-01T12:00:00Z", "2026-02-30T12:00:00Z", "2026-10-15T12:00:00Z\n"] {
            XCTAssertThrowsError(try UTCTimestamp(value))
        }
        XCTAssertNoThrow(try UTCTimestamp("2026-10-15T12:00:00.123Z"))
        XCTAssertEqual(try UTCTimestamp("2026-10-15T12:00:00Z"), try UTCTimestamp("2026-10-15T12:00:00.000Z"))
        XCTAssertThrowsError(try TaskRequest(requestID: UUID(), agentID: .athena, capabilityID: "system.get_metrics",
            parameters: EmptyParameters(), origin: .user, idempotencyKey: "k",
            createdAt: UTCTimestamp("2026-10-15T12:00:00Z"), deadlineAt: UTCTimestamp("2026-10-15T11:59:59Z")))
    }
    func testIntegerBytesKeepPrecisionAndRejectOverflow() throws {
        let large: Int64 = 9_007_199_254_740_993
        let encoder = JSONEncoder()
        let decoded = try JSONDecoder().decode(NonnegativeInt.self, from: encoder.encode(NonnegativeInt(large)))
        XCTAssertEqual(decoded.value, large)
        for input in ["-1", "9223372036854775808", "1.5"] {
            XCTAssertThrowsError(try JSONDecoder().decode(NonnegativeInt.self, from: Data(input.utf8)))
        }
    }
    func testInvalidPercentagesAndProgressAreRejected() throws {
        for value in [Double.nan, Double.infinity, -1, 100.01] {
            XCTAssertThrowsError(try ContractValidation.percentage(value))
        }
        XCTAssertNoThrow(try ContractValidation.percentage(100))
        XCTAssertThrowsError(try TaskProgress(phase: "hashing", processed: NonnegativeInt(11), total: NonnegativeInt(10)))
    }
    func testAllTerminalStatesAreImmutableForEveryAuthority() {
        for state in TaskStatus.allCases where state.isTerminal {
            for next in TaskStatus.allCases {
                for authority in [TransitionAuthority.executor, .policy, .scheduler, .recovery] {
                    XCTAssertThrowsError(try state.requireTransition(to: next, by: authority))
                }
            }
        }
    }
    func testCancellationAndRecoveryTransitionsNeedCorrectAuthority() {
        XCTAssertNoThrow(try TaskStatus.running.requireTransition(to: .cancelling, by: .executor))
        XCTAssertThrowsError(try TaskStatus.running.requireTransition(to: .cancelled, by: .executor))
        XCTAssertNoThrow(try TaskStatus.cancelling.requireTransition(to: .cancelled, by: .executor))
        XCTAssertNoThrow(try TaskStatus.cancelling.requireTransition(to: .completed, by: .executor))
        XCTAssertThrowsError(try TaskStatus.queued.requireTransition(to: .running, by: .policy))
        XCTAssertNoThrow(try TaskStatus.running.requireTransition(to: .recoveryRequired, by: .recovery))
    }
    func testSecretAndLocalContentCannotBecomeExportedResults() throws {
        for classification in ["secret", "localContent", "contentExport"] {
            let data = try editedResult { $0["dataClassification"] = classification }
            XCTAssertThrowsError(try ContractCodec.decode(TaskResult<EmptyParameters>.self, from: data))
        }
    }
    func testPartialFailedAndStartedAtSemantics() throws {
        for change: (inout [String: Any]) -> Void in [
            { $0["status"] = "partial" }, { $0["status"] = "failed" }, { $0.removeValue(forKey: "startedAt") },
            { $0["status"] = "cancelled"; $0["cancellationTooLate"] = true }
        ] {
            XCTAssertThrowsError(try ContractCodec.decode(TaskResult<EmptyParameters>.self, from: editedResult(change)))
        }
        let nullStart = try editedResult { $0["startedAt"] = NSNull() }
        let result = try ContractCodec.decode(TaskResult<EmptyParameters>.self, from: nullStart)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: ContractCodec.encode(result)) as? [String: Any])
        XCTAssertTrue(encoded["startedAt"] is NSNull)
    }
    func testCursorRejectsDifferentSnapshotAndFilter() throws {
        let id = UUID(); let filter = String(repeating: "a", count: 64)
        let cursor = try SnapshotCursor(snapshotID: id, filterFingerprint: filter, offset: NonnegativeInt(0))
        XCTAssertNoThrow(try cursor.requireContext(snapshotID: id, filterFingerprint: filter))
        XCTAssertThrowsError(try cursor.requireContext(snapshotID: UUID(), filterFingerprint: filter))
        XCTAssertThrowsError(try cursor.requireContext(snapshotID: id, filterFingerprint: String(repeating: "b", count: 64)))
        let recovered = try SnapshotCursor.decodeOpaque(cursor.opaqueValue())
        XCTAssertEqual(recovered.snapshotID, id)
        XCTAssertThrowsError(try SnapshotCursor.decodeOpaque("../invalid"))
        XCTAssertThrowsError(try PageRequest(limit: 501))
        XCTAssertThrowsError(try PageRequest(limit: 0))
        XCTAssertEqual(try PageRequest().limit, 100)
    }
    func testFutureClientAndErrorCodesArePreservedWithoutSwitches() throws {
        let flags = try ClientCapabilityFlags(clientID: "hermes-future")
        XCTAssertEqual(flags.localMCP, .unknown)
        XCTAssertEqual(flags.nativeDelegation, .unknown)
        let error = try ContractError(code: "FUTURE_ERROR", scope: .transport,
            message: "Соединение недоступно", retryable: false, correlationID: UUID())
        XCTAssertEqual(try ContractCodec.decode(ContractError.self, from: ContractCodec.encode(error)).code, "FUTURE_ERROR")
        XCTAssertEqual(KnownErrorCode.allCases.count, 19)
    }
    func testGrantRejectsDuplicatesAndInvalidExpiry() throws {
        let now = try UTCTimestamp("2026-10-15T12:00:00Z")
        XCTAssertThrowsError(try GrantDescriptor(grantID: UUID(), agentID: .ares,
            capabilityIDs: ["file.scan", "file.scan"], dataClassification: .fileMetadata,
            maximumBytes: NonnegativeInt(100), maximumObjects: NonnegativeInt(10),
            periodMilliseconds: NonnegativeInt(1000), revision: NonnegativeInt(0),
            issuedAt: now, expiresAt: now, authorizationBasis: "user-interface"))
    }
    func testBundledRolesAndRegistryAreAvailableWithoutClientInstallation() throws {
        for name in ["ares", "athena", "coordinator"] {
            let data = try ContractResources.data(relativePath: "Roles/" + name + ".json")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(object["enabledByDefault"] as? Bool, false)
            XCTAssertTrue(object["modelOverride"] is NSNull)
        }
        let registry = try ContractCodec.decode(CapabilityRegistry.self,
            from: ContractResources.data(relativePath: "capability-registry.json"))
        XCTAssertFalse(registry.capabilities.isEmpty)
        XCTAssertTrue(registry.capabilities.allSatisfy { $0.implementationStatus == .planned })
        XCTAssertFalse(try ContractResources.data(relativePath: "Schemas/contracts.schema.json").isEmpty)
        XCTAssertThrowsError(try ContractResources.data(relativePath: "../../outside"))
    }
    func testAllContractSamplesExportForIndependentSchemaValidation() throws {
        let now = try UTCTimestamp("2026-10-15T12:00:00Z")
        let later = try UTCTimestamp("2026-10-15T12:01:00Z")
        let zero = try NonnegativeInt(0)
        let capability = try CapabilityDescriptor(id: "system.get_metrics", agentID: .athena,
            inputSchema: "urn:ecosystem:contracts:1#/$defs/TaskRequest",
            outputSchema: "urn:ecosystem:contracts:1#/$defs/TaskResult", mode: .readOnly,
            readsContent: false, dataClassifications: [.aggregate], supportsAsync: false,
            supportsCancel: false, maximumInputBytes: NonnegativeInt(1_048_576),
            maximumPageSize: NonnegativeInt(500), requiresGrant: false)
        XCTAssertThrowsError(try CapabilityDescriptor(id: "rule.run", agentID: .ares,
            inputSchema: "input", outputSchema: "output", mode: .mutating, readsContent: false,
            dataClassifications: [.fileMetadata], supportsAsync: true, supportsCancel: true,
            maximumInputBytes: NonnegativeInt(100), maximumPageSize: NonnegativeInt(100), requiresGrant: false))
        let grant = try GrantDescriptor(grantID: UUID(), agentID: .ares, rootIDs: [UUID()],
            capabilityIDs: ["file.scan"], dataClassification: .fileMetadata,
            maximumBytes: NonnegativeInt(100), maximumObjects: NonnegativeInt(10),
            periodMilliseconds: NonnegativeInt(1000), revision: zero, issuedAt: now,
            expiresAt: later, authorizationBasis: "local-user-interface")
        let samples: [String: Data] = [
            "ClientContext": try ContractCodec.encode(ClientContext(clientID: "hermes-future")),
            "TaskProgress": try ContractCodec.encode(TaskProgress(phase: "queued", processed: zero)),
            "TaskRequest": try ContractCodec.encode(request()),
            "TaskRecord": try ContractCodec.encode(TaskRecord(taskID: UUID(), request: request(), status: .queued, revision: zero)),
            "ContractError": try ContractCodec.encode(ContractError(code: "CLIENT_UNAVAILABLE", scope: .transport,
                message: "Откройте приложение", retryable: false, correlationID: UUID())),
            "TaskResult": try ContractCodec.encode(ContractCodec.decode(TaskResult<EmptyParameters>.self, from: fixture())),
            "CapabilityDescriptor": try ContractCodec.encode(capability),
            "GrantDescriptor": try ContractCodec.encode(grant),
            "AgentEvent": try ContractCodec.encode(AgentEvent(eventID: UUID(), sequence: zero, source: .athena,
                detectedAt: now, type: "metrics.measured", severity: .info, dataClassification: .aggregate, payload: EmptyParameters())),
            "PageRequest": try ContractCodec.encode(PageRequest()),
            "SnapshotCursor": try ContractCodec.encode(SnapshotCursor(snapshotID: UUID(), filterFingerprint: String(repeating: "a", count: 64), offset: zero)),
            "ClientCapabilityFlags": try ContractCodec.encode(ClientCapabilityFlags(clientID: "hermes-future"))
        ]
        // Необязательный экспорт только синтетических фикстур для независимого
        // JSON Schema validator. Обычный swift test ничего не пишет в workspace.
        if let directory = ProcessInfo.processInfo.environment["ECOSYSTEM_CONTRACT_FIXTURE_OUTPUT"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, data) in samples {
                try data.write(to: url.appendingPathComponent(name + ".json"), options: .atomic)
            }
        }
        XCTAssertEqual(samples.count, 12)
    }

}
