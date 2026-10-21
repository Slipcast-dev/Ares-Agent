import EcosystemContracts
import Foundation
import XCTest
@testable import EcosystemRuntimeSupport

private final class MutablePowerState: @unchecked Sendable {
    private let lock = NSLock()
    private var state: QueuePowerState
    init(_ state: QueuePowerState) { self.state = state }
    func read() -> QueuePowerState { lock.lock(); defer { lock.unlock() }; return state }
    func set(_ value: QueuePowerState) { lock.lock(); defer { lock.unlock() }; state = value }
}
private actor PowerWorkGate {
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    var entered: Set<UUID> = []
    func wait(_ id: UUID) async { entered.insert(id); await withCheckedContinuation { continuations[id] = $0 } }
    func release(_ id: UUID) { continuations.removeValue(forKey: id)?.resume() }
}
private struct PowerParameters: Codable, Sendable { let value: Int = 1 }

/// Реальный store/claim/finish, но synthetic callbacks без файловых изменений.
/// Никакой настройки батареи/macOS или чтения личного профиля здесь нет.
final class QueuePowerPolicyTests: XCTestCase {
    private let battery = QueuePowerState(onBattery: true, lowPower: false, thermallyConstrained: false)
    private let ac = QueuePowerState(onBattery: false, lowPower: false, thermallyConstrained: false)
    private func directory() -> URL { URL(fileURLWithPath: "/private/tmp/queue-power-" + UUID().uuidString) }
    private func submission(_ key: String, capability: String = "storage.scan", deadline: Date? = nil) throws -> QueueSubmission {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let request = try TaskRequest(requestID: UUID(), agentID: .athena, capabilityID: capability,
            parameters: PowerParameters(), origin: .user, idempotencyKey: key, rootID: nil,
            createdAt: UTCTimestamp(formatter.string(from: Date())), deadlineAt: deadline.map { try UTCTimestamp(formatter.string(from: $0)) })
        return try QueueSubmission(request: request, resources: ["root." + key], mutating: false)
    }
    private func executor(_ queue: DurableTaskQueue, _ gate: PowerWorkGate, _ power: MutablePowerState) throws -> DurableTaskExecutor {
        let perform: @Sendable (Data, QueueExecutionContext) async throws -> Data = { _, context in
            await gate.wait(context.lease.taskID); try await context.checkpoint(); return Data("{}".utf8)
        }
        return try DurableTaskExecutor(queue: queue, operations: [
            "storage.scan": RegisteredQueueOperation(mutating: false, workload: .heavy, perform: perform),
            "system.get_metrics": RegisteredQueueOperation(mutating: false, workload: .light, perform: perform)
        ], powerState: { power.read() })
    }
    private func entered(_ id: UUID, _ gate: PowerWorkGate) async throws {
        for _ in 0..<200 { if await gate.entered.contains(id) { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Callback did not start")
    }
    private func complete(_ id: UUID, _ gate: PowerWorkGate, _ executor: DurableTaskExecutor) async throws {
        await gate.release(id)
        let result = try await executor.waitForTerminal(id, timeoutSeconds: 2)
        XCTAssertEqual(result.status, .completed)
    }
    func testRestrictionIncludesBatteryLowPowerThermalAndUnknownSource() {
        XCTAssertFalse(ac.limitsHeavyConcurrency)
        XCTAssertTrue(battery.limitsHeavyConcurrency)
        XCTAssertTrue(QueuePowerState(onBattery: nil, lowPower: false, thermallyConstrained: false).limitsHeavyConcurrency)
        XCTAssertTrue(QueuePowerState(onBattery: false, lowPower: true, thermallyConstrained: false).limitsHeavyConcurrency)
        XCTAssertTrue(QueuePowerState(onBattery: false, lowPower: false, thermallyConstrained: true).limitsHeavyConcurrency)
    }
    func testBatterySerializesHeavyAndKeepsIdempotentAcceptance() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .athena)
        let gate = PowerWorkGate(), power = MutablePowerState(battery)
        let executor = try executor(queue, gate, power)
        let first = try await executor.submit(submission("first")); try await entered(first.id, gate)
        let second = try await executor.submit(submission("second"))
        let repeatSecond = try await executor.submit(submission("second")); XCTAssertEqual(second.id, repeatSecond.id)
        let queued = try await queue.task(second.id); XCTAssertEqual(queued?.status, .queued)
        try await complete(first.id, gate, executor); try await entered(second.id, gate)
        try await complete(second.id, gate, executor)
        let seen = await gate.entered; XCTAssertEqual(seen.count, 2)
    }
    func testLightCanCoexistWithHeavyButGlobalQueueMaximumStillApplies() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .athena)
        let gate = PowerWorkGate(), power = MutablePowerState(battery)
        let executor = try executor(queue, gate, power)
        let heavy = try await executor.submit(submission("heavy")); try await entered(heavy.id, gate)
        let light = try await executor.submit(submission("light", capability: "system.get_metrics")); try await entered(light.id, gate)
        let another = try await executor.submit(submission("another", capability: "system.get_metrics"))
        let waiting = try await queue.task(another.id); XCTAssertEqual(waiting?.status, .queued)
        try await complete(light.id, gate, executor); try await entered(another.id, gate)
        try await complete(another.id, gate, executor); try await complete(heavy.id, gate, executor)
    }
    func testACRestoresParallelHeavyWithoutInterruptingFirst() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .athena)
        let gate = PowerWorkGate(), power = MutablePowerState(battery)
        let executor = try executor(queue, gate, power)
        let first = try await executor.submit(submission("first")); try await entered(first.id, gate)
        let second = try await executor.submit(submission("second"))
        power.set(ac); try await executor.resumeQueuedTasks()
        try await entered(second.id, gate)
        let retained = try await queue.task(first.id); XCTAssertEqual(retained?.status, .running)
        try await complete(first.id, gate, executor); try await complete(second.id, gate, executor)
    }
    func testSwitchToBatteryDoesNotCancelAlreadyRunningHeavy() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .athena)
        let gate = PowerWorkGate(), power = MutablePowerState(ac)
        let executor = try executor(queue, gate, power)
        let first = try await executor.submit(submission("first")); try await entered(first.id, gate)
        let second = try await executor.submit(submission("second")); try await entered(second.id, gate)
        power.set(battery)
        let third = try await executor.submit(submission("third"))
        try await complete(first.id, gate, executor)
        let waiting = try await queue.task(third.id), retained = try await queue.task(second.id)
        XCTAssertEqual(waiting?.status, .queued); XCTAssertEqual(retained?.status, .running)
        try await complete(second.id, gate, executor); try await entered(third.id, gate)
        try await complete(third.id, gate, executor)
    }
    func testQueuedDeadlineStillExpiresBehindLimitedHeavy() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .athena)
        let gate = PowerWorkGate(), power = MutablePowerState(battery)
        let executor = try executor(queue, gate, power)
        let first = try await executor.submit(submission("first")); try await entered(first.id, gate)
        let second = try await executor.submit(submission("deadline", deadline: Date().addingTimeInterval(0.2)))
        try await Task.sleep(for: .milliseconds(250)); try await executor.resumeQueuedTasks()
        let expired = try await queue.task(second.id); XCTAssertEqual(expired?.errorCode, .deadlineExceeded)
        let reserved = try await queue.hasReservation("root.deadline"); XCTAssertFalse(reserved)
        try await complete(first.id, gate, executor)
        let seen = await gate.entered; XCTAssertEqual(seen, [first.id])
    }
    func testCancelledQueuedHeavyNeverEntersCallback() async throws {
        let path = directory(); defer { try? FileManager.default.removeItem(at: path) }
        let queue = try DurableTaskQueue(directory: path, agentID: .athena)
        let gate = PowerWorkGate(), power = MutablePowerState(battery)
        let executor = try executor(queue, gate, power)
        let first = try await executor.submit(submission("first")); try await entered(first.id, gate)
        let second = try await executor.submit(submission("cancelled"))
        try await executor.cancel(second.id)
        try await complete(first.id, gate, executor)
        let cancelled = try await queue.task(second.id); XCTAssertEqual(cancelled?.status, .cancelled)
        let seen = await gate.entered; XCTAssertEqual(seen, [first.id])
    }
}
