import Foundation
@preconcurrency import SQLite3
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import FileOrganizerCore

final class QueuedAresTests: XCTestCase {
    private func finish(_ queue: DurableTaskQueue, _ id: UUID) async throws -> DurableTask {
        for _ in 0..<100 {
            if let value = try await queue.task(id), value.status.isTerminal { return value }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw LocalRuntimeFailure.deadlineExceeded
    }
    func testInvalidLocalClientNeverFallsBackToOpeningDatabase() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/e3b-failclosed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let database = base.appendingPathComponent("must-not-exist.sqlite")
        let container = AppContainer(databaseURL: database, localClientOverride: .failure(LocalRuntimeFailure.invalidConfiguration))
        XCTAssertTrue(container.isLocalRuntimeClient)
        XCTAssertThrowsError(try container.preparePersistentStore())
        do { _ = try await container.fileRepository.fetchRoots(); XCTFail("Unexpected direct repository fallback") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .invalidConfiguration) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }
    func testRevocationRollsBackIfDependentRuleUpdateFails() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/e3b-revoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let database = base.appendingPathComponent("domain.sqlite")
        let container = AppContainer(databaseURL: database, allowLocalClient: false)
        try container.preparePersistentStore()
        let folder = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = try await container.authorizedRootAccess.addRoot(from: folder)
        var rule = AutomationRule(); rule.rootID = root.id; rule.enabled = true
        try await container.fileRepository.saveRuleObject(rule, id: rule.id.uuidString, table: .rules)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        guard let handle else { return XCTFail("No fixture database") }
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TRIGGER fixture_reject BEFORE UPDATE ON automation_rules BEGIN SELECT RAISE(ABORT, 'fixture'); END", nil, nil, nil), SQLITE_OK)
        do { try await container.fileRepository.removeRoot(withID: root.id); XCTFail("Expected rule update failure") }
        catch { }
        let saved = try await container.fileRepository.root(withID: root.id); XCTAssertNotNil(saved)
        let kept = try await container.fileRepository.ruleObject(AutomationRule.self, id: rule.id.uuidString, table: .rules)
        XCTAssertEqual(kept?.enabled, true)
    }

    func testScanIsPersistentIdempotentAndRepeatableThroughRuntime() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/e3b-ares-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("same".utf8).write(to: folder.appendingPathComponent("b.txt"))
        let container = AppContainer(databaseURL: base.appendingPathComponent("domain.sqlite"), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: folder)
        let queue = try DurableTaskQueue(directory: base.appendingPathComponent("queue"), agentID: .ares)
        let work = try AresQueuedWork(queue: queue, repository: container.fileRepository, access: container.authorizedRootAccess, rules: container.ruleCoordinator)
        let request = AresSubmission(capability: "file.scan", job: AresJob(rootID: root.id), key: "same-scan")
        let first = try await work.submit(request, role: .gui)
        let result = try await finish(queue, first.id)
        XCTAssertEqual(result.status.rawValue, "completed")
        let summary = try LocalWire.decode(ScanSummary.self, XCTUnwrap(result.result))
        XCTAssertEqual(summary.indexedFileCount, 2); XCTAssertEqual(summary.totalByteSize, 8)
        let repeated = try await work.submit(request, role: .gui); XCTAssertEqual(first.id, repeated.id)
        let next = try await work.submit(AresSubmission(capability: "file.scan", job: AresJob(rootID: root.id), key: "next-scan"), role: .gui)
        let completed = try await finish(queue, next.id); XCTAssertEqual(completed.status.rawValue, "completed")
        let duplicate = try await work.submit(AresSubmission(capability: "file.compute_duplicates", job: AresJob(rootID: root.id), key: "duplicates"), role: .gui)
        let detected = try await finish(queue, duplicate.id)
        XCTAssertEqual(detected.status.rawValue, "completed")
        let analysis = try LocalWire.decode(DuplicateAnalysis.self, XCTUnwrap(detected.result))
        XCTAssertEqual(analysis.groups.count, 1)
        do { _ = try await work.authorizedTask(first.id, role: .mcp); XCTFail("Task ACL bypass") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
    }
    func testRuleCopyHasDurableReceiptAndRevocationStopsQueuedWork() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/e3b-rules-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source"), destination = base.appendingPathComponent("destination")
        for folder in [source, destination] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("unchanged source".utf8).write(to: source.appendingPathComponent("sample.txt"))
        let container = AppContainer(databaseURL: base.appendingPathComponent("domain.sqlite"), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: source)
        let target = try await container.authorizedRootAccess.addRoot(from: destination)
        let queue = try DurableTaskQueue(directory: base.appendingPathComponent("queue"), agentID: .ares)
        let work = try AresQueuedWork(queue: queue, repository: container.fileRepository, access: container.authorizedRootAccess, rules: container.ruleCoordinator)
        let service = AresRuntimeService(container: container, work: work)
        var action = RuleAction(kind: .copy); action.destinationRootID = target.id
        var rule = AutomationRule(); rule.rootID = root.id; rule.actions = [action]; rule.conditions.extensions = ["txt"]
        if let path = ProcessInfo.processInfo.environment["ECOSYSTEM_ARES_RULE_FIXTURE_OUTPUT"] {
            try LocalWire.encode(rule).write(to: URL(fileURLWithPath: path))
        }
        _ = try await work.governance.save(rule, fromMCP: false)
        let plan = try await work.governance.prepare(rule.id, kind: "run")
        _ = try await work.governance.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
        let request = AresSubmission(capability: "rule.run", job: AresJob(ruleID: rule.id, planID: plan.id), key: "copy")
        let value = try await work.submit(request, role: .gui)
        let completed = try await finish(queue, value.id); XCTAssertEqual(completed.status.rawValue, "completed")
        let receipts = try await queue.receipts(value.id)
        XCTAssertEqual(receipts.count, 1); XCTAssertEqual(receipts.first?.state.rawValue, "done")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("sample.txt")), "unchanged source")
        let nextPlan = try await work.governance.prepare(rule.id, kind: "run")
        _ = try await work.governance.approve(nextPlan.id, fingerprint: nextPlan.fingerprint, role: .gui)
        let next = try await work.submit(AresSubmission(capability: "rule.run", job: AresJob(ruleID: rule.id, planID: nextPlan.id), key: "cancel-by-revoke"), role: .gui)
        let payload = try LocalWire.encode(RepositoryPayload(id: root.id))
        _ = try await service.handle(role: .gui, request: LocalRPCRequest(domain: "ares", operation: "repo.removeRoot", payload: payload))
        let stopped = try await finish(queue, next.id)
        XCTAssertTrue(["cancelled", "failed"].contains(stopped.status.rawValue))
        let removed = try await container.fileRepository.root(withID: root.id); XCTAssertNil(removed)
    }
}
