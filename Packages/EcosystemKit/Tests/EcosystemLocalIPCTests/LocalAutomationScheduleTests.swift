import Foundation
import XCTest
@testable import EcosystemLocalIPC

final class LocalAutomationScheduleTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ecosystem-e7-scheduler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testCatchUpLatestOnlyAndClockRollback() async throws {
        let store = try LocalAutomationScheduleStore(directory: directory())
        let start = date("2026-10-17T10:00:00Z")
        try await store.upsert(.init(trigger: .interval(seconds: 60), createdAt: start))
        let first = try await store.due(now: start.addingTimeInterval(605))
        XCTAssertEqual(first.count, 1); XCTAssertEqual(first.first?.scheduledAt, start.addingTimeInterval(600))
        let again = try await store.due(now: start.addingTimeInterval(720))
        XCTAssertEqual(first, again)
        try await store.acknowledge(first[0], now: start.addingTimeInterval(720))
        let rollback = try await store.due(now: start.addingTimeInterval(600))
        XCTAssertTrue(rollback.isEmpty)
        let next = try await store.due(now: start.addingTimeInterval(780))
        XCTAssertEqual(next.first?.scheduledAt, start.addingTimeInterval(780))
        XCTAssertNotEqual(next.first?.idempotencyKey, first.first?.idempotencyKey)
    }

    func testPendingSurvivesReloadAndAcknowledgeIsIdempotent() async throws {
        let directory = try directory(); let start = date("2026-10-17T10:00:00Z")
        let original = try LocalAutomationScheduleStore(directory: directory)
        try await original.upsert(.init(trigger: .interval(seconds: 30), createdAt: start))
        let slots = try await original.due(now: start.addingTimeInterval(31))
        let reloaded = try LocalAutomationScheduleStore(directory: directory)
        let retry = try await reloaded.due(now: start.addingTimeInterval(80))
        XCTAssertEqual(slots, retry)
        try await reloaded.acknowledge(slots[0], now: start.addingTimeInterval(80))
        try await reloaded.acknowledge(slots[0], now: start.addingTimeInterval(80))
        let empty = try await reloaded.due(now: start.addingTimeInterval(80)); XCTAssertTrue(empty.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("automation-schedule-v1.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSpringDSTMissingTimeRunsAtThreeAM() async throws {
        let store = try LocalAutomationScheduleStore(directory: directory())
        try await store.upsert(.init(trigger: .daily(hour: 2, minute: 30, timeZoneIdentifier: "America/New_York"), createdAt: date("2026-03-08T05:00:00Z")))
        let before = try await store.due(now: date("2026-03-08T06:59:59Z")); XCTAssertTrue(before.isEmpty)
        let due = try await store.due(now: date("2026-03-08T07:00:00Z"))
        XCTAssertEqual(due.first?.scheduledAt, date("2026-03-08T07:00:00Z"))
        try await store.acknowledge(due[0], now: date("2026-03-08T07:00:00Z"))
        let next = try await store.due(now: date("2026-03-09T06:30:00Z"))
        XCTAssertEqual(next.first?.scheduledAt, date("2026-03-09T06:30:00Z"))
    }

    func testFallDSTRepeatedTimeRunsOnlyFirstOccurrence() async throws {
        let store = try LocalAutomationScheduleStore(directory: directory())
        try await store.upsert(.init(trigger: .daily(hour: 1, minute: 30, timeZoneIdentifier: "America/New_York"), createdAt: date("2026-11-01T04:00:00Z")))
        let first = try await store.due(now: date("2026-11-01T05:30:00Z"))
        XCTAssertEqual(first.first?.scheduledAt, date("2026-11-01T05:30:00Z"))
        try await store.acknowledge(first[0], now: date("2026-11-01T05:30:00Z"))
        let repeated = try await store.due(now: date("2026-11-01T06:30:00Z")); XCTAssertTrue(repeated.isEmpty)
    }

    func testManualPauseDropsMissedSlotsAndResumesNext() async throws {
        let store = try LocalAutomationScheduleStore(directory: directory())
        let start = date("2026-10-17T10:00:00Z")
        let schedule = LocalAutomationSchedule(trigger: .interval(seconds: 60), createdAt: start)
        try await store.upsert(schedule)
        _ = try await store.due(now: start.addingTimeInterval(60))
        try await store.setPaused(schedule.id, paused: true, now: start.addingTimeInterval(61))
        let paused = try await store.due(now: start.addingTimeInterval(3600)); XCTAssertTrue(paused.isEmpty)
        try await store.setPaused(schedule.id, paused: false, now: start.addingTimeInterval(3601))
        let resumed = try await store.due(now: start.addingTimeInterval(3601)); XCTAssertTrue(resumed.isEmpty)
        let next = try await store.due(now: start.addingTimeInterval(3660)); XCTAssertEqual(next.count, 1)
    }

    func testFileDebounceWaitsForDelayedCopyEvenBeyondMaximumWait() async throws {
        let store = try LocalAutomationScheduleStore(directory: directory())
        let root = UUID(); let start = date("2026-10-17T10:00:00Z")
        for second in stride(from: 0, through: 120, by: 2) {
            let change = try await store.observe(rootID: root, signature: "size-\(second)", now: start.addingTimeInterval(Double(second)), quietPeriod: 5, maximumWait: 10)
            XCTAssertNil(change)
        }
        let stable = try await store.observe(rootID: root, signature: "size-120", now: start.addingTimeInterval(125), quietPeriod: 5, maximumWait: 10)
        XCTAssertNotNil(stable)
        try await store.acknowledgeChange(stable!)
        let duplicate = try await store.observe(rootID: root, signature: "size-120", now: start.addingTimeInterval(150)); XCTAssertNil(duplicate)
    }

    func testUnavailableRootAndReloadDoNotReportEmptyOrDuplicate() async throws {
        let directory = try directory(); let store = try LocalAutomationScheduleStore(directory: directory)
        let root = UUID(); let start = date("2026-10-17T10:00:00Z")
        _ = try await store.observe(rootID: root, signature: "version-a", now: start)
        let pending = try await store.observe(rootID: root, signature: "version-a", now: start.addingTimeInterval(6))
        let unavailable = try await store.observe(rootID: root, signature: nil, now: start.addingTimeInterval(7)); XCTAssertNil(unavailable)
        let reloaded = try LocalAutomationScheduleStore(directory: directory)
        let retry = try await reloaded.observe(rootID: root, signature: "version-a", now: start.addingTimeInterval(10)); XCTAssertEqual(pending, retry)
        try await reloaded.acknowledgeChange(retry!)
        let duplicate = try await reloaded.observe(rootID: root, signature: "version-a", now: start.addingTimeInterval(16)); XCTAssertNil(duplicate)
        _ = try await reloaded.observe(rootID: root, signature: "version-b", now: start.addingTimeInterval(20))
        let changed = try await reloaded.observe(rootID: root, signature: "version-b", now: start.addingTimeInterval(26))
        XCTAssertNotEqual(changed?.idempotencyKey, pending?.idempotencyKey)
    }

    func testOnceAndWeeklyUseStableSlots() async throws {
        let store = try LocalAutomationScheduleStore(directory: directory())
        let start = date("2026-10-17T10:00:00Z")
        let once = LocalAutomationSchedule(trigger: .once(at: start.addingTimeInterval(60)), createdAt: start)
        try await store.upsert(once)
        let onceSlot = try await store.due(now: start.addingTimeInterval(600))
        XCTAssertEqual(onceSlot.first?.scheduledAt, start.addingTimeInterval(60))
        try await store.acknowledge(onceSlot[0], now: start.addingTimeInterval(600))
        let later = try await store.due(now: start.addingTimeInterval(3600)); XCTAssertTrue(later.isEmpty)
        // Независимое ожидаемое значение: воскресенье 1 ноября — смена DST.
        let weekly = LocalAutomationSchedule(trigger: .weekly(weekday: 1, hour: 1, minute: 30, timeZoneIdentifier: "America/New_York"), createdAt: date("2026-10-30T00:00:00Z"))
        try await store.upsert(weekly)
        let weeklySlot = try await store.due(now: date("2026-11-01T06:30:00Z"))
        XCTAssertEqual(weeklySlot.first?.scheduledAt, date("2026-11-01T05:30:00Z"))
    }

    func testRecoveryWithoutCatchUpSkipsMissedButPreservesPending() async throws {
        let store = try LocalAutomationScheduleStore(directory: directory()); let start = date("2026-10-17T10:00:00Z")
        try await store.upsert(.init(trigger: .interval(seconds: 60), createdAt: start, catchUpOnce: false))
        let recovered = try await store.due(now: start.addingTimeInterval(600), recovering: true); XCTAssertTrue(recovered.isEmpty)
        let pending = try await store.due(now: start.addingTimeInterval(660)); XCTAssertEqual(pending.count, 1)
        let recoveredPending = try await store.due(now: start.addingTimeInterval(700), recovering: true)
        XCTAssertEqual(recoveredPending, pending)
    }

    func testPrivateStateRejectsSymlinkAndUnknownVersion() throws {
        let directory = try directory(); let file = directory.appendingPathComponent("automation-schedule-v1.json")
        let target = directory.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try LocalAutomationScheduleStore(directory: directory))
        try FileManager.default.removeItem(at: file)
        try Data("{\"version\":2,\"schedules\":[],\"observations\":{}}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try LocalAutomationScheduleStore(directory: directory))
    }

    func testBoundsRejectInvalidTriggersAndExcessRoots() async throws {
        let store = try LocalAutomationScheduleStore(directory: directory()); let now = Date()
        do { try await store.upsert(.init(trigger: .interval(seconds: 29), createdAt: now)); XCTFail("Короткий интервал должен отклоняться") } catch {}
        do { try await store.upsert(.init(trigger: .daily(hour: 24, minute: 0, timeZoneIdentifier: "America/New_York"), createdAt: now)); XCTFail("Неверный час должен отклоняться") } catch {}
        do { try await store.upsert(.init(trigger: .daily(hour: 10, minute: 0, timeZoneIdentifier: "Unknown/Zone"), createdAt: now)); XCTFail("Неизвестный пояс должен отклоняться") } catch {}
        for _ in 0..<128 { _ = try await store.observe(rootID: UUID(), signature: "a", now: now) }
        do { _ = try await store.observe(rootID: UUID(), signature: "a", now: now); XCTFail("Хранилище корней должно быть ограничено") } catch {}
        do { _ = try await store.observe(rootID: UUID(), signature: String(repeating: "a", count: 257), now: now); XCTFail("Fingerprint должен быть ограничен") } catch {}
    }
}
