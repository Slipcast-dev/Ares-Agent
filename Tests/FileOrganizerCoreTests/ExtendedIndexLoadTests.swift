// Этот opt-in набор компилируется только специальной проверочной командой.
// Проверочный пакет добавляет forwarding extension рядом с private pager.
// Рабочие исходники/API, runtime grants, XPC и TCC при этом не меняются.
#if ECOSYSTEM_EXTENDED_LOAD
import Darwin
import Foundation
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import FileOrganizerCore

/// Независимый oracle — заранее созданный набор путей и опубликованные SHA-256
/// vectors. Код pager не копируется в тест и не подменяется mock-реализацией.
final class ExtendedIndexLoadTests: XCTestCase {
    private let fm = FileManager.default
    private let abcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func note(_ name: String, _ value: [String: Any]) throws {
        guard let path = ProcessInfo.processInfo.environment["ECOSYSTEM_LOAD_REPORT_DIRECTORY"], path.hasPrefix("/") else {
            throw NSError(domain: "ExtendedLoad", code: 1)
        }
        let directory = URL(fileURLWithPath: path)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }
    private func base() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/ecosystem-index-load-" + UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func container(_ base: URL) throws -> AppContainer {
        let value = AppContainer(databaseURL: base.appendingPathComponent("domain.sqlite"), allowLocalClient: false)
        try value.preparePersistentStore()
        return value
    }
    private func saved(_ container: AppContainer, root: AuthorizedRoot, folder: URL) async throws -> FileIndexSnapshot {
        let scan = try await FileIndexingService().scan(root: root, rootURL: folder) { _ in }
        return try await container.fileRepository.publishSnapshot(records: scan.records, summary: scan.summary)
    }
    private func pager(_ container: AppContainer) -> FileSnapshotOperations {
        FileSnapshotOperations(repository: container.fileRepository, access: container.authorizedRootAccess)
    }
    private func work(_ container: AppContainer, base: URL) throws -> AresQueuedWork {
        try AresQueuedWork(queue: DurableTaskQueue(directory: base.appendingPathComponent("queue"), agentID: .ares),
            repository: container.fileRepository, access: container.authorizedRootAccess, rules: container.ruleCoordinator)
    }
    private func execute(_ work: AresQueuedWork, capability: String, job: AresJob) async throws -> DurableTask {
        let task = try await work.submit(AresSubmission(capability: capability, job: job, key: UUID().uuidString), role: .mcp)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let result = try await work.queue.task(task.id), result.status.isTerminal { return result }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LocalRuntimeFailure.deadlineExceeded
    }

    func testAllThousandPagesOfEachViewOnRealPersisted100kIndex() async throws {
        let base = try base(); defer { try? fm.removeItem(at: base) }
        let folder = base.appendingPathComponent("Unicode Ω")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        var expected = Set<String>()
        for group in 0..<100 {
            let directory = folder.appendingPathComponent(String(format: "%03d", group))
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            for item in 0..<1000 {
                let name = String(format: "%04d.txt", item)
                try Data("abc".utf8).write(to: directory.appendingPathComponent(name))
                expected.insert(directory.lastPathComponent + "/" + name)
            }
        }
        let container = try container(base)
        let root = try await container.authorizedRootAccess.addRoot(from: folder)
        let start = Date()
        _ = try await saved(container, root: root, folder: folder)
        // Повторное открытие SQLite доказывает, что страницы читают сохранённый
        // индекс, а не только массив, возвращённый сканером.
        let reopened = SQLiteFileRepository(databaseURL: base.appendingPathComponent("domain.sqlite"))
        let current = try await reopened.currentSnapshot(rootID: root.id)
        let snapshot = try XCTUnwrap(current)
        XCTAssertEqual(snapshot.header.fileCount, 100_000)
        XCTAssertEqual(snapshot.header.totalByteSize, 300_000)
        XCTAssertEqual(snapshot.header.skippedCount, 0)
        XCTAssertEqual(Set(snapshot.records.map(\.relativePath)), expected)
        let scanSeconds = Date().timeIntervalSince(start)
        var timings: [String: Double] = [:]
        func traverse(_ snapshot: FileIndexSnapshot, operation: String) throws {
            let started = Date()
            var cursor: String?, seen = Set<String>(), ids = Set<UUID>(), cursors = Set<String>()
            var pages = 0, bytes: Int64 = 0
            repeat {
                let page = try pager(container).verificationPage(snapshot, operation: operation,
                    job: AresJob(rootID: root.id, cursor: cursor, pageSize: 100))
                pages += 1
                XCTAssertEqual(page.snapshot.id, snapshot.header.id)
                XCTAssertEqual(page.fileCount, 100_000)
                XCTAssertEqual(page.records.count, 100)
                XCTAssertEqual(page.freshness, "verified")
                for row in page.records {
                    XCTAssertTrue(expected.contains(row.relativePath))
                    XCTAssertTrue(seen.insert(row.relativePath).inserted, "Duplicate path across pages")
                    XCTAssertTrue(ids.insert(row.id).inserted, "Duplicate identity across pages")
                    bytes += row.byteSize
                }
                if operation == "file.find_duplicates" {
                    XCTAssertEqual(page.totalDuplicateFileCount, 100_000)
                    XCTAssertEqual(page.totalGroupCount, 1)
                    XCTAssertEqual(page.groups.first?.totalRecordCount, 100_000)
                    XCTAssertTrue(page.records.allSatisfy { $0.contentHash == abcHash })
                }
                cursor = page.nextCursor
                if let cursor { XCTAssertTrue(cursors.insert(cursor).inserted, "Cursor loop") }
                guard pages <= 1000 else { return XCTFail("Pager did not terminate") }
                if pages.isMultiple(of: 100) { print("EXTENDED_LOAD \(operation) \(pages)/1000") }
            } while cursor != nil
            XCTAssertEqual(pages, 1000)
            XCTAssertEqual(seen, expected)
            XCTAssertEqual(ids.count, 100_000)
            XCTAssertEqual(bytes, 300_000)
            timings[operation] = Date().timeIntervalSince(started)
        }
        try traverse(snapshot, operation: "file.search")
        try traverse(snapshot, operation: "file.analyze_storage")
        // Hash каждого реального файла вычисляется самим reader и сверяется
        // с известным abc vector; hashes не генерируются из pager или имени.
        var hashes: [UUID: String] = [:]
        for row in snapshot.records {
            let digest = try VerifiedFileReader.hash(root: folder, relative: row.relativePath, expected: XCTUnwrap(row.version))
            XCTAssertEqual(digest, abcHash); hashes[row.id] = digest
        }
        _ = try await reopened.publishHashes(rootID: root.id, snapshotID: snapshot.header.id, hashes: hashes)
        let hashedValue = try await reopened.currentSnapshot(rootID: root.id)
        let hashed = try XCTUnwrap(hashedValue)
        XCTAssertTrue(hashed.header.hashesComputed)
        try traverse(hashed, operation: "file.find_duplicates")
        // Меняется только fixture: новый scan обязан инвалидировать cursor.
        let first = try pager(container).verificationPage(snapshot, operation: "file.search", job: AresJob(rootID: root.id))
        let next = try await saved(container, root: root, folder: folder)
        XCTAssertThrowsError(try pager(container).verificationPage(next, operation: "file.search", job: AresJob(rootID: root.id, cursor: first.nextCursor))) {
            XCTAssertEqual($0 as? AresFileFailure, .staleSnapshot)
        }
        try note("all-pages", ["files": 100_000, "pagesPerView": 1000, "views": 3,
            "pagesTotal": 3000, "scanPublishReopenSeconds": scanSeconds, "pageSeconds": timings,
            "allPathsExactlyOnce": true, "allHashesMatchIndependentVector": true,
            "newGenerationRejectsOldCursor": true, "transport": "production pager on real persisted snapshot, no per-page RPC freshness scans",
            "userDataTouched": false])
    }

    func testUnreadableEntriesRemainPartialAndHashFailureCannotPublish() async throws {
        let base = try base(); defer { try? fm.removeItem(at: base) }
        let folder = base.appendingPathComponent("files"), blocked = folder.appendingPathComponent("blocked")
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        let good = folder.appendingPathComponent("good.txt"), unreadable = folder.appendingPathComponent("unreadable.txt")
        try Data("abc".utf8).write(to: good); try Data("abc".utf8).write(to: unreadable)
        try Data("abc".utf8).write(to: blocked.appendingPathComponent("hidden.txt"))
        defer { chmod(blocked.path, 0o700); chmod(unreadable.path, 0o600) }
        XCTAssertEqual(chmod(blocked.path, 0), 0); XCTAssertEqual(chmod(unreadable.path, 0), 0)
        let fd = open(unreadable.path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 { close(fd); return XCTFail("Fixture content is readable; permission test invalid") }
        XCTAssertEqual(errno, EACCES)
        let container = try container(base), work = try work(container, base: base)
        let root = try await container.authorizedRootAccess.addRoot(from: folder)
        let scan = try await execute(work, capability: "file.scan", job: AresJob(rootID: root.id))
        XCTAssertEqual(scan.status, .completed)
        let search = try await execute(work, capability: "file.search", job: AresJob(rootID: root.id))
        XCTAssertEqual(search.status, .completed)
        let page = try LocalWire.decode(FileSnapshotPage.self, XCTUnwrap(search.result))
        XCTAssertEqual(page.freshness, "partial")
        XCTAssertGreaterThanOrEqual(page.snapshot.skippedCount, 1)
        XCTAssertTrue(page.records.contains { $0.relativePath == "good.txt" })
        XCTAssertFalse(page.records.contains { $0.relativePath == "blocked/hidden.txt" })
        // На этой ФС O_EVTONLY тоже требует доступа: сканер безопасно
        // исключает unreadable, вместо публикации фиктивной версии/хеша.
        XCTAssertFalse(page.records.contains { $0.relativePath == "unreadable.txt" })
        XCTAssertEqual(page.fileCount, 1)
        XCTAssertGreaterThanOrEqual(page.snapshot.skippedCount, 2)
        XCTAssertEqual(chmod(blocked.path, 0o700), 0); XCTAssertEqual(chmod(unreadable.path, 0o600), 0)
        let indexed = try await execute(work, capability: "file.scan", job: AresJob(rootID: root.id))
        XCTAssertEqual(indexed.status, .completed)
        let before = try await container.fileRepository.currentSnapshot(rootID: root.id)
        XCTAssertEqual(before?.header.fileCount, 3)
        // Меняем только права собственного файла после индексации. Повторная
        // проверка свежести обязана отказать до публикации любых hash updates.
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        let hash = try await execute(work, capability: "file.compute_duplicates", job: AresJob(rootID: root.id))
        XCTAssertEqual(hash.status, .failed)
        XCTAssertEqual(hash.errorCode?.rawValue, "STALE_SNAPSHOT")
        let retained = try await container.fileRepository.currentSnapshot(rootID: root.id)
        XCTAssertEqual(retained?.header.id, before?.header.id)
        XCTAssertEqual(retained?.header.hashesComputed, false)
        XCTAssertTrue(retained?.records.allSatisfy { $0.contentHash == nil } == true)
        XCTAssertEqual(chmod(unreadable.path, 0o600), 0)
        let rescan = try await execute(work, capability: "file.scan", job: AresJob(rootID: root.id))
        XCTAssertEqual(rescan.status, .completed)
        let complete = try await execute(work, capability: "file.compute_duplicates", job: AresJob(rootID: root.id))
        XCTAssertEqual(complete.status, .completed)
        let restored = try LocalWire.decode(FileSnapshotPage.self, XCTUnwrap(complete.result))
        XCTAssertEqual(restored.freshness, "verified"); XCTAssertEqual(restored.fileCount, 3)
        XCTAssertEqual(restored.totalDuplicateFileCount, 3)
        XCTAssertEqual(try Data(contentsOf: good), Data("abc".utf8))
        try note("unreadable", ["realEACCES": true, "partialSnapshot": true, "unreadableEntrySkipped": true, "hashFailureStatus": hash.status.rawValue,
            "hashFailureCode": hash.errorCode?.rawValue ?? "none", "failedHashNotPublished": true,
            "explicitRescanAfterRestoringPermission": true, "systemTCCTest": false])
    }

    private func hdi(_ arguments: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); p.arguments = arguments
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "OwnedCaseImage", code: Int(p.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]) }
    }
    private func caseVolume(sensitive: Bool) async throws {
        let base = try base(); defer { try? fm.removeItem(at: base) }
        let mount = base.appendingPathComponent("volume"), image = base.appendingPathComponent("case.sparseimage")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        try hdi(["create", "-size", "128m", "-type", "SPARSE", "-fs", sensitive ? "HFSX" : "HFS+", "-volname", "E13Case", image.path])
        try hdi(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? hdi(["detach", "-force", mount.path]) }
        var host = stat(), mounted = stat()
        guard lstat(base.path, &host) == 0, lstat(mount.path, &mounted) == 0, host.st_dev != mounted.st_dev else { return XCTFail("Image did not mount") }
        let actual = try mount.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        XCTAssertEqual(actual, sensitive)
        let source = mount.appendingPathComponent("source"), target = mount.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("abc".utf8).write(to: source.appendingPathComponent("Report.txt"))
        // O_EXCL проверяет фактическую семантику ФС, не перезаписывая первый файл.
        let second = open(source.appendingPathComponent("report.txt").path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        if sensitive {
            guard second >= 0 else { return XCTFail("Case-sensitive volume collapsed paths") }
            let data = [UInt8]("xyz".utf8)
            XCTAssertEqual(data.withUnsafeBytes { Darwin.write(second, $0.baseAddress, $0.count) }, 3); close(second)
        } else {
            if second >= 0 { close(second); return XCTFail("Case-insensitive volume admitted alias") }
            XCTAssertEqual(errno, EEXIST)
        }
        let container = try container(base), work = try work(container, base: base)
        let root = try await container.authorizedRootAccess.addRoot(from: source)
        let scan = try await execute(work, capability: "file.scan", job: AresJob(rootID: root.id))
        XCTAssertEqual(scan.status, .completed)
        let search = try await execute(work, capability: "file.search", job: AresJob(rootID: root.id, query: "REPORT.TXT", pageSize: 1))
        let first = try LocalWire.decode(FileSnapshotPage.self, XCTUnwrap(search.result))
        var paths = first.records.map(\.relativePath)
        if let cursor = first.nextCursor {
            let task = try await execute(work, capability: "file.search", job: AresJob(rootID: root.id, query: "REPORT.TXT", cursor: cursor, pageSize: 1))
            let last = try LocalWire.decode(FileSnapshotPage.self, XCTUnwrap(task.result))
            XCTAssertNil(last.nextCursor); paths += last.records.map(\.relativePath)
        }
        XCTAssertEqual(Set(paths), sensitive ? Set(["Report.txt", "report.txt"]) : Set(["Report.txt"]))
        let hash = try await execute(work, capability: "file.compute_duplicates", job: AresJob(rootID: root.id))
        XCTAssertEqual(hash.status, .completed)
        let duplicates = try LocalWire.decode(FileSnapshotPage.self, XCTUnwrap(hash.result))
        XCTAssertEqual(duplicates.totalDuplicateFileCount, 0)
        let version = try VerifiedFileReader.capture(root: source, relative: "Report.txt")
        try SecureRuleIO.copy(root: source, relative: "Report.txt", version: version, destinationRoot: target, name: "Copy.txt")
        if sensitive {
            let other = try VerifiedFileReader.capture(root: source, relative: "report.txt")
            try SecureRuleIO.copy(root: source, relative: "report.txt", version: other, destinationRoot: target, name: "copy.txt")
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Ares Results/copy.txt")), Data("xyz".utf8))
        } else {
            XCTAssertThrowsError(try SecureRuleIO.copy(root: source, relative: "Report.txt", version: version, destinationRoot: target, name: "copy.txt"))
        }
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Ares Results/Copy.txt")), Data("abc".utf8))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Report.txt")), Data("abc".utf8))
        try note(sensitive ? "case-sensitive" : "case-insensitive", ["filesystem": sensitive ? "HFSX" : "HFS+",
            "caseSensitive": sensitive, "caseFoldedSearchKeepsDistinctPaths": true,
            "differentContentNotDuplicateByName": true, "copyCollisionCannotOverwrite": true,
            "userDataTouched": false])
    }
    func testCaseSensitiveNamesStayDistinct() async throws { try await caseVolume(sensitive: true) }
    func testCaseInsensitiveAliasCannotOverwrite() async throws { try await caseVolume(sensitive: false) }
}
#endif
