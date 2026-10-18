import Foundation
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import FileOrganizerCore

final class EventBoundRuleTests: XCTestCase {
    private func finish(_ queue: DurableTaskQueue, _ id: UUID) async throws -> DurableTask {
        for _ in 0..<150 {
            if let value = try await queue.task(id), value.status.isTerminal { return value }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw LocalRuntimeFailure.deadlineExceeded
    }

    func testSameEventCannotCopyChangedFileTwiceAndAnotherClientCannotStealTask() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/e10-rule-event-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source"), destination = base.appendingPathComponent("destination")
        for folder in [source, destination] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let file = source.appendingPathComponent("sample.txt")
        try Data("first version".utf8).write(to: file)
        let container = AppContainer(databaseURL: base.appendingPathComponent("domain.sqlite"), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: source)
        let target = try await container.authorizedRootAccess.addRoot(from: destination)
        let queue = try DurableTaskQueue(directory: base.appendingPathComponent("queue"), agentID: .ares)
        let policy = try LocalAccessPolicy(directory: base, domain: "ares")
        let automation = try LocalAutomationService(directory: base, domain: "ares")
        try await automation.configure(paused: true, notificationsEnabled: false)
        let work = try AresQueuedWork(queue: queue, repository: container.fileRepository,
            access: container.authorizedRootAccess, rules: container.ruleCoordinator, policy: policy)
        let service = AresRuntimeService(container: container, work: work, automation: automation)
        var action = RuleAction(kind: .copy); action.destinationRootID = target.id
        var rule = AutomationRule(); rule.rootID = root.id; rule.actions = [action]; rule.conditions.extensions = ["txt"]
        _ = try await work.governance.save(rule, fromMCP: false)
        let enable = try await work.governance.prepare(rule.id, kind: "enable")
        _ = try await work.governance.approve(enable.id, fingerprint: enable.fingerprint, role: .gui)
        var grants: [LocalMCPClient: LocalAccessGrant] = [:]
        for client in [LocalMCPClient.codex, .deepseekHarness] {
            var draft = LocalAccessDraft(); draft.client = client; draft.roots = [root.id, target.id]
            draft.capabilities = ["events.read", "rule.run", "rule.history"]
            draft.dataClass = .fileMetadata
            let plan = try await policy.request(draft, client: nil)
            grants[client] = try await policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
        }
        let eventID = UUID()
        try await automation.inbox.append(id: eventID, kind: "rule.completed", capability: "rule.history", rootIDs: [root.id], summary: "Правило завершено")
        let claim = try await automation.inbox.claimProcessing(id: eventID, client: .codex, authorizationID: XCTUnwrap(grants[.codex]).id)
        let token = try XCTUnwrap(claim.processingToken)
        func run(_ client: LocalMCPClient, _ token: UUID, key: String? = nil) async throws -> LocalTaskID {
            let value = RuleControlRequest(ruleID: rule.id, key: key, eventID: eventID, processingToken: token)
            return try LocalWire.decode(LocalTaskID.self, await service.handle(role: .mcp, clientID: client,
                request: LocalRPCRequest(domain: "ares", operation: "rule.run", payload: LocalWire.encode(value))))
        }
        let first = try await run(.codex, token)
        let completed = try await finish(queue, first.id)
        XCTAssertEqual(completed.status.rawValue, "completed")
        let output = destination.appendingPathComponent("Ares Results")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 1)
        // Новая версия намеренно исключает помощь per-file receipts: повтор
        // обязан блокироваться по событию, а не совпавшему fingerprint файла.
        try Data("second changed version".utf8).write(to: file)
        let repeated = try await run(.codex, token)
        XCTAssertEqual(repeated.id, first.id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 1)
        do { _ = try await run(.deepseekHarness, token); XCTFail("Чужой processing token принят") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        do { _ = try await run(.codex, token, key: "choose-a-new-key"); XCTFail("Клиент изменил canonical key") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        try await automation.inbox.ackProcessing(id: eventID, client: .codex, token: token, authorizationID: XCTUnwrap(grants[.codex]).id)
        do { _ = try await run(.codex, token); XCTFail("Завершённая обработка возобновилась") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let tasks = try await queue.tasks(limit: 100)
        XCTAssertEqual(tasks.filter { $0.capabilityID == "rule.run" }.count, 1)
    }
}
