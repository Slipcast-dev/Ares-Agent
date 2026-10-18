@preconcurrency import SQLite3
import EcosystemContracts
import Foundation
import XCTest
@testable import EcosystemRuntimeSupport

/// Управляемое время делает lease/deadline проверки воспроизводимыми и быстрыми.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; time.addTimeInterval(seconds) }
}
private struct Parameters: Codable, Sendable { let value: Int }
private enum InjectedFailure: Error { case crash }

private struct StaleDomainFailure: QueueDomainError { let knownCode: KnownErrorCode = .staleSnapshot }

final class QueueTests: XCTestCase {
    /// Типизированная ошибка домена переживает сохранение и чтение очереди.
    func testDomainErrorCodeSurvivesExecutorFinalization() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let executor = try DurableTaskExecutor(queue: queue, operations: ["file.scan": RegisteredQueueOperation(mutating: false) { _, _ in
            throw StaleDomainFailure()
        }])
        let task = try await executor.submit(submission("stale"))
        let result = try await executor.waitForTerminal(task.id)
        XCTAssertEqual(result.status, .failed); XCTAssertEqual(result.errorCode, .staleSnapshot)
        let persisted = try await queue.task(task.id)
        XCTAssertEqual(persisted?.errorCode, .staleSnapshot)
    }

    private func directory() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("e3-" + UUID().uuidString)
    }
    private func submission(_ key: String, value: Int = 1, resource: String = "root.test",
                            agent: AgentID = .ares, mutating: Bool = false, deadline: String? = nil) throws -> QueueSubmission {
        let request = try TaskRequest(requestID: UUID(), agentID: agent,
            capabilityID: agent == .ares ? "file.scan" : "system.get_metrics", parameters: Parameters(value: value),
            origin: .user, idempotencyKey: key, rootID: agent == .ares ? UUID(uuidString: "00000000-0000-0000-0000-000000000001") : nil,
            createdAt: UTCTimestamp("2026-10-15T12:00:00Z"), deadlineAt: deadline.map { try UTCTimestamp($0) })
        return try QueueSubmission(request: request, resources: [resource], mutating: mutating)
    }
    private func expect(_ expected: QueueFailure, _ operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Ожидался отказ \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? QueueFailure, expected, file: file, line: line) }
    }

    func testHistoryPagesPreserveOrderAndRejectNegativeOffset() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        var ids: [UUID] = []
        for index in 0..<5 {
            let task = try await queue.accept(submission("history-" + String(index)))
            ids.append(task.id); let lease = try await queue.claim(task.id)
            _ = try await queue.finish(lease, status: .completed, result: Data())
        }
        let first = try await queue.tasks(limit: 2), second = try await queue.tasks(limit: 2, offset: 2), third = try await queue.tasks(limit: 2, offset: 4)
        XCTAssertEqual((first + second + third).map(\.id), ids.reversed())
        await expect(.invalidArgument) { _ = try await queue.tasks(limit: 2, offset: -1) }
    }

    func testOwnerReleasedAndStoredDomainCannotBeChanged() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        var queue: DurableTaskQueue? = try DurableTaskQueue(directory: path, agentID: .ares)
        XCTAssertNotNil(queue)
        XCTAssertThrowsError(try DurableTaskQueue(directory: path, agentID: .ares)) {
            XCTAssertEqual($0 as? QueueFailure, .ownerBusy)
        }
        XCTAssertNotNil(queue) // Владелец должен оставаться жив до второй попытки.
        queue = nil
        XCTAssertThrowsError(try DurableTaskQueue(directory: path, agentID: .athena)) {
            XCTAssertEqual($0 as? QueueFailure, .wrongDomain)
        }
        XCTAssertNoThrow(try DurableTaskQueue(directory: path, agentID: .ares))
    }
    func testRepeatedIdempotencyReturnsSameTaskButChangedParametersConflict() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let first = try await queue.accept(submission("same"))
        let second = try await queue.accept(submission("same"))
        XCTAssertEqual(first.id, second.id)
        await expect(.idempotencyConflict) { _ = try await queue.accept(self.submission("same", value: 2)) }
        let tasks = try await queue.tasks(); XCTAssertEqual(tasks.count, 1)
    }
    func testConcurrentAdmissionCreatesOnlyOneTaskAndResourceConflictRollsBack() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let request = try submission("same")
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<20 { group.addTask { try await queue.accept(request).id } }
            var ids: [UUID] = []; for try await id in group { ids.append(id) }; return ids
        }
        XCTAssertEqual(Set(ids).count, 1)
        await expect(.resourceBusy) { _ = try await queue.accept(self.submission("different")) }
        let tasks = try await queue.tasks(); XCTAssertEqual(tasks.count, 1)
    }
    func testCompletionAllowsSecondScanAndKeepsCommittedResultAfterRestart() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        var queue: DurableTaskQueue? = try DurableTaskQueue(directory: path, agentID: .ares)
        let first = try await queue!.accept(submission("one"))
        let token = try await queue!.claim(first.id)
        _ = try await queue!.finish(token, status: .completed, result: Data("result".utf8))
        let next = try await queue!.accept(submission("two")); XCTAssertNotEqual(first.id, next.id)
        queue = nil
        queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let stored = try await queue!.task(first.id)
        XCTAssertEqual(stored?.status, .completed); XCTAssertEqual(stored?.result, Data("result".utf8))
    }
    func testQueuedCancellationReleasesResourcesButRunningWaitsForActualStop() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let first = try await queue.accept(submission("one"))
        let queuedCancelled = try await queue.requestCancellation(first.id); XCTAssertEqual(queuedCancelled.status, .cancelled)
        let second = try await queue.accept(submission("two")); let token = try await queue.claim(second.id)
        let cancelling = try await queue.requestCancellation(second.id); XCTAssertEqual(cancelling.status, .cancelling)
        await expect(.resourceBusy) { _ = try await queue.accept(self.submission("three")) }
        await expect(.cancelled) { try await queue.checkpoint(token) }
        _ = try await queue.finish(token, status: .cancelled, errorCode: .cancelled)
        _ = try await queue.accept(submission("three"))
    }
    func testLeaseExpiryFencesOldWriterAndNewAttemptHasHigherToken() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let clock = TestClock()
        let queue = try DurableTaskQueue(directory: path, agentID: .ares, clock: { clock.now() })
        let first = try await queue.accept(submission("one")); let token = try await queue.claim(first.id, leaseSeconds: 2)
        clock.advance(3); try await queue.recoverExpiredLeases()
        await expect(.staleLease) { _ = try await queue.finish(token, status: .completed, result: Data()) }
        let original = try await queue.task(first.id); XCTAssertEqual(original?.status, .interrupted)
        let retry = try await queue.accept(submission("retry"), retrying: first.id)
        XCTAssertEqual(retry.parentAttemptID, first.id)
        let next = try await queue.claim(retry.id); XCTAssertGreaterThan(next.fencingToken, token.fencingToken)
    }
    func testHeartbeatCannotResurrectExpiredLeaseAndProgressCannotGoBackwards() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let clock = TestClock()
        let queue = try DurableTaskQueue(directory: path, agentID: .ares, clock: { clock.now() })
        let first = try await queue.accept(submission("one")); let token = try await queue.claim(first.id, leaseSeconds: 2)
        clock.advance(1); let renewed = try await queue.heartbeat(token, leaseSeconds: 4)
        XCTAssertGreaterThan(renewed.expiresAt, token.expiresAt)
        try await queue.reportProgress(renewed, progress: TaskProgress(phase: "scan", processed: NonnegativeInt(2)))
        await expect(.invalidArgument) {
            try await queue.reportProgress(renewed, progress: TaskProgress(phase: "scan", processed: NonnegativeInt(1)))
        }
        clock.advance(5)
        await expect(.staleLease) { _ = try await queue.heartbeat(renewed) }
    }
    func testMutationWithUnfinishedReceiptIsQuarantinedAndNotRepeated() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        var queue: DurableTaskQueue? = try DurableTaskQueue(directory: path, agentID: .ares)
        let first = try await queue!.accept(submission("one", mutating: true)); let token = try await queue!.claim(first.id)
        let receipt = try await queue!.beginReceipt(token, actionKey: "copy.test")
        queue = nil; queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let recovered = try await queue!.task(first.id); XCTAssertEqual(recovered?.status, .recoveryRequired)
        let active = queue!
        await expect(.resourceBusy) { _ = try await active.accept(self.submission("two", mutating: true)) }
        await expect(.recoveryRequired) { _ = try await active.reconcile(first.id, resolutions: [:]) }
        let result = try await active.reconcile(first.id, resolutions: [receipt.id:
            ReceiptResolution(state: .confirmedNoEffect, evidence: Data("checked absent".utf8))])
        XCTAssertEqual(result.status, .recoveryRequired); XCTAssertNotNil(result.reconciledAt)
        _ = try await active.accept(submission("two", mutating: true))
    }
    func testDoneReceiptBeforeResultStillRequiresRecovery() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        var queue: DurableTaskQueue? = try DurableTaskQueue(directory: path, agentID: .ares)
        let first = try await queue!.accept(submission("one", mutating: true)); let token = try await queue!.claim(first.id)
        let receipt = try await queue!.beginReceipt(token, actionKey: "copy.test")
        try await queue!.completeReceipt(token, receiptID: receipt.id, evidence: Data("verified".utf8))
        queue = nil; queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let result = try await queue!.task(first.id); XCTAssertEqual(result?.status, .recoveryRequired)
        let active = queue!
        await expect(.resourceBusy) { _ = try await active.accept(self.submission("two")) }
    }
    func testNoReceiptOnReadOnlyAndNoDuplicateActionKey() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let first = try await queue.accept(submission("read")); let readLease = try await queue.claim(first.id)
        await expect(.invalidState) { _ = try await queue.beginReceipt(readLease, actionKey: "copy.test") }
        _ = try await queue.finish(readLease, status: .completed, result: Data())
        let second = try await queue.accept(submission("write", mutating: true)); let token = try await queue.claim(second.id)
        _ = try await queue.beginReceipt(token, actionKey: "copy.test")
        await expect(.receiptAlreadyExists) { _ = try await queue.beginReceipt(token, actionKey: "copy.test") }
        let outcome = try await queue.finish(token, status: .completed, result: Data())
        XCTAssertEqual(outcome.status, .recoveryRequired)
    }
    func testAdmissionRollbackLeavesNoTaskOrLock() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        var queue: DurableTaskQueue? = try DurableTaskQueue(directory: path, agentID: .ares, fault: { point in
            if point == .beforeAdmissionCommit { throw InjectedFailure.crash }
        })
        do { _ = try await queue!.accept(submission("one")); XCTFail("Fault must interrupt") }
        catch { XCTAssertTrue(error is InjectedFailure) }
        let empty = try await queue!.tasks(); XCTAssertTrue(empty.isEmpty)
        queue = nil; queue = try DurableTaskQueue(directory: path, agentID: .ares)
        _ = try await queue!.accept(submission("one"))
    }
    func testQueuedDeadlineExpiresAndDomainQueuesStayIndependent() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        let ares = try DurableTaskQueue(directory: root.appendingPathComponent("ares"), agentID: .ares, clock: { clock.now() })
        let athena = try DurableTaskQueue(directory: root.appendingPathComponent("athena"), agentID: .athena, clock: { clock.now() })
        let formatter = ISO8601DateFormatter()
        let deadline = formatter.string(from: clock.now().addingTimeInterval(2))
        let task = try await ares.accept(submission("one", deadline: deadline))
        clock.advance(3); let next = try await ares.nextQueuedTask(); XCTAssertNil(next)
        let expired = try await ares.task(task.id); XCTAssertEqual(expired?.errorCode, .deadlineExceeded)
        _ = try await ares.accept(submission("two"))
        let other = try await athena.accept(submission("one", agent: .athena)); let lease = try await athena.claim(other.id)
        _ = try await athena.finish(lease, status: .completed, result: Data())
        await expect(.wrongDomain) { _ = try await athena.accept(self.submission("wrong")) }
    }
    func testCapacityAndLateCancellationReportActualOutcome() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let one = try await queue.accept(submission("one", resource: "root.one"))
        let two = try await queue.accept(submission("two", resource: "root.two"))
        let token = try await queue.claim(one.id)
        await expect(.capacityReached) { _ = try await queue.claim(two.id) }
        _ = try await queue.requestCancellation(one.id)
        let finished = try await queue.finish(token, status: .completed, result: Data())
        XCTAssertEqual(finished.status, .completed); XCTAssertTrue(finished.cancellationTooLate)
        let again = try await queue.requestCancellation(one.id); XCTAssertEqual(again.revision, finished.revision)
        _ = try await queue.claim(two.id)
    }
    func testSymlinkDatabaseRejectedWithoutChangingTarget() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = path.appendingPathComponent("unrelated.txt")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: path.appendingPathComponent("tasks-v1.sqlite3"), withDestinationURL: target)
        XCTAssertThrowsError(try DurableTaskQueue(directory: path, agentID: .ares))
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
    }
    func testExecutorRunsPersistentJobsAndSchedulesNextAfterCompletion() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let executor = try DurableTaskExecutor(queue: queue, operations: ["file.scan":
            RegisteredQueueOperation(mutating: false) { _, context in
                try await Task.sleep(nanoseconds: 50_000_000)
                try await context.progress(TaskProgress(phase: "scan", processed: NonnegativeInt(1)))
                return Data("{}".utf8)
            }])
        let first = try await executor.submit(submission("one", resource: "root.one"))
        let second = try await executor.submit(submission("two", resource: "root.two"))
        let completed = try await executor.waitForTerminal(first.id)
        let next = try await executor.waitForTerminal(second.id)
        XCTAssertEqual(completed.status, .completed); XCTAssertEqual(next.status, .completed)
        let repeated = try await executor.submit(submission("one", resource: "root.one"))
        XCTAssertEqual(repeated.id, first.id)
        let failures = await executor.failures(); XCTAssertTrue(failures.isEmpty)
    }
    func testBoundedDrainDoesNotReleaseQuarantineOfNonCooperativeCallback() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let clock = TestClock(), gate = PhysicalGate()
        let queue = try DurableTaskQueue(directory: path, agentID: .ares, clock: { clock.now() })
        let executor = try DurableTaskExecutor(queue: queue, operations: ["file.scan": RegisteredQueueOperation(mutating: true) { _, context in
            try await context.recordedAction(key: "test.pending") { await gate.waitFirst(); return Data("synthetic callback returned".utf8) }
        }])
        let task = try await executor.submit(submission("pending", resource: "root.one", mutating: true))
        for _ in 0..<100 { if await gate.entered == 1 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let drained = try await executor.drain(timeoutSeconds: 0.02); XCTAssertFalse(drained)
        clock.advance(31); try await queue.recoverExpiredLeases()
        let stored = try await queue.task(task.id); XCTAssertEqual(stored?.status, .recoveryRequired)
        let locked = try await queue.hasReservation("root.one"); XCTAssertTrue(locked)
        await expect(.resourceBusy) { _ = try await executor.reconcile(task.id, resolutions: [:]) }
        await gate.release()
        for _ in 0..<100 { if await executor.canReconcile(task.id) { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        let physicallyStopped = await executor.canReconcile(task.id); XCTAssertTrue(physicallyStopped)
        let stillLocked = try await queue.hasReservation("root.one"); XCTAssertTrue(stillLocked)
    }

    func testShutdownDrainsPhysicalCallbackPreservesQueuedTaskAndRejectsNewWork() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let executor = try DurableTaskExecutor(queue: queue, operations: ["file.scan": RegisteredQueueOperation(mutating: false) { _, context in
            while true { try await context.checkpoint(); try await Task.sleep(nanoseconds: 1_000_000) }
        }])
        let running = try await executor.submit(submission("running", resource: "root.one"))
        let queued = try await executor.submit(submission("queued", resource: "root.two"))
        let drained = try await executor.drain(timeoutSeconds: 1); XCTAssertTrue(drained)
        let first = try await queue.task(running.id), second = try await queue.task(queued.id)
        XCTAssertEqual(first?.status, .cancelled); XCTAssertEqual(second?.status, .queued)
        do { _ = try await executor.submit(submission("new", resource: "root.three")); XCTFail("Shutdown must reject admissions") } catch {}
    }

    func testExecutorCancelsPhysicalTaskAtDeadline() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let executor = try DurableTaskExecutor(queue: queue, operations: ["file.scan":
            RegisteredQueueOperation(mutating: false) { _, _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return Data("{}".utf8)
            }])
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let request = try TaskRequest(requestID: UUID(), agentID: .ares, capabilityID: "file.scan", parameters: Parameters(value: 1), origin: .user,
            idempotencyKey: "deadline-live", rootID: UUID(), createdAt: UTCTimestamp(formatter.string(from: Date())),
            deadlineAt: UTCTimestamp(formatter.string(from: Date().addingTimeInterval(0.15))))
        let value = try await executor.submit(QueueSubmission(request: request, resources: ["root.deadline"], mutating: false))
        let result = try await executor.waitForTerminal(value.id, timeoutSeconds: 2)
        XCTAssertEqual(result.status, .failed); XCTAssertEqual(result.errorCode, .deadlineExceeded)
        let reserved = try await queue.hasReservation("root.deadline"); XCTAssertFalse(reserved)
    }

    func testExpiredLeaseDoesNotReusePhysicalSlotBeforeCallbackReturns() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let clock = TestClock(), gate = PhysicalGate()
        let queue = try DurableTaskQueue(directory: path, agentID: .ares, clock: { clock.now() })
        let executor = try DurableTaskExecutor(queue: queue, operations: ["file.scan": RegisteredQueueOperation(mutating: false) { _, context in
            await gate.waitFirst(); try await context.checkpoint(); return Data("{}".utf8)
        }])
        let first = try await executor.submit(submission("first", resource: "root.first"))
        for _ in 0..<100 { if await gate.entered == 1 { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        clock.advance(31); try await queue.recoverExpiredLeases()
        let canReconcile = await executor.canReconcile(first.id); XCTAssertFalse(canReconcile)
        await expect(.resourceBusy) { _ = try await executor.reconcile(first.id, resolutions: [:]) }
        let second = try await executor.submit(submission("second", resource: "root.second"))
        let entered = await gate.entered; XCTAssertEqual(entered, 1)
        let pending = try await queue.task(second.id); XCTAssertEqual(pending?.status, .queued)
        await gate.release()
        let done = try await executor.waitForTerminal(second.id); XCTAssertEqual(done.status, .completed)
        let previous = try await queue.task(first.id); XCTAssertEqual(previous?.status, .interrupted)
    }
    func testRetentionDeletesOnlyOldCompletedReadingAndPreservesMutations() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let clock = TestClock()
        let queue = try DurableTaskQueue(directory: path, agentID: .ares, clock: { clock.now() })
        let read = try await queue.accept(submission("reading", resource: "root.read"))
        let readLease = try await queue.claim(read.id)
        _ = try await queue.finish(readLease, status: .completed, result: Data("{}".utf8))
        let mutation = try await queue.accept(submission("mutation", resource: "root.change", mutating: true))
        let lease = try await queue.claim(mutation.id)
        let receipt = try await queue.beginReceipt(lease, actionKey: "effect.one")
        try await queue.completeReceipt(lease, receiptID: receipt.id, evidence: Data("proved".utf8))
        _ = try await queue.finish(lease, status: .completed, result: Data("{}".utf8))
        clock.advance(91 * 86_400)
        let purged = try await queue.purgeExpiredReadHistory(); XCTAssertEqual(purged, 1)
        let removed = try await queue.task(read.id); XCTAssertNil(removed)
        let preserved = try await queue.task(mutation.id); XCTAssertEqual(preserved?.status, .completed)
        let same = try await queue.accept(submission("mutation", resource: "root.change", mutating: true)); XCTAssertEqual(same.id, mutation.id)
        let receipts = try await queue.receipts(mutation.id); XCTAssertEqual(receipts.count, 1)
    }
    func testPendingAdmissionBoundDoesNotDeleteExistingTasks() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .athena)
        for index in 0..<256 { _ = try await queue.accept(submission("key.\(index)", resource: "resource.\(index)", agent: .athena)) }
        await expect(.capacityReached) { _ = try await queue.accept(self.submission("overflow", resource: "new.resource", agent: .athena)) }
        let values = try await queue.tasks(limit: 500); XCTAssertEqual(values.count, 256)
    }
    func testSQLiteFullRollsBackWithoutFillingPhysicalDisk() throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = try QueueDatabase(directory: path)
        try database.query("PRAGMA max_page_count=2")
        try database.query("CREATE TABLE fixture(payload BLOB)")
        XCTAssertThrowsError(try database.transaction {
            try database.query("INSERT INTO fixture VALUES (?)", [.blob(Data(repeating: 1, count: 32_768))])
        }) { XCTAssertEqual($0 as? QueueFailure, .storageFull) }
        let count = try database.query("SELECT COUNT(*) AS count FROM fixture").first?.integer("count")
        XCTAssertEqual(count, 0)
    }

    func testOversizedCallbackResultFailsAndReleasesResource() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let executor = try DurableTaskExecutor(queue: queue, operations: ["file.scan":
            RegisteredQueueOperation(mutating: false) { _, _ in
                Data(repeating: 1, count: ContractCodec.maximumBytes + 1)
            }])
        let task = try await executor.submit(submission("too-large"))
        let result = try await executor.waitForTerminal(task.id, timeoutSeconds: 0.5)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.errorCode, .internalError)
        XCTAssertNil(result.result)
        _ = try await queue.accept(submission("next"))
    }
    func testExecutorCancellationStopsCooperativeCallback() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let executor = try DurableTaskExecutor(queue: queue, operations: ["file.scan":
            RegisteredQueueOperation(mutating: false) { _, context in
                while true { try await context.checkpoint(); try await Task.sleep(nanoseconds: 10_000_000) }
            }])
        let task = try await executor.submit(submission("one"))
        try await executor.cancel(task.id)
        let stopped = try await executor.waitForTerminal(task.id)
        XCTAssertEqual(stopped.status, .cancelled)
        _ = try await queue.accept(submission("two"))
    }
    func testExecutorCallbackFailureAfterReceiptRequiresRecovery() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let executor = try DurableTaskExecutor(queue: queue, operations: ["file.scan":
            RegisteredQueueOperation(mutating: true) { _, context in
                try await context.recordedAction(key: "copy.test") { throw InjectedFailure.crash }
            }])
        let task = try await executor.submit(submission("one", mutating: true))
        let result = try await executor.waitForTerminal(task.id)
        XCTAssertEqual(result.status, .recoveryRequired)
        await expect(.resourceBusy) { _ = try await queue.accept(self.submission("two")) }
    }

    func testEmbeddedNULIdempotencyKeysDoNotCollapse() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let first = try await queue.accept(submission("same\u{0000}one"))
        _ = try await queue.requestCancellation(first.id)
        let second = try await queue.accept(submission("same\u{0000}two"))
        XCTAssertNotEqual(first.id, second.id)
        let repeated = try await queue.accept(submission("same\u{0000}one"))
        XCTAssertEqual(repeated.id, first.id)
    }
    func testReceiptPagesRemainBoundedAndCompletedHistoryDoesNotHidePendingAction() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .ares)
        let task = try await queue.accept(submission("one", mutating: true)); let lease = try await queue.claim(task.id)
        for index in 0..<101 {
            let receipt = try await queue.beginReceipt(lease, actionKey: "copy.\(index)")
            try await queue.completeReceipt(lease, receiptID: receipt.id, evidence: Data("verified".utf8))
        }
        let first = try await queue.receipts(task.id)
        let second = try await queue.receipts(task.id, offset: 100)
        XCTAssertEqual(first.count, 100); XCTAssertEqual(second.count, 1)
        _ = try await queue.beginReceipt(lease, actionKey: "pending")
        let result = try await queue.finish(lease, status: .completed, result: Data())
        XCTAssertEqual(result.status, .recoveryRequired)
    }
    func testSuccessfulCallbackAfterDeadlineIsNotPublishedAsTimelySuccess() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let clock = TestClock(); let formatter = ISO8601DateFormatter()
        let queue = try DurableTaskQueue(directory: path, agentID: .ares, clock: { clock.now() })
        let task = try await queue.accept(submission("one", deadline: formatter.string(from: clock.now().addingTimeInterval(1))))
        let lease = try await queue.claim(task.id)
        clock.advance(2)
        await expect(.deadlineExceeded) { try await queue.checkpoint(lease) }
        let result = try await queue.finish(lease, status: .completed, result: Data("actual result".utf8))
        XCTAssertEqual(result.status, .failed); XCTAssertEqual(result.errorCode, .deadlineExceeded)
    }
    func testUnrelatedAndFutureDatabaseAreNotChanged() throws {
        for future in [false, true] {
            let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = path.appendingPathComponent("tasks-v1.sqlite3")
            try createForeignDatabase(url, future: future)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let original = try Data(contentsOf: url)
            XCTAssertThrowsError(try DurableTaskQueue(directory: path, agentID: .ares)) {
                XCTAssertEqual($0 as? QueueFailure, .incompatibleStorage)
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
    private func createForeignDatabase(_ url: URL, future: Bool) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw QueueFailure.storageFailure }
        defer { sqlite3_close(handle) }
        let sql = future ? "PRAGMA application_id=1162039601; PRAGMA user_version=99;" : "CREATE TABLE user_data(value TEXT); INSERT INTO user_data VALUES ('preserve');"
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw QueueFailure.storageFailure }
    }

}

private actor PhysicalGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = 0
    func waitFirst() async {
        entered += 1
        if entered == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}
