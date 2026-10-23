import Foundation
import XCTest
import EcosystemLocalIPC
@testable import FileOrganizerCore

/// Реальные receipts, файлы и scheduler; системные диалоги/баннеры не вызываются.
extension RulePlanTests {
    func testRuntimeNotifyRecordsDurableEventWithoutSystemPermissionAndReplaysNoEffect() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let state = f.base.appendingPathComponent("automation")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let automation = try LocalAutomationService(directory: state, domain: "ares")
        await f.container.ruleCoordinator.configureAutomation(scheduler: automation.schedules) { receipt in
            try await automation.record(id: LocalStableEventID.make(receipt), kind: "rule.notification", capability: "rule.history", capturedAt: Date(), significant: true)
        }
        var rule = rule(f); rule.actions = [RuleAction(kind: .notify)]
        XCTAssertFalse(RulePolicy.requiresGUI(rule))
        let plan = try await approved(f, rule)
        let request = RuleControlRequest(ruleID: rule.id, planID: plan.id, key: "notify-approved")
        let task: LocalTaskID = try await call(f, "rule.run", request)
        let done = try await finish(f, task.id); XCTAssertEqual(done.status.rawValue, "completed")
        let events = try await automation.inbox.events(); XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.notificationEligible == true && !$0.summary.contains("a.txt") })
        let repeated: LocalTaskID = try await call(f, "rule.run", request); XCTAssertEqual(repeated.id, task.id)
        let restored = try LocalAutomationService(directory: state, domain: "ares")
        let persisted = try await restored.inbox.events(); XCTAssertEqual(persisted.map(\.id), events.map(\.id))
        let status = try await restored.status(); XCTAssertFalse(status.settings.notificationsEnabled)
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a.txt")), "alpha")
        await f.work.shutdown()
    }
    func testMissingSourcePreservesObservationAndRecordsFailureWithoutEmptySuccess() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var rule = rule(f); rule.actions = [RuleAction(kind: .log)]; rule.event = .arrived
        _ = try await f.work.governance.save(rule, fromMCP: false)
        let enable = try await f.work.governance.prepare(rule.id, kind: "enable")
        _ = try await f.work.governance.approve(enable.id, fingerprint: enable.fingerprint, role: .gui)
        try await f.container.ruleCoordinator.poll()
        let before = try await f.container.fileRepository.ruleObject(RuleObservation.self, id: rule.id.uuidString, table: .observations)
        XCTAssertEqual(before?.files.count, 2)
        // Только собственная временная папка; логическая недоступность носителя.
        try FileManager.default.removeItem(at: f.source)
        try await f.container.ruleCoordinator.poll()
        let after = try await f.container.fileRepository.ruleObject(RuleObservation.self, id: rule.id.uuidString, table: .observations)
        XCTAssertEqual(after?.files.count, 2)
        let runs = try await f.container.fileRepository.ruleObjects(RuleRun.self, table: .runs)
        XCTAssertEqual(runs.last?.status, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.appendingPathComponent("Ares Results").path))
        await f.work.shutdown()
    }
    func testOnceSchedulerSurvivesRecreationAndRepeatedPollsWithoutDuplicateRun() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let state = f.base.appendingPathComponent("automation")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let schedules = try LocalAutomationScheduleStore(directory: state)
        await f.container.ruleCoordinator.configureAutomation(scheduler: schedules) { _ in }
        var rule = rule(f); rule.actions = [RuleAction(kind: .log)]; rule.event = .scheduled
        rule.schedule = .once; rule.scheduleDate = Date().addingTimeInterval(-60); rule.catchUpOnce = true
        _ = try await f.work.governance.save(rule, fromMCP: false)
        let enable = try await f.work.governance.prepare(rule.id, kind: "enable")
        _ = try await f.work.governance.approve(enable.id, fingerprint: enable.fingerprint, role: .gui)
        try await f.container.ruleCoordinator.poll(appLaunch: true)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        try await f.container.ruleCoordinator.poll()
        let before = try await f.container.fileRepository.ruleObjects(RuleRun.self, table: .runs)
        XCTAssertEqual(before.filter { $0.ruleID == rule.id && $0.status == "completed" }.count, 1)
        let restored = try LocalAutomationScheduleStore(directory: state)
        await f.container.ruleCoordinator.configureAutomation(scheduler: restored) { _ in }
        for _ in 0..<3 { try await f.container.ruleCoordinator.poll(appLaunch: true) }
        let after = try await f.container.fileRepository.ruleObjects(RuleRun.self, table: .runs)
        XCTAssertEqual(after.filter { $0.ruleID == rule.id && $0.status == "completed" }.count, 1)
        let due = try await restored.due(now: Date()); XCTAssertTrue(due.isEmpty)
        await f.work.shutdown()
    }
    func testRuntimeLanguageSettingIsGUIOnlyAndLeavesQueueAndRulesIntact() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let state = f.base.appendingPathComponent("language-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let automation = try LocalAutomationService(directory: state, domain: "ares")
        let service = AresRuntimeService(container: f.container, work: f.work, automation: automation)
        let before = try await f.work.queue.tasks(limit: 100).map(\.id)
        let request = LocalRPCRequest(domain: "ares", operation: "language.set", payload: Data("{\"preference\":\"en\"}".utf8))
        for role in [LocalRole.mcp, .worker] {
            do { _ = try await service.handle(role: role, request: request); XCTFail("Role bypass") }
            catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        }
        let status = try LocalWire.decode(LocalLanguageStatus.self, await service.handle(role: .gui, request: request))
        XCTAssertEqual(status.preference, .en)
        let after = try await f.work.queue.tasks(limit: 100).map(\.id); XCTAssertEqual(after, before)
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a.txt")), "alpha")
        await f.work.shutdown()
    }
}
