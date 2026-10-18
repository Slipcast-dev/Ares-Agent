import Foundation
import XCTest
@testable import FileOrganizerCore

final class DuplicateDetectionServiceTests: XCTestCase {
    func testFindsOnlyFilesWithIdenticalSHA256Content() async throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: rootURL.appendingPathComponent("first.txt"))
        try Data("same".utf8).write(to: rootURL.appendingPathComponent("second.txt"))
        try Data("else".utf8).write(to: rootURL.appendingPathComponent("third.txt"))

        let rootID = UUID()
        let records = ["first.txt", "second.txt", "third.txt"].map {
            FileRecord(rootID: rootID, relativePath: $0, fileName: $0, fileExtension: "txt", byteSize: 4, createdAt: nil, modifiedAt: nil, typeIdentifier: "public.plain-text")
        }
        let groups = try await DuplicateDetectionService().findExactDuplicates(rootURL: rootURL, records: records) { _, _ in }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].records.map(\.fileName).sorted(), ["first.txt", "second.txt"])
        XCTAssertEqual(groups[0].reclaimableByteSize, 4)
    }
}
