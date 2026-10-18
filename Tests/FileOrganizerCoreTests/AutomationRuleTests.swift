import Foundation
import XCTest
import AppKit
@testable import FileOrganizerCore

final class AutomationRuleTests: XCTestCase {
    func testPartialFailureIsVisibleAndRetrySkipsCompletedAction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.txt")
        try Data("unchanged".utf8).write(to: source)
        let container = AppContainer(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: directory)
        var rule = AutomationRule(); rule.rootID = root.id
        rule.conditions.extensions = ["txt"]
        // У копирования намеренно отсутствует разрешённая папка назначения.
        rule.actions = [RuleAction(kind: .log), RuleAction(kind: .copy), RuleAction(kind: .log)]
        let first = try await container.ruleCoordinator.run(rule)
        XCTAssertEqual(first.status, "partial_or_failed")
        XCTAssertEqual(first.results.map(\.status), ["completed", "failed", "skipped"])
        let retry = try await container.ruleCoordinator.run(rule)
        XCTAssertEqual(retry.results.map(\.status), ["skipped", "failed", "skipped"])
        XCTAssertEqual(try Data(contentsOf: source), Data("unchanged".utf8))
    }
    private func fixture() -> RuleFileSnapshot {
        RuleFileSnapshot(relativePath: "incoming/report.pdf", identity: "1", byteSize: 200, modifiedAt: Date(), createdAt: Date(), tags: ["Работа"], firstSeenAt: Date(), stableSince: Date(), isDirectory: false)
    }
    func testConditionsAndExclusionsAreNotBypassedByOR() {
        var rule = AutomationRule()
        rule.conditions.extensions = ["PDF"]
        rule.conditions.minimumBytes = 1000
        XCTAssertFalse(RuleMatching.matches(fixture(), rule: rule))
        rule.conditions.allConditions = false
        XCTAssertTrue(RuleMatching.matches(fixture(), rule: rule))
        rule.conditions.excludedPaths = ["incoming"]
        XCTAssertFalse(RuleMatching.matches(fixture(), rule: rule))
        XCTAssertTrue(RuleMatching.wildcard("invoice-12.pdf", pattern: "invoice-??.pdf"))
        XCTAssertFalse(RuleMatching.wildcard("invoice-123.pdf", pattern: "invoice-??.pdf"))
        XCTAssertFalse(RuleMatching.wildcard(String(repeating: "a", count: 200), pattern: String(repeating: "*a", count: 100) + "b"))
    }
    func testRulesAndHistorySurviveNewRepository() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppContainer(databaseURL: url)
        try store.preparePersistentStore()
        var rule = AutomationRule(); rule.name = "Test"; rule.rootID = UUID()
        try await store.fileRepository.saveRuleObject(rule, id: rule.id.uuidString, table: .rules)
        var run = RuleRun(rule: rule, origin: "test"); run.status = "completed"
        try await store.fileRepository.saveRuleObject(run, id: run.id.uuidString, table: .runs)
        let reopened = SQLiteFileRepository(databaseURL: url)
        let rules = try await reopened.ruleObjects(AutomationRule.self, table: .rules)
        let history = try await reopened.ruleObjects(RuleRun.self, table: .runs)
        XCTAssertEqual(rules, [rule])
        XCTAssertEqual(history.first?.id, run.id)
        XCTAssertFalse(rules[0].enabled)
    }
    func testTagsPreserveUnrelatedValues() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("tags".utf8).write(to: url)
        let actions = RuleFileActions()
        try await actions.updateTag("Existing", at: url, remove: false)
        try await actions.updateTag("New", at: url, remove: false)
        try await actions.updateTag("New", at: url, remove: false)
        var tags = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertEqual(Set(tags), ["Existing", "New"])
        try await actions.updateTag("New", at: url, remove: true)
        tags = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        XCTAssertEqual(tags, ["Existing"])
    }
    func testArchiveAndCopyPreserveSourceAndRejectOverwrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("sample.txt")
        let copy = directory.appendingPathComponent("copy.txt")
        let archive = directory.appendingPathComponent("sample.zip")
        let content = Data("independent-test-content".utf8)
        try content.write(to: source)
        let actions = RuleFileActions()
        try await actions.copy(source: source, destination: copy)
        XCTAssertEqual(try Data(contentsOf: copy), content)
        try await actions.archive(source: source, destination: archive)
        XCTAssertEqual(try Data(contentsOf: source), content)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        do { try await actions.copy(source: source, destination: copy); XCTFail("Перезапись должна быть запрещена") }
        catch { XCTAssertEqual(error as? RuleExecutionError, .destinationExists) }
        // Независимо извлекаем ZIP и сравниваем данные, а не только статус ditto.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.arguments = ["-p", archive.path, "sample.txt"]
        try process.run()
        let extracted = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(extracted, content)
    }
    func testContentRequiresConsentAndUsesLocalText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Договор на услуги".utf8).write(to: url)
        let analyzer = RuleContentAnalyzer()
        do { _ = try await analyzer.matches(url: url, event: .textContains, value: "Договор", consent: false); XCTFail("Требуется согласие") } catch {}
        let match = try await analyzer.matches(url: url, event: .documentType, value: "договор", consent: true)
        XCTAssertTrue(match)
    }

    func testCoordinatorDeduplicatesAndRevocationDisablesRule() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let container = AppContainer(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: directory)
        var rule = AutomationRule(); rule.rootID = root.id; rule.enabled = true
        rule.conditions.extensions = ["txt"]
        rule.actions = [RuleAction(kind: .log)]
        try await container.fileRepository.saveRuleObject(rule, id: rule.id.uuidString, table: .rules)
        let matches = try await container.ruleCoordinator.check(rule)
        XCTAssertEqual(matches.map(\.relativePath), ["source.txt"])
        let first = try await container.ruleCoordinator.run(rule)
        let second = try await container.ruleCoordinator.run(rule)
        XCTAssertEqual(first.results.first?.status, "completed")
        XCTAssertEqual(second.results.first?.status, "skipped")
        try await container.fileRepository.removeRoot(withID: root.id)
        let stored = try await container.fileRepository.ruleObjects(AutomationRule.self, table: .rules)
        XCTAssertFalse(stored[0].enabled)
        // Поздний результат наблюдения не возвращает индекс после отзыва доступа.
        try await container.fileRepository.upsertRuleFile(matches[0], rootID: root.id)
        let recordsAfterRevocation = try await container.fileRepository.records(forRootID: root.id)
        XCTAssertTrue(recordsAfterRevocation.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    func testObservationWaitsForStableNewFileAndDoesNotRepeat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = AppContainer(databaseURL: directory.appendingPathComponent("metadata.sqlite"))
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: directory)
        var rule = AutomationRule(); rule.rootID = root.id; rule.enabled = true; rule.event = .arrived
        rule.conditions.extensions = ["txt"]
        try await container.fileRepository.saveRuleObject(rule, id: rule.id.uuidString, table: .rules)
        try await container.ruleCoordinator.poll(appLaunch: true)
        try Data("new".utf8).write(to: directory.appendingPathComponent("new.txt"))
        try await container.ruleCoordinator.poll()
        let waiting = try await container.fileRepository.ruleObjects(RuleRun.self, table: .runs)
        XCTAssertTrue(waiting.isEmpty)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        try await container.ruleCoordinator.poll()
        try await container.ruleCoordinator.poll()
        let history = try await container.fileRepository.ruleObjects(RuleRun.self, table: .runs)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].matchedCount, 1)
        XCTAssertEqual(history[0].status, "completed")
        let state = try await container.fileRepository.ruleObject(RuleObservation.self, id: rule.id.uuidString, table: .observations)
        XCTAssertNotNil(state?.files.first(where: { $0.relativePath == "new.txt" })?.firstSeenAt)
    }

    func testExecutionLockRejectsConcurrentWriter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lock")
        defer { try? FileManager.default.removeItem(at: url) }
        let lock = RuleExecutionLock(url: url)
        let descriptor = try lock.acquire()
        XCTAssertThrowsError(try RuleExecutionLock(url: url).acquire())
        lock.release(descriptor)
        let next = try lock.acquire(); lock.release(next)
    }

    func testRuleChainStopsCycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: directory.appendingPathComponent("test.txt"))
        let container = AppContainer(databaseURL: directory.appendingPathComponent("store.sqlite"))
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: directory)
        var first = AutomationRule(); first.rootID = root.id; first.enabled = true; first.conditions.extensions = ["txt"]
        var second = first; second.id = UUID()
        var toSecond = RuleAction(kind: .runRule); toSecond.nextRuleID = second.id
        var toFirst = RuleAction(kind: .runRule); toFirst.nextRuleID = first.id
        first.actions = [toSecond]; second.actions = [toFirst]
        try await container.fileRepository.saveRuleObject(first, id: first.id.uuidString, table: .rules)
        try await container.fileRepository.saveRuleObject(second, id: second.id.uuidString, table: .rules)
        _ = try await container.ruleCoordinator.run(first)
        let history = try await container.fileRepository.ruleObjects(RuleRun.self, table: .runs)
        XCTAssertEqual(history.count, 2)
        XCTAssertTrue(history.contains { $0.ruleID == second.id && $0.status == "partial_or_failed" })
    }

    func testOnceScheduleAndExactDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt"] { try Data("same".utf8).write(to: directory.appendingPathComponent(name)) }
        try Data("else".utf8).write(to: directory.appendingPathComponent("c.txt"))
        let container = AppContainer(databaseURL: directory.appendingPathComponent("store.sqlite"))
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: directory)
        var duplicate = AutomationRule(); duplicate.rootID = root.id; duplicate.event = .duplicate
        duplicate.conditions.extensions = ["txt"]
        let result = try await container.ruleCoordinator.run(duplicate)
        XCTAssertEqual(result.matchedCount, 2)
        var scheduled = AutomationRule(); scheduled.rootID = root.id; scheduled.enabled = true
        scheduled.event = .scheduled; scheduled.schedule = .once; scheduled.catchUpOnce = true
        scheduled.scheduleDate = Date().addingTimeInterval(-100); scheduled.conditions.extensions = ["txt"]
        try await container.fileRepository.saveRuleObject(scheduled, id: scheduled.id.uuidString, table: .rules)
        try await container.ruleCoordinator.poll(appLaunch: true)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        try await container.ruleCoordinator.poll()
        try await container.ruleCoordinator.poll()
        let history = try await container.fileRepository.ruleObjects(RuleRun.self, table: .runs)
        XCTAssertEqual(history.filter { $0.ruleID == scheduled.id }.count, 1)
    }

    @MainActor
    func testLocalOCRReadsGeneratedFixture() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = NSImage(size: NSSize(width: 800, height: 180), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSAttributedString(string: "INVOICE TEST 4821", attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 30, y: 60))
            return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let found = try await RuleContentAnalyzer().matches(url: url, event: .imageText, value: "INVOICE", consent: true)
        XCTAssertTrue(found)
    }
}
