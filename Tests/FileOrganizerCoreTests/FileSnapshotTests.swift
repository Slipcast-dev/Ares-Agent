import Darwin
import Foundation
@preconcurrency import SQLite3
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import FileOrganizerCore

/// Реальные файлы и SQLite проверяют контракт снимков, а не устройство реализации.
final class FileSnapshotTests: XCTestCase {
    private struct Fixture {
        let base: URL
        let folder: URL
        let container: AppContainer
        let root: AuthorizedRoot
        let queue: DurableTaskQueue
        let work: AresQueuedWork
    }
    private func fixture(count: Int = 3) async throws -> Fixture {
        let base = URL(fileURLWithPath: "/private/tmp/e4a-tests-" + UUID().uuidString)
        let folder = base.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<count { try Data("abc".utf8).write(to: folder.appendingPathComponent(String(format: "%03d.txt", index))) }
        let container = AppContainer(databaseURL: base.appendingPathComponent("domain.sqlite"), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: folder)
        let queue = try DurableTaskQueue(directory: base.appendingPathComponent("queue"), agentID: .ares)
        let work = try AresQueuedWork(queue: queue, repository: container.fileRepository, access: container.authorizedRootAccess, rules: container.ruleCoordinator)
        return Fixture(base: base, folder: folder, container: container, root: root, queue: queue, work: work)
    }
    private func run(_ fixture: Fixture, _ capability: String, job: AresJob? = nil) async throws -> DurableTask {
        let task = try await fixture.work.submit(AresSubmission(capability: capability, job: job ?? AresJob(rootID: fixture.root.id), key: UUID().uuidString), role: .mcp)
        for _ in 0..<300 {
            if let result = try await fixture.queue.task(task.id), result.status.isTerminal { return result }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw LocalRuntimeFailure.deadlineExceeded
    }
    private func page(_ task: DurableTask) throws -> FileSnapshotPage {
        XCTAssertEqual(task.status.rawValue, "completed", task.errorCode?.rawValue ?? "")
        return try LocalWire.decode(FileSnapshotPage.self, XCTUnwrap(task.result))
    }
    private func trigger(_ fixture: Fixture, sql: String) throws {
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.base.appendingPathComponent("domain.sqlite").path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    func testSnapshotPersistsAndSearchCursorBindsQueryAndGeneration() async throws {
        let f = try await fixture(count: 205); defer { try? FileManager.default.removeItem(at: f.base) }
        let scan = try await run(f, "file.scan")
        let summary = try LocalWire.decode(ScanSummary.self, XCTUnwrap(scan.result))
        XCTAssertNotNil(summary.snapshotID); XCTAssertEqual(summary.indexGeneration, 1)
        let reopened = SQLiteFileRepository(databaseURL: f.base.appendingPathComponent("domain.sqlite"))
        let saved = try await reopened.currentSnapshot(rootID: f.root.id)
        XCTAssertEqual(saved?.header.id, summary.snapshotID)
        let first = try page(await run(f, "file.search"))
        let second = try page(await run(f, "file.search", job: AresJob(rootID: f.root.id, cursor: first.nextCursor)))
        let last = try page(await run(f, "file.search", job: AresJob(rootID: f.root.id, cursor: second.nextCursor)))
        XCTAssertEqual([first.records.count, second.records.count, last.records.count], [100, 100, 5])
        XCTAssertEqual(Set((first.records + second.records + last.records).map(\.relativePath)).count, 205)
        let mismatch = try await run(f, "file.search", job: AresJob(rootID: f.root.id, query: "txt", cursor: first.nextCursor))
        XCTAssertEqual(mismatch.status.rawValue, "failed")
        XCTAssertEqual(mismatch.errorCode?.rawValue, "INVALID_ARGUMENT")
        let malformed = try await run(f, "file.search", job: AresJob(rootID: f.root.id, cursor: Data("invalid json".utf8).base64EncodedString()))
        XCTAssertEqual(malformed.errorCode?.rawValue, "INVALID_ARGUMENT")
        _ = try await run(f, "file.scan")
        let stale = try await run(f, "file.search", job: AresJob(rootID: f.root.id, cursor: first.nextCursor))
        XCTAssertEqual(stale.errorCode?.rawValue, "STALE_SNAPSHOT")
    }
    func testSeparateHashTaskIncludesEmptyFilesAndPagesOneLargeGroup() async throws {
        let f = try await fixture(count: 205); defer { try? FileManager.default.removeItem(at: f.base) }
        for name in ["empty-a", "empty-b"] { try Data().write(to: f.folder.appendingPathComponent(name)) }
        _ = try await run(f, "file.scan")
        let unknown = try page(await run(f, "file.find_duplicates"))
        XCTAssertFalse(unknown.hashesAvailable); XCTAssertNil(unknown.totalDuplicateFileCount)
        let computed = try page(await run(f, "file.compute_duplicates"))
        XCTAssertEqual(computed.totalDuplicateFileCount, 207); XCTAssertEqual(computed.totalGroupCount, 2)
        var pages = [computed]
        while let cursor = pages.last?.nextCursor {
            pages.append(try page(await run(f, "file.find_duplicates", job: AresJob(rootID: f.root.id, cursor: cursor))))
        }
        let records = pages.flatMap(\.records)
        XCTAssertEqual(records.count, 207); XCTAssertEqual(Set(records.map(\.id)).count, 207)
        // Независимые опубликованные SHA-256 test vectors: abc и пустая строка.
        XCTAssertEqual(Set(records.filter { $0.byteSize == 3 }.compactMap(\.contentHash)), ["ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"])
        XCTAssertEqual(Set(records.filter { $0.byteSize == 0 }.compactMap(\.contentHash)), ["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"])
        XCTAssertTrue(pages.flatMap(\.groups).contains { $0.totalRecordCount == 205 })
        XCTAssertEqual(try Data(contentsOf: f.folder.appendingPathComponent("000.txt")), Data("abc".utf8))
    }
    func testChangedOrNewFileMakesStorageAndHashStale() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try await run(f, "file.scan")
        let storage = try page(await run(f, "file.analyze_storage"))
        XCTAssertEqual(storage.totalByteSize, 9); XCTAssertEqual(storage.freshness, "verified")
        let file = f.folder.appendingPathComponent("000.txt")
        let old = try VerifiedFileReader.capture(root: f.folder, relative: "000.txt")
        let originalDate = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try Data("xyz".utf8).write(to: file)
        if let originalDate { try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path) }
        XCTAssertNotEqual(try VerifiedFileReader.capture(root: f.folder, relative: "000.txt"), old)
        let stale = try await run(f, "file.compute_duplicates")
        XCTAssertEqual(stale.errorCode?.rawValue, "STALE_SNAPSHOT")
        let retained = try await f.container.fileRepository.currentSnapshot(rootID: f.root.id)
        XCTAssertEqual(retained?.header.hashesComputed, false)
        _ = try await run(f, "file.scan")
        try Data("new".utf8).write(to: f.folder.appendingPathComponent("new.txt"))
        let changed = try await run(f, "file.analyze_storage")
        XCTAssertEqual(changed.errorCode?.rawValue, "STALE_SNAPSHOT")
    }
    func testDescriptorReaderRejectsReplacementTraversalAndSymlink() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let file = f.folder.appendingPathComponent("000.txt")
        let version = try VerifiedFileReader.capture(root: f.folder, relative: "000.txt")
        try FileManager.default.removeItem(at: file); try Data("abc".utf8).write(to: file)
        XCTAssertThrowsError(try VerifiedFileReader.hash(root: f.folder, relative: "000.txt", expected: version))
        let outside = f.base.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: f.folder.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: f.folder.appendingPathComponent("leaf"), withDestinationURL: file)
        for path in ["link/secret", "leaf", "../outside/secret", "/000.txt", "a/../000.txt"] {
            XCTAssertThrowsError(try VerifiedFileReader.capture(root: f.folder, relative: path))
        }
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("secret")), Data("secret".utf8))
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertThrowsError(try VerifiedFileReader.hash(root: f.folder, relative: "000.txt", expected: version))
    }
    func testCancelledHashStopsBeforePublishing() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let version = try VerifiedFileReader.capture(root: f.folder, relative: "000.txt")
        let task = Task { () throws -> String in
            // Отменяем сам task непосредственно перед reader, без отменяемого sleep.
            withUnsafeCurrentTask { $0?.cancel() }
            return try VerifiedFileReader.hash(root: f.folder, relative: "000.txt", expected: version)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled hash returned bytes") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testPublicationAndHashCommitRollbackAsWholeTransactions() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        _ = try await run(f, "file.scan")
        let initial = try await f.container.fileRepository.currentSnapshot(rootID: f.root.id)
        let first = try XCTUnwrap(initial)
        try trigger(f, sql: "CREATE TRIGGER fixture_reject BEFORE UPDATE ON file_snapshot_state BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        let failedHash = try await run(f, "file.compute_duplicates")
        XCTAssertEqual(failedHash.status.rawValue, "failed")
        let unchanged = try await f.container.fileRepository.currentSnapshot(rootID: f.root.id)
        let legacy = try await f.container.fileRepository.records(forRootID: f.root.id)
        XCTAssertEqual(unchanged?.header.hashesComputed, false); XCTAssertTrue(legacy.allSatisfy { $0.contentHash == nil })
        try Data("new".utf8).write(to: f.folder.appendingPathComponent("new"))
        let failedScan = try await run(f, "file.scan")
        XCTAssertEqual(failedScan.status.rawValue, "failed")
        let kept = try await f.container.fileRepository.currentSnapshot(rootID: f.root.id)
        let count = try await f.container.fileRepository.indexedFileCount(forRootID: f.root.id)
        XCTAssertEqual(kept?.header.id, first.header.id); XCTAssertEqual(count, 3)
    }
    func testRevocationRemovesSnapshotsAndDeniesOldMCPTaskResults() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        let scan = try await run(f, "file.scan")
        _ = try page(await run(f, "file.search")) // Прогреваем cache до revoke.
        try await f.container.fileRepository.removeRoot(withID: f.root.id)
        let snapshot = try await f.container.fileRepository.currentSnapshot(rootID: f.root.id)
        XCTAssertNil(snapshot)
        do { _ = try await run(f, "file.search"); XCTFail("Revoked root returned cached page") }
        catch { XCTAssertTrue([LocalRuntimeFailure.invalidRequest, .denied].contains(error as? LocalRuntimeFailure ?? .operationFailed)) }
        do { _ = try await f.work.authorizedTask(scan.id, role: .mcp); XCTFail("Revoked root disclosed result") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.folder.appendingPathComponent("000.txt").path))
    }
}
