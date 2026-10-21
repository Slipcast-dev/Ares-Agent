import Foundation
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import FileOrganizerCore

/// Испытываем реальные SQL/файлы и подтверждённые роли. Фикстуры не используют
/// пользовательские базы, Keychain или внешнюю сеть.
final class RulePlanTests: XCTestCase {
    struct Fixture {
        let base: URL; let source: URL; let target: URL
        let container: AppContainer; let root: AuthorizedRoot; let destination: AuthorizedRoot
        let work: AresQueuedWork; let service: AresRuntimeService
    }
    func fixture() async throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp/e4b-unit-" + UUID().uuidString)
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        for directory in [source, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("alpha".utf8).write(to: source.appendingPathComponent("a.txt"))
        try Data("beta".utf8).write(to: source.appendingPathComponent("b.txt"))
        let container = AppContainer(databaseURL: base.appendingPathComponent("state.sqlite"), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: source)
        let destination = try await container.authorizedRootAccess.addRoot(from: target)
        let queue = try DurableTaskQueue(directory: base.appendingPathComponent("queue"), agentID: .ares)
        let work = try AresQueuedWork(queue: queue, repository: container.fileRepository, access: container.authorizedRootAccess, rules: container.ruleCoordinator)
        return Fixture(base: base, source: source, target: target, container: container, root: root, destination: destination, work: work, service: AresRuntimeService(container: container, work: work))
    }
    func rule(_ f: Fixture) -> AutomationRule {
        var rule = AutomationRule(); rule.name = "Copy and archive"; rule.rootID = f.root.id; rule.conditions.extensions = ["txt"]
        var copy = RuleAction(kind: .copy); copy.destinationRootID = f.destination.id
        var archive = RuleAction(kind: .archive); archive.destinationRootID = f.destination.id; archive.archiveTogether = true
        rule.actions = [copy, archive]; return rule
    }
    func call<T: Decodable>(_ f: Fixture, _ name: String, _ request: RuleControlRequest, role: LocalRole = .mcp, as type: T.Type = T.self) async throws -> T {
        let data = try await f.service.handle(role: role, request: LocalRPCRequest(domain: "ares", operation: name, payload: LocalWire.encode(request)))
        if name == "rule.preview" {
            let id = try LocalWire.decode(LocalTaskID.self, data)
            let completed = try await finish(f, id.id)
            guard let result = completed.result else { throw RulePolicyError.invalid }
            return try LocalWire.decode(type, result)
        }
        return try LocalWire.decode(type, data)
    }
    func finish(_ f: Fixture, _ id: UUID) async throws -> DurableTask {
        for _ in 0..<500 {
            if let task = try await f.work.queue.task(id), task.status.isTerminal { return task }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw LocalRuntimeFailure.deadlineExceeded
    }
    func approved(_ f: Fixture, _ rule: AutomationRule) async throws -> RulePlanSummary {
        let _: AutomationRule = try await call(f, "rule.propose", RuleControlRequest(rule: rule), role: .gui)
        let plan: RulePlanSummary = try await call(f, "rule.preview", RuleControlRequest(ruleID: rule.id))
        return try await call(f, "rule.approve", RuleControlRequest(planID: plan.id, fingerprint: plan.fingerprint), role: .gui)
    }
    func testEmergencyControlIsGUIOnlyAndBlocksApprovedRuleExecution() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let draft = rule(f)
        let plan = try await approved(f, draft)
        for operation in ["operations.emergency_status", "operations.emergency_stop", "operations.emergency_resume"] {
            for role in [LocalRole.mcp, .worker] {
                do {
                    _ = try await f.service.handle(role: role, request: LocalRPCRequest(domain: "ares", operation: operation, payload: Data("{}".utf8)))
                    XCTFail("Non-GUI emergency control")
                } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
            }
        }
        _ = try await f.service.handle(role: .gui, request: LocalRPCRequest(domain: "ares", operation: "operations.emergency_stop", payload: Data("{}".utf8)))
        do {
            let _: LocalTaskID = try await call(f, "rule.run", RuleControlRequest(ruleID: draft.id, planID: plan.id, key: "stop-approved"))
            XCTFail("Stopped runtime accepted approved mutation")
        } catch { XCTAssertEqual(error as? QueueFailure, .emergencyStopped) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.appendingPathComponent("Ares Results").path))
        _ = try await f.service.handle(role: .gui, request: LocalRPCRequest(domain: "ares", operation: "operations.emergency_resume", payload: Data("{}".utf8)))
        let task: LocalTaskID = try await call(f, "rule.run", RuleControlRequest(ruleID: draft.id, planID: plan.id, key: "resumed-approved"))
        let result = try await finish(f, task.id); XCTAssertEqual(result.status.rawValue, "completed")
        await f.work.shutdown()
    }
    func testPlanNeedsGUIAndCopyZIPAreVerifiedAndIdempotent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var draft = rule(f); draft.enabled = true
        let saved: AutomationRule = try await call(f, "rule.propose", RuleControlRequest(rule: draft))
        XCTAssertFalse(saved.enabled); XCTAssertNotEqual(saved.id, draft.id)
        let plan: RulePlanSummary = try await call(f, "rule.preview", RuleControlRequest(ruleID: saved.id))
        XCTAssertEqual(plan.fileCount, 2); XCTAssertEqual(plan.byteSize, 9)
        let filesPage: RulePlanFilesPage = try await call(f, "rule.plan_files", RuleControlRequest(planID: plan.id, offset: 1), role: .gui)
        XCTAssertEqual(filesPage.files, ["b.txt"])
        do { let _: RulePlanFilesPage = try await call(f, "rule.plan_files", RuleControlRequest(planID: plan.id)); XCTFail("MCP read internal plan") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        do { let _: RulePlanSummary = try await call(f, "rule.approve", RuleControlRequest(planID: plan.id, fingerprint: plan.fingerprint)); XCTFail("MCP minted approval") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let denied: LocalTaskID = try await call(f, "rule.run", RuleControlRequest(ruleID: saved.id, planID: plan.id, key: "unapproved"))
        let failed = try await finish(f, denied.id); XCTAssertEqual(failed.errorCode?.rawValue, "PERMISSION_DENIED")
        let _: RulePlanSummary = try await call(f, "rule.approve", RuleControlRequest(planID: plan.id, fingerprint: plan.fingerprint), role: .gui)
        let request = RuleControlRequest(ruleID: saved.id, planID: plan.id, key: "approved")
        let task: LocalTaskID = try await call(f, "rule.run", request)
        let result = try await finish(f, task.id)
        XCTAssertEqual(result.status.rawValue, "completed")
        let output = try FileManager.default.contentsOfDirectory(at: f.target.appendingPathComponent("Ares Results"), includingPropertiesForKeys: nil)
        XCTAssertEqual(output.count, 3)
        let copies = output.filter { $0.pathExtension == "txt" }
        XCTAssertEqual(Set(try copies.map { try String(contentsOf: $0) }), ["alpha", "beta"])
        let archive = try XCTUnwrap(output.first { $0.pathExtension == "zip" })
        for (entry, expected) in [("1-a.txt", "alpha"), ("2-b.txt", "beta")] {
            let process = Process(); let pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", archive.path, entry]; process.standardOutput = pipe
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0); XCTAssertEqual(String(data: data, encoding: .utf8), expected)
        }
        let repeated: LocalTaskID = try await call(f, "rule.run", request); XCTAssertEqual(repeated.id, task.id)
        let reused: LocalTaskID = try await call(f, "rule.run", RuleControlRequest(ruleID: saved.id, planID: plan.id, key: "new-key"))
        let rejected = try await finish(f, reused.id); XCTAssertEqual(rejected.errorCode?.rawValue, "STALE_SNAPSHOT")
        let receipts = try await f.work.queue.receipts(task.id); XCTAssertEqual(receipts.count, 3); XCTAssertTrue(receipts.allSatisfy { $0.state.rawValue == "done" })
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a.txt")), "alpha")
    }
    func testChangedFilesRevisionExpiryAndQuotaRejectPlan() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let rule = rule(f)
        let _: AutomationRule = try await call(f, "rule.propose", RuleControlRequest(rule: rule), role: .gui)
        let plan = try await f.work.governance.prepare(rule.id, kind: "run")
        try Data("other".utf8).write(to: f.source.appendingPathComponent("a.txt"))
        do { _ = try await f.work.governance.approve(plan.id, fingerprint: plan.fingerprint, role: .gui); XCTFail("Stale bytes approved") } catch { XCTAssertEqual(error as? RulePolicyError, .stale) }
        var changed = rule; changed.name = "changed"
        _ = try await f.work.governance.save(changed, fromMCP: false)
        do { _ = try await f.work.governance.checkedPlan(plan.id); XCTFail("Revision changed") } catch { XCTAssertEqual(error as? RulePolicyError, .stale) }
        let fresh = try await f.work.governance.prepare(rule.id, kind: "run")
        let expired = RulePlan(id: fresh.id, ruleID: fresh.ruleID, revision: fresh.revision, kind: fresh.kind, createdAt: fresh.createdAt, expiresAt: Date(timeIntervalSince1970: 1), files: fresh.files)
        try await f.container.fileRepository.saveRuleObject(expired, id: expired.id.uuidString, table: .plans)
        do { _ = try await f.work.governance.checkedPlan(expired.id); XCTFail("Expired plan") } catch { XCTAssertEqual(error as? RulePolicyError, .stale) }
        changed.maximumFiles = 1; _ = try await f.work.governance.save(changed, fromMCP: false)
        do { _ = try await f.work.governance.prepare(changed.id, kind: "run"); XCTFail("Quota bypass") } catch { XCTAssertEqual(error as? RulePolicyError, .quota) }
        _ = try await f.work.governance.save(rule, fromMCP: false)
        do { _ = try await f.work.governance.approve(plan.id, fingerprint: plan.fingerprint, role: .gui); XCTFail("A-B-A revived old plan") } catch { XCTAssertEqual(error as? RulePolicyError, .stale) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.appendingPathComponent("Ares Results").path))
    }
    func testEnableBindsRevisionAndDisableInvalidatesApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var rule = rule(f); rule.actions = [RuleAction(kind: .log)]
        _ = try await f.work.governance.save(rule, fromMCP: false)
        let enable = try await f.work.governance.prepare(rule.id, kind: "enable")
        _ = try await f.work.governance.approve(enable.id, fingerprint: enable.fingerprint, role: .gui)
        let saved = try await f.work.governance.saved(rule.id); XCTAssertTrue(saved.enabled)
        try await f.work.governance.authorized(saved)
        var changed = saved; changed.maximumFiles = 10
        let updated = try await f.work.governance.save(changed, fromMCP: false); XCTAssertFalse(updated.enabled)
        let plan = try await f.work.governance.prepare(rule.id, kind: "run")
        _ = try await f.work.governance.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
        try await f.work.governance.disable(rule.id)
        let (_, invalidated) = try await f.work.governance.execution(rule.id, planID: plan.id)
        do { try await f.work.governance.consume(XCTUnwrap(invalidated)); XCTFail("Disabled plan reused") } catch { XCTAssertEqual(error as? RulePolicyError, .stale) }
    }
    func testCyclesGUIActionsAndRawSubmissionCannotBypassPolicy() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var first = rule(f), second = rule(f)
        var link = RuleAction(kind: .runRule); link.nextRuleID = second.id; first.actions = [link]
        link.nextRuleID = first.id; second.actions = [link]
        try await f.container.fileRepository.saveRuleObject(second, id: second.id.uuidString, table: .rules)
        do { try await f.work.governance.validate(first); XCTFail("Cycle accepted") } catch { XCTAssertEqual(error as? RulePolicyError, .invalid) }
        var gui = rule(f); gui.actions = [RuleAction(kind: .showFiles)]
        _ = try await f.work.governance.save(gui, fromMCP: false)
        do { _ = try await f.work.governance.prepare(gui.id, kind: "run"); XCTFail("GUI falsely succeeded") } catch { XCTAssertEqual(error as? RulePolicyError, .guiRequired) }
        do { _ = try await f.work.submit(AresSubmission(capability: "rule.run", job: AresJob(rule: gui), key: "raw"), role: .gui); XCTFail("Raw rule bypass") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .invalidRequest) }
    }
    func testDescriptorCopyRejectsCollisionAndDeterministicPathReplacement() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let version = try VerifiedFileReader.capture(root: f.source, relative: "a.txt")
        XCTAssertThrowsError(try SecureRuleIO.space(SecureRuleIO.directory(f.target), bytes: Int64.max, factor: 2)) { XCTAssertEqual($0 as? RulePolicyError, .space) }
        try SecureRuleIO.copy(root: f.source, relative: "a.txt", version: version, destinationRoot: f.target, name: "copy.txt")
        XCTAssertThrowsError(try SecureRuleIO.copy(root: f.source, relative: "a.txt", version: version, destinationRoot: f.target, name: "copy.txt"))
        let outside = f.base.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let output = f.target.appendingPathComponent("Ares Results"), moved = f.target.appendingPathComponent("moved")
        XCTAssertThrowsError(try SecureRuleIO.copy(root: f.source, relative: "a.txt", version: version, destinationRoot: f.target, name: "escape.txt", beforePublish: {
            try FileManager.default.moveItem(at: output, to: moved)
            try FileManager.default.createSymbolicLink(at: output, withDestinationURL: outside)
        }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.path), ["copy.txt"])
        XCTAssertThrowsError(try SecureRuleIO.copy(root: f.source, relative: "a.txt", version: version, destinationRoot: outside, name: "changed.txt", beforePublish: {
            try FileManager.default.moveItem(at: f.source.appendingPathComponent("a.txt"), to: f.source.appendingPathComponent("old.txt"))
            try Data("alpha".utf8).write(to: f.source.appendingPathComponent("a.txt"))
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("Ares Results/changed.txt").path))
    }
    func testOutputDirectoryCaseAliasNeverFeedsAutomationAgain() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let results = f.source.appendingPathComponent("ares results")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try Data("own result".utf8).write(to: results.appendingPathComponent("old.txt"))
        let matches = try await f.container.ruleCoordinator.preview(rule(f))
        XCTAssertEqual(matches.map(\.relativePath), ["a.txt", "b.txt"])
    }
    func testTagCannotMutateAnInodeWithAnAliasOutsideTheRoot() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let source = f.source.appendingPathComponent("a.txt"), alias = f.base.appendingPathComponent("outside-alias.txt")
        let initial = try VerifiedFileReader.capture(root: f.source, relative: "a.txt")
        try SecureRuleIO.tag(root: f.source, relative: "a.txt", version: initial, value: "Existing", remove: false)
        let tagged = try VerifiedFileReader.capture(root: f.source, relative: "a.txt")
        try SecureRuleIO.tag(root: f.source, relative: "a.txt", version: tagged, value: "Existing", remove: false)
        XCTAssertEqual(try VerifiedFileReader.capture(root: f.source, relative: "a.txt"), tagged)
        try FileManager.default.linkItem(at: source, to: alias)
        let before = try alias.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        let version = try VerifiedFileReader.capture(root: f.source, relative: "a.txt")
        XCTAssertThrowsError(try SecureRuleIO.tag(root: f.source, relative: "a.txt", version: version, value: "Protected", remove: false)) {
            XCTAssertEqual($0 as? RulePolicyError, .permission)
        }
        XCTAssertEqual(try alias.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [], before)
    }
    func testContentReaderRejectsReplacementSymlinkBeforeParsing() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let version = try VerifiedFileReader.capture(root: f.source, relative: "a.txt")
        let analyzer = RuleContentAnalyzer()
        let matches = try await analyzer.matchesVerified(root: f.source, relative: "a.txt", expected: version, event: .textContains, value: "alpha", consent: true)
        XCTAssertTrue(matches)
        let outside = f.base.appendingPathComponent("private.txt")
        try Data("outside phrase".utf8).write(to: outside)
        try FileManager.default.removeItem(at: f.source.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(at: f.source.appendingPathComponent("a.txt"), withDestinationURL: outside)
        do {
            _ = try await analyzer.matchesVerified(root: f.source, relative: "a.txt", expected: version, event: .textContains, value: "outside phrase", consent: true)
            XCTFail("Decoder followed a replacement symlink")
        } catch { XCTAssertEqual(error as? AresFileFailure, .unsafePath) }
    }
    func testOpposingAutomaticTagsInOverlappingRootsAreRejected() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var add = rule(f); add.actions = [RuleAction(kind: .addTag, value: "Inbox")]
        _ = try await f.work.governance.save(add, fromMCP: false)
        let enable = try await f.work.governance.prepare(add.id, kind: "enable")
        let nested = f.source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedRoot = try await f.container.authorizedRootAccess.addRoot(from: nested)
        var remove = rule(f); remove.rootID = nestedRoot.id; remove.actions = [RuleAction(kind: .removeTag, value: "Inbox")]
        _ = try await f.work.governance.save(remove, fromMCP: false)
        let pendingRemove = try await f.work.governance.prepare(remove.id, kind: "enable")
        _ = try await f.work.governance.approve(enable.id, fingerprint: enable.fingerprint, role: .gui)
        do { _ = try await f.work.governance.approve(pendingRemove.id, fingerprint: pendingRemove.fingerprint, role: .gui); XCTFail("Approval race") } catch { XCTAssertEqual(error as? RulePolicyError, .invalid) }
        do { _ = try await f.work.governance.prepare(remove.id, kind: "enable"); XCTFail("Opposing automation cycle") } catch { XCTAssertEqual(error as? RulePolicyError, .invalid) }
        let manual = try await f.work.governance.prepare(remove.id, kind: "run"); XCTAssertEqual(manual.kind, "run")
    }
    func testCancellationBeforeEffectsStopsQueueWithoutPublishing() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let rule = rule(f); let plan = try await approved(f, rule)
        let task: LocalTaskID = try await call(f, "rule.run", RuleControlRequest(ruleID: rule.id, planID: plan.id, key: "cancel"))
        try await f.work.cancel(task.id, role: .gui)
        let stopped = try await finish(f, task.id); XCTAssertEqual(stopped.status.rawValue, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.appendingPathComponent("Ares Results").path))
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("a.txt")), "alpha")
    }
}
