import Foundation
import XCTest
@testable import FileOrganizerCore

final class FileIndexingServiceTests: XCTestCase {
    /// Сканер обязан индексировать обычные файлы рекурсивно, но не переходить по
    /// символической ссылке, ведущей за границу разрешённого тестового корня.
    func testScanIndexesNestedFilesAndSkipsSymbolicLinks() async throws {
        let rootURL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nestedURL = rootURL.appendingPathComponent("Nested", isDirectory: true)
        let fileURL = nestedURL.appendingPathComponent("report.txt")
        let linkURL = rootURL.appendingPathComponent("external-link")
        let externalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: externalURL)
        }

        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data("report".utf8).write(to: fileURL)
        try Data("outside".utf8).write(to: externalURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: externalURL)

        XCTAssertNoThrow(try VerifiedFileReader.capture(root: rootURL, relative: "Nested/report.txt"))
        let root = AuthorizedRoot(displayName: "Test", relativePathHint: "/test")
        let service = FileIndexingService()
        let result = try await service.scan(root: root, rootURL: rootURL) { _ in }

        XCTAssertEqual(result.summary.indexedFileCount, 1)
        XCTAssertEqual(result.records.map(\.relativePath), ["Nested/report.txt"])
        XCTAssertGreaterThanOrEqual(result.summary.skippedItemCount, 1)
    }

    /// Индекс хранится в SQLite отдельно от файловой системы, поэтому повторная
    /// загрузка приложения может восстановить количество записей без сканирования.
    func testRepositoryStoresReplacedIndex() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let container = AppContainer(databaseURL: databaseURL)
        try container.preparePersistentStore()
        let rootID = UUID()
        let records = [
            FileRecord(
                rootID: rootID,
                relativePath: "one.txt",
                fileName: "one.txt",
                fileExtension: "txt",
                byteSize: 1,
                createdAt: nil,
                modifiedAt: nil,
                typeIdentifier: "public.plain-text"
            ),
            FileRecord(
                rootID: rootID,
                relativePath: "two.txt",
                fileName: "two.txt",
                fileExtension: "txt",
                byteSize: 2,
                createdAt: nil,
                modifiedAt: nil,
                typeIdentifier: "public.plain-text"
            )
        ]

        try await container.fileRepository.replaceIndex(records: records, forRootID: rootID)
        let initialCount = try await container.fileRepository.indexedFileCount(forRootID: rootID)
        XCTAssertEqual(initialCount, 2)

        try await container.fileRepository.replaceIndex(records: [records[0]], forRootID: rootID)
        let replacementCount = try await container.fileRepository.indexedFileCount(forRootID: rootID)
        XCTAssertEqual(replacementCount, 1)
    }
}
