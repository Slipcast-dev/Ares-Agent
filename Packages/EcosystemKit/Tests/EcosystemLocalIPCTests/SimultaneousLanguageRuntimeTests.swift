import Foundation
import XCTest
import EcosystemContracts
import EcosystemLocalization
import EcosystemRuntimeSupport
@testable import EcosystemLocalIPC

private actor SimultaneousLanguageGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var callbacks = 0
    func wait() async {
        callbacks += 1
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

/// Реальные in-process executor callbacks обоих доменов одновременно удерживают
/// started receipt. Допуск queue доверенный; XPC, grants и GUI approval здесь
/// не моделируются. Эффект — только возвращённые Data, личных файлов нет.
final class SimultaneousLanguageRuntimeTests: XCTestCase {
    func testBothPhysicalMutationsContinueOnceAcrossIndependentLanguageChangesAndExecutorRestart() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/simultaneous-language-" + UUID().uuidString)
        let ares = root.appendingPathComponent("ares"), athena = root.appendingPathComponent("athena")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [ares, athena] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let queueA = try DurableTaskQueue(directory: ares.appendingPathComponent("queue"), agentID: .ares)
        let queueB = try DurableTaskQueue(directory: athena.appendingPathComponent("queue"), agentID: .athena)
        let languageA = try LocalLanguagePreferences(directory: ares, domain: "ares")
        let languageB = try LocalLanguagePreferences(directory: athena, domain: "athena")
        let gateA = SimultaneousLanguageGate(), gateB = SimultaneousLanguageGate()
        let operationsA = ["rule.run": RegisteredQueueOperation(mutating: true) { _, context in
            try await context.recordedAction(key: "fixture.effect") {
                await gateA.wait(); return Data("ares effect".utf8)
            }
        }]
        let operationsB = ["monitor.create": RegisteredQueueOperation(mutating: true) { _, context in
            try await context.recordedAction(key: "fixture.effect") {
                await gateB.wait(); return Data("athena effect".utf8)
            }
        }]
        let executorA = try DurableTaskExecutor(queue: queueA, operations: operationsA)
        let executorB = try DurableTaskExecutor(queue: queueB, operations: operationsB)
        do {
            let submissionA = try submission(agent: .ares, capability: "rule.run")
            let submissionB = try submission(agent: .athena, capability: "monitor.create")
            async let acceptedA = executorA.submit(submissionA)
            async let acceptedB = executorB.submit(submissionB)
            let (taskA, taskB) = try await (acceptedA, acceptedB)
            try await waitForCallback(gateA)
            try await waitForCallback(gateB)
            let activeA = try await queueA.task(taskA.id), activeB = try await queueB.task(taskB.id)
            XCTAssertEqual(activeA?.status, .running)
            XCTAssertEqual(activeB?.status, .running)
            XCTAssertNotNil(activeA?.lease)
            XCTAssertNotNil(activeB?.lease)
            let bytesA = try LocalWire.encode(XCTUnwrap(activeA))
            let bytesB = try LocalWire.encode(XCTUnwrap(activeB))
            _ = try await languageA.set(.en)
            let untouchedB = try await queueB.task(taskB.id)
            XCTAssertEqual(try LocalWire.encode(XCTUnwrap(untouchedB)), bytesB)
            _ = try await languageB.set(.ru)
            let unchangedA = try await queueA.task(taskA.id), unchangedB = try await queueB.task(taskB.id)
            XCTAssertEqual(try LocalWire.encode(XCTUnwrap(unchangedA)), bytesA)
            XCTAssertEqual(try LocalWire.encode(XCTUnwrap(unchangedB)), bytesB)
            // Повторные submit во время callbacks не создают второй физический
            // эффект и не обновляют lease/fencing через изменение языка.
            let repeatedA = try await executorA.submit(submissionA), repeatedB = try await executorB.submit(submissionB)
            XCTAssertEqual(repeatedA.id, taskA.id)
            XCTAssertEqual(repeatedB.id, taskB.id)
            let countA = await gateA.callbacks, countB = await gateB.callbacks
            XCTAssertEqual(countA, 1)
            XCTAssertEqual(countB, 1)
            await gateA.release()
            let finishedA = try await executorA.waitForTerminal(taskA.id)
            XCTAssertEqual(finishedA.status, .completed)
            let stillRunningB = try await queueB.task(taskB.id)
            XCTAssertEqual(try LocalWire.encode(XCTUnwrap(stillRunningB)), bytesB)
            await gateB.release()
            let finishedB = try await executorB.waitForTerminal(taskB.id)
            XCTAssertEqual(finishedB.status, .completed)
            XCTAssertEqual(finishedA.result, Data("ares effect".utf8))
            XCTAssertEqual(finishedB.result, Data("athena effect".utf8))
            let drainedA = try await executorA.drain(), drainedB = try await executorB.drain()
            XCTAssertTrue(drainedA)
            XCTAssertTrue(drainedB)
            // Новый executor читает ту же устойчивую queue; это перезапуск
            // executor внутри процесса, а не заявление о новом системном XPC.
            let restartedA = try DurableTaskExecutor(queue: queueA, operations: operationsA)
            let restartedB = try DurableTaskExecutor(queue: queueB, operations: operationsB)
            let restoredLanguageA = try LocalLanguagePreferences(directory: ares, domain: "ares")
            let restoredLanguageB = try LocalLanguagePreferences(directory: athena, domain: "athena")
            let choiceA = await restoredLanguageA.status(), choiceB = await restoredLanguageB.status()
            XCTAssertEqual(choiceA.preference, .en)
            XCTAssertEqual(choiceB.preference, .ru)
            let sameA = try await restartedA.submit(submissionA), sameB = try await restartedB.submit(submissionB)
            XCTAssertEqual(sameA.id, taskA.id)
            XCTAssertEqual(sameB.id, taskB.id)
            XCTAssertEqual(sameA.status, .completed)
            XCTAssertEqual(sameB.status, .completed)
            let finalCountA = await gateA.callbacks, finalCountB = await gateB.callbacks
            XCTAssertEqual(finalCountA, 1)
            XCTAssertEqual(finalCountB, 1)
            for (queue, id) in [(queueA, taskA.id), (queueB, taskB.id)] {
                let receipts = try await queue.receipts(id)
                XCTAssertEqual(receipts.count, 1)
                XCTAssertEqual(receipts.first?.state, .done)
            }
            let restartedDrainedA = try await restartedA.drain(), restartedDrainedB = try await restartedB.drain()
            XCTAssertTrue(restartedDrainedA)
            XCTAssertTrue(restartedDrainedB)
        } catch {
            await gateA.release(); await gateB.release()
            _ = try? await executorA.drain(); _ = try? await executorB.drain()
            throw error
        }
    }

    private func submission(agent: AgentID, capability: String) throws -> QueueSubmission {
        let request = try TaskRequest(requestID: UUID(), agentID: agent, capabilityID: capability,
            parameters: ["fixture": 1], origin: .user, idempotencyKey: "simultaneous-language-once",
            rootID: UUID(), createdAt: UTCTimestamp("2026-10-23T01:00:00Z"))
        return try QueueSubmission(request: request, resources: ["fixture.resource"], mutating: true)
    }

    private func waitForCallback(_ gate: SimultaneousLanguageGate) async throws {
        for _ in 0..<300 {
            if await gate.callbacks == 1 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw LocalRuntimeFailure.deadlineExceeded
    }
}
