import Foundation
import XCTest
@testable import FileOrganizerCore

final class FileSnapshotViewCacheTests: XCTestCase {
    private func snapshot() -> FileIndexSnapshot {
        let root = UUID()
        let records = ["a.txt", "A.txt", "Ω.txt"].map { name in
            FileRecord(rootID: root, relativePath: name, fileName: name, fileExtension: "txt", byteSize: 3,
                createdAt: nil, modifiedAt: nil, typeIdentifier: nil, contentHash: "abc")
        }
        return FileIndexSnapshot(header: FileSnapshotHeader(id: UUID(), rootID: root, generation: 1,
            indexedAt: Date(), fileCount: 3, totalByteSize: 9, skippedCount: 0, hashesComputed: false,
            hashesVerifiedAt: nil), records: records)
    }
    func testReuseAndExplicitInvalidationReleasePreviousView() throws {
        let cache = FileSnapshotViewCache(), original = snapshot()
        let first = try cache.prepare(original)
        XCTAssertTrue(first === (try cache.prepare(original)))
        cache.invalidate()
        XCTAssertFalse(first === (try cache.prepare(original)))
    }
    func testHashPublicationWithSameSnapshotIDCannotReuseOldView() throws {
        let cache = FileSnapshotViewCache(); var original = snapshot()
        let first = try cache.prepare(original)
        original.header.hashesComputed = true; original.header.hashesVerifiedAt = Date()
        let second = try cache.prepare(original)
        XCTAssertFalse(first === second)
        original.header.hashesVerifiedAt = Date().addingTimeInterval(1)
        XCTAssertFalse(second === (try cache.prepare(original)))
    }
    func testSingleEntryEvictsOtherRootAndPreservesCaseDistinctNames() throws {
        let cache = FileSnapshotViewCache(), original = snapshot()
        let first = try cache.prepare(original)
        XCTAssertEqual(first.storage.map(\.relativePath), ["A.txt", "a.txt", "Ω.txt"])
        XCTAssertEqual(first.duplicates.map(\.relativePath), ["A.txt", "a.txt", "Ω.txt"])
        XCTAssertEqual(first.duplicateCount, 3)
        _ = try cache.prepare(snapshot())
        XCTAssertFalse(first === (try cache.prepare(original)))
    }
    func testCancelledPreparationDoesNotReturnCachedData() async throws {
        let cache = FileSnapshotViewCache(), original = snapshot()
        _ = try cache.prepare(original)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try cache.prepare(original)
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
