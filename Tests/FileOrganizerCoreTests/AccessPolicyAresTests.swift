import XCTest
@testable import FileOrganizerCore
import EcosystemContracts
import EcosystemLocalIPC
import EcosystemRuntimeSupport

final class AccessPolicyAresTests: XCTestCase {
    struct Fixture {
        let base: URL; let source: URL; let target: URL
        let container: AppContainer; let root: AuthorizedRoot; let destination: AuthorizedRoot
        let policy: LocalAccessPolicy; let work: AresQueuedWork; let service: AresRuntimeService
    }
    func fixture() async throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ares-e6-" + UUID().uuidString)
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        for url in [source, target] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try Data("private-data".utf8).write(to: source.appendingPathComponent("private-name.txt"))
        let container = AppContainer(databaseURL: base.appendingPathComponent("state.sqlite"), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: source), destination = try await container.authorizedRootAccess.addRoot(from: target)
        let policy = try LocalAccessPolicy(directory: base, domain: "ares")
        let work = try AresQueuedWork(queue: DurableTaskQueue(directory: base.appendingPathComponent("queue"), agentID: .ares), repository: container.fileRepository, access: container.authorizedRootAccess, rules: container.ruleCoordinator, policy: policy)
        return Fixture(base: base, source: source, target: target, container: container, root: root, destination: destination, policy: policy, work: work, service: AresRuntimeService(container: container, work: work))
    }
    func grant(_ f: Fixture, client: LocalMCPClient, roots: [UUID], metadata: Bool = true, sourceBytes: Int64 = 1_073_741_824) async throws -> LocalAccessGrant {
        var draft = LocalAccessDraft(); draft.client = client; draft.roots = roots; draft.maximumSourceBytes = sourceBytes; draft.dataClass = metadata ? .fileMetadata : .aggregate
        draft.capabilities = metadata ? f.policy.capabilities : ["file.list_roots", "file.scan", "file.analyze_storage"]
        let plan = try await f.policy.request(draft, client: client)
        return try await f.policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
    }
    func finish(_ f: Fixture, _ id: UUID) async throws -> DurableTask {
        for _ in 0..<500 {
            if let task = try await f.work.queue.task(id), task.status.isTerminal { return task }
            try await Task.sleep(nanoseconds: 10_000_000)
        }; throw LocalRuntimeFailure.unavailable
    }
    func testRootsTasksAndInternalRequestAreIsolatedByClient() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try await grant(f, client: .codex, roots: [f.root.id])
        _ = try await grant(f, client: .deepseekHarness, roots: [f.root.id], metadata: false)
        let data = try await f.service.handle(role: .mcp, clientID: .codex, request: LocalRPCRequest(domain: "ares", operation: "repo.roots", payload: Data("{}".utf8)))
        let roots = try LocalWire.decode([AuthorizedRoot].self, data)
        XCTAssertEqual(roots.map(\.id), [f.root.id]); XCTAssertEqual(roots[0].relativePathHint, "")
        let task = try await f.work.submit(AresSubmission(capability: "file.scan", job: AresJob(rootID: f.root.id), key: "private-task"), role: .mcp, clientID: .codex)
        _ = try await finish(f, task.id)
        let own = try await f.work.authorizedTask(task.id, role: .mcp, clientID: .codex)
        XCTAssertTrue(own.request.isEmpty); XCTAssertTrue(own.resources.isEmpty); XCTAssertNil(own.lease)
        do { _ = try await f.work.authorizedTask(task.id, role: .mcp, clientID: .deepseekHarness); XCTFail("Cross task") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        do { _ = try await f.work.submit(AresSubmission(capability: "file.search", job: AresJob(rootID: f.root.id), key: "metadata"), role: .mcp, clientID: .deepseekHarness); XCTFail("Aggregate search") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        await f.work.shutdown()
    }
    func testPlanIsBoundToClientAndRevokedGrantEvenAfterSameRegrant() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let old = try await grant(f, client: .codex, roots: [f.root.id, f.destination.id])
        _ = try await grant(f, client: .deepseekHarness, roots: [f.root.id, f.destination.id])
        var rule = AutomationRule(); rule.rootID = f.root.id
        var copy = RuleAction(kind: .copy); copy.destinationRootID = f.destination.id; rule.actions = [copy]
        _ = try await f.work.governance.save(rule, fromMCP: false)
        let preview = try await f.work.submit(AresSubmission(capability: "rule.preview", job: AresJob(ruleID: rule.id), key: "preview"), role: .mcp, clientID: .codex)
        let completed = try await finish(f, preview.id); let plan = try LocalWire.decode(RulePlanSummary.self, completed.result!)
        _ = try await f.work.governance.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
        do { _ = try await f.work.submit(AresSubmission(capability: "rule.run", job: AresJob(ruleID: rule.id, planID: plan.id), key: "stolen"), role: .mcp, clientID: .deepseekHarness); XCTFail("Stolen plan") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        _ = try await f.policy.revoke(old.id, role: .gui)
        _ = try await grant(f, client: .codex, roots: [f.root.id, f.destination.id])
        do { _ = try await f.work.governance.checkedPlan(plan.id); XCTFail("Revived plan") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.target.appendingPathComponent("Ares Results").path))
        await f.work.shutdown()
    }
    func testDestinationOutsideScopeCannotBeAdmitted() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try await grant(f, client: .codex, roots: [f.root.id])
        var rule = AutomationRule(); rule.rootID = f.root.id
        var copy = RuleAction(kind: .copy); copy.destinationRootID = f.destination.id; rule.actions = [copy]
        _ = try await f.work.governance.save(rule, fromMCP: false)
        do { _ = try await f.work.submit(AresSubmission(capability: "rule.preview", job: AresJob(ruleID: rule.id), key: "outside"), role: .mcp, clientID: .codex); XCTFail("Expanded destination") } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        await f.work.shutdown()
    }
    func testMetadataDoesNotSpendContentByteBudgetAndHashCannotBypassIt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        try Data("private-data".utf8).write(to: f.source.appendingPathComponent("duplicate.txt"))
        _ = try await grant(f, client: .codex, roots: [f.root.id], sourceBytes: 1)
        let scan = try await f.work.submit(AresSubmission(capability: "file.scan", job: AresJob(rootID: f.root.id), key: "metadata-only"), role: .mcp, clientID: .codex)
        let indexed = try await finish(f, scan.id); XCTAssertEqual(indexed.status, .completed)
        let hash = try await f.work.submit(AresSubmission(capability: "file.compute_duplicates", job: AresJob(rootID: f.root.id), key: "content-budget"), role: .mcp, clientID: .codex)
        let denied = try await finish(f, hash.id); XCTAssertEqual(denied.status, .failed); XCTAssertEqual(denied.errorCode, .permissionDenied)
        let snapshot = try await f.container.fileRepository.currentSnapshot(rootID: f.root.id); XCTAssertFalse(snapshot?.header.hashesComputed ?? true)
        await f.work.shutdown()
    }
    func testContentConditionPreviewCannotReadBeyondClientByteBudget() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try await grant(f, client: .codex, roots: [f.root.id], sourceBytes: 1)
        var rule = AutomationRule(); rule.rootID = f.root.id; rule.event = .textContains; rule.eventValue = "private"
        rule.allowContentReading = true; rule.actions = [RuleAction(kind: .log)]
        _ = try await f.work.governance.save(rule, fromMCP: false)
        let task = try await f.work.submit(AresSubmission(capability: "rule.preview", job: AresJob(ruleID: rule.id), key: "condition-budget"), role: .mcp, clientID: .codex)
        let final = try await finish(f, task.id); XCTAssertEqual(final.status, .failed); XCTAssertEqual(final.errorCode, .permissionDenied)
        let plans = try await f.work.governance.plans(); XCTAssertTrue(plans.isEmpty)
        await f.work.shutdown()
    }
    func testRevocationDuringRealEnumerationStopsBeforeFullWalk() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        for i in 0..<220 { try Data().write(to: f.source.appendingPathComponent("file-\(i).txt")) }
        let permission = try await grant(f, client: .codex, roots: [f.root.id])
        let ticket = try await f.policy.authorize(client: .codex, capability: "file.scan", roots: [f.root.id])
        let observation = WalkObservation()
        do {
            _ = try await FileIndexingService().scan(root: f.root, rootURL: f.source) { progress in
                await observation.set(progress.indexedFileCount)
                _ = try await f.policy.revoke(permission.id, role: .gui)
                _ = try await f.policy.check(ticket)
            }
            XCTFail("Walk continued after revoke")
        } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let count = await observation.count; XCTAssertEqual(count, 100)
        XCTAssertEqual(try String(contentsOf: f.source.appendingPathComponent("private-name.txt")), "private-data")
        await f.work.shutdown()
    }
}
private actor WalkObservation { private(set) var count = 0; func set(_ count: Int) { self.count = count } }
