import Foundation
import XCTest
import EcosystemContracts
import EcosystemRuntimeSupport
@testable import EcosystemLocalIPC

final class RecoveryTests: XCTestCase {
    private func request(_ operation: String, _ payload: some Encodable) throws -> LocalRPCRequest {
        LocalRPCRequest(domain: "ares", operation: operation, payload: try LocalWire.encode(payload))
    }
    func testOperatorConfirmsUnknownEffectWithoutReplayAndRejectsRoleRevisionAndMissingFacts() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/e3c-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = try DurableTaskQueue(directory: directory, agentID: .ares)
        let taskRequest = try TaskRequest(requestID: UUID(), agentID: .ares, capabilityID: "rule.run", parameters: LocalEmpty(), origin: .user, idempotencyKey: "original", createdAt: UTCTimestamp("2026-10-16T12:00:00Z"))
        let submission = try QueueSubmission(request: taskRequest, resources: ["ares.domain"], mutating: true)
        let effect = directory.appendingPathComponent("effect.txt")
        let executor = try DurableTaskExecutor(queue: queue, operations: ["rule.run": RegisteredQueueOperation(mutating: true) { _, context in
            try await context.recordedAction(key: "copy", summary: "Копия тестового файла") {
                try Data("one effect".utf8).write(to: effect)
                throw LocalRuntimeFailure.operationFailed
            }
        }])
        let task = try await executor.submit(submission)
        let failed = try await executor.waitForTerminal(task.id)
        XCTAssertEqual(failed.status, .recoveryRequired)
        // История обычных чтений не должна спрятать старый карантин.
        for index in 0..<105 {
            let reading = try TaskRequest(requestID: UUID(), agentID: .ares, capabilityID: "file.scan", parameters: LocalEmpty(), origin: .user, idempotencyKey: "read-\(index)", rootID: UUID(), createdAt: UTCTimestamp("2026-10-16T12:00:00Z"))
            let accepted = try await queue.accept(QueueSubmission(request: reading, resources: ["independent.read"], mutating: false))
            let lease = try await queue.claim(accepted.id)
            _ = try await queue.finish(lease, status: .completed, result: Data("{}".utf8))
        }
        let recent = try await queue.tasks(); XCTAssertFalse(recent.contains { $0.id == task.id })
        let service = LocalRecoveryService(queue: queue, executor: executor)
        let list = try request("recovery.list", RecoveryListRequest())
        do { _ = try await service.handle(role: .mcp, request: list); XCTFail("MCP cannot reconcile") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let page = try LocalWire.decode(RecoveryPage.self, await service.handle(role: .gui, request: list))
        XCTAssertEqual(page.items.map(\.id), [task.id])
        let detail = try LocalWire.decode(RecoveryDetails.self, await service.handle(role: .gui, request: request("recovery.inspect", RecoveryInspectRequest(id: task.id))))
        XCTAssertEqual(detail.receipts.first?.summary, "Копия тестового файла")
        let decision = RecoveryDecision(receiptID: try XCTUnwrap(detail.receipts.first).id, state: .done, note: "Проверено содержимое копии: one effect")
        for invalid in [RecoveryConfirmation(id: task.id, revision: detail.item.revision + 1, decisions: [decision]), RecoveryConfirmation(id: task.id, revision: detail.item.revision, decisions: []), RecoveryConfirmation(id: task.id, revision: detail.item.revision, decisions: [RecoveryDecision(receiptID: decision.receiptID, state: .done, note: String(repeating: " ", count: 2000) + decision.note)])] {
            do { _ = try await service.handle(role: .gui, request: request("recovery.confirm", invalid)); XCTFail("Invalid confirmation accepted") } catch {}
        }
        let stillLocked = try await queue.hasReservation("ares.domain"); XCTAssertTrue(stillLocked)
        _ = try await service.handle(role: .gui, request: request("recovery.confirm", RecoveryConfirmation(id: task.id, revision: detail.item.revision, decisions: [decision])))
        let stored = try await queue.task(task.id); XCTAssertNotNil(stored?.reconciledAt); XCTAssertEqual(stored?.status, .recoveryRequired)
        let locked = try await queue.hasReservation("ares.domain"); XCTAssertFalse(locked)
        XCTAssertEqual(try String(contentsOf: effect), "one effect")
        let repeated = try await queue.accept(submission); XCTAssertEqual(repeated.id, task.id)
        let receipts = try await queue.receipts(task.id); XCTAssertEqual(receipts.first?.state, .done)
        let pending = try await queue.recoveryTasks(); XCTAssertTrue(pending.isEmpty)
    }
}
