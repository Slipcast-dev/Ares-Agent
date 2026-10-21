import Foundation
import XCTest
@testable import FileOrganizerCore

/// Контрольный workload проверяет сам pager без файлового обхода. Он не
/// подменяет end-to-end MCP benchmark: verify/root grants здесь не вызываются.
final class SnapshotPagingPerformanceTests: XCTestCase {
    func testAllPagesMatchIndependentOrdering() throws { try traverse(count: 10_000) }
    func testAllPagesOfHundredThousandRecords() throws { try traverse(count: 100_000) }
    private func traverse(count: Int) throws {
        let base = URL(fileURLWithPath: "/private/tmp/ares-page-bench-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let container = AppContainer(databaseURL: base.appendingPathComponent("store.sqlite"), allowLocalClient: false)
        let root = UUID()
        let records = (0..<count).map { index in
            FileRecord(rootID: root, relativePath: String(format: "%05d-Ω.txt", index), fileName: "file",
                fileExtension: "txt", byteSize: Int64(index % 37), createdAt: nil, modifiedAt: nil,
                typeIdentifier: nil, contentHash: String(format: "%064x", index % 50))
        }
        let snapshot = FileIndexSnapshot(header: FileSnapshotHeader(id: UUID(), rootID: root, generation: 1,
            indexedAt: Date(), fileCount: records.count, totalByteSize: records.reduce(0) { $0 + $1.byteSize },
            skippedCount: 0, hashesComputed: true, hashesVerifiedAt: Date()), records: records)
        let pager = FileSnapshotOperations(repository: container.fileRepository, access: container.authorizedRootAccess)
        for operation in ["file.search", "file.analyze_storage", "file.find_duplicates"] {
            let expected: [FileRecord]
            switch operation {
            case "file.search": expected = records
            case "file.analyze_storage": expected = records.sorted { $0.byteSize == $1.byteSize ? $0.relativePath < $1.relativePath : $0.byteSize > $1.byteSize }
            default: expected = records.sorted { $0.contentHash == $1.contentHash ? $0.relativePath < $1.relativePath : $0.contentHash! < $1.contentHash! }
            }
            let start = ContinuousClock.now
            var cursor: String?, collected: [UUID] = [], pages = 0
            repeat {
                let page = try pager.page(snapshot, operation: operation, job: AresJob(rootID: root, cursor: cursor, pageSize: 100))
                collected += page.records.map(\.id); cursor = page.nextCursor; pages += 1
                XCTAssertEqual(page.totalGroupCount, 50)
                XCTAssertEqual(page.totalDuplicateFileCount, records.count)
                XCTAssertEqual(page.largeFiles.count, 20)
                XCTAssertTrue(page.groups.allSatisfy { $0.totalRecordCount == count / 50 })
                guard pages <= count / 100 else { return XCTFail("Cursor loop") }
            } while cursor != nil
            XCTAssertEqual(pages, count / 100); XCTAssertEqual(collected, expected.map(\.id))
            XCTAssertEqual(Set(collected).count, records.count)
            let elapsed = start.duration(to: .now)
            print("PAGE_BENCH count=\(count) operation=\(operation) elapsed=\(elapsed)")
        }
    }
}
