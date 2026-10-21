import Foundation
import XCTest
@testable import FileOrganizerCore

final class DuplicateDetectionServiceTests: XCTestCase {
    /// Физический tmp-путь не содержит системного alias /var: тест проверяет
    /// подмену внутри корня, а не отказ из-за ссылки в самом пути стенда.
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/ares-duplicate-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func records(_ root: URL) throws -> [FileRecord] {
        let rootID = UUID()
        return try ["a/file.txt", "b/file.txt"].map { path in
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("same".utf8).write(to: file)
            return FileRecord(rootID: rootID, relativePath: path, fileName: "file.txt", fileExtension: "txt",
                byteSize: 4, createdAt: nil, modifiedAt: nil, typeIdentifier: "public.plain-text",
                version: try VerifiedFileReader.capture(root: root, relative: path))
        }
    }

    func testFindsOnlyFilesWithIdenticalSHA256Content() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = try records(root)
        let other = root.appendingPathComponent("other.txt")
        try Data("else".utf8).write(to: other)
        let control = FileRecord(rootID: rows[0].rootID, relativePath: "other.txt", fileName: "other.txt",
            fileExtension: "txt", byteSize: 4, createdAt: nil, modifiedAt: nil, typeIdentifier: nil,
            version: try VerifiedFileReader.capture(root: root, relative: "other.txt"))
        let groups = try await DuplicateDetectionService().findExactDuplicates(rootURL: root, records: rows + [control]) { _, _ in }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].records.map(\.id)), Set(rows.map(\.id)))
        XCTAssertEqual(groups[0].reclaimableByteSize, 4)
        XCTAssertEqual(groups[0].records.map(\.version), rows.map(\.version))
    }

    /// Набор из двух старых путей имитирует индекс до подмены. Даже совпадающий
    /// размер внешнего файла не должен разрешать его чтение/сохранение SHA.
    private func rejectsReplacement(parent: Bool) async throws {
        let root = try fixture(), outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let rows = try records(root)
        try Data("secr".utf8).write(to: outside.appendingPathComponent("file.txt"))
        for name in ["a", "b"] {
            let target = root.appendingPathComponent(parent ? name : name + "/file.txt")
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: parent ? outside : outside.appendingPathComponent("file.txt"))
        }
        let saved = DuplicateHashRecorder()
        do {
            _ = try await DuplicateDetectionService().findExactDuplicates(rootURL: root, records: rows,
                onProgress: { _, _ in }, persistHash: { id, _ in await saved.record(id) })
            XCTFail("Подмена ссылкой должна остановить анализ")
        } catch { XCTAssertTrue(error is AresFileFailure) }
        let count = await saved.count
        XCTAssertEqual(count, 0, "Недопустимый SHA не должен попасть в индекс")
    }

    func testRejectsSymlinkedParentWithoutPersistingHashes() async throws { try await rejectsReplacement(parent: true) }
    func testRejectsSymlinkedLeafWithoutPersistingHashes() async throws { try await rejectsReplacement(parent: false) }

    func testRejectsReplacedInodeEvenWithIdenticalBytes() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = try records(root)
        for row in rows {
            // Atomic write заменяет inode, оставляя размер и содержимое прежними.
            try Data("same".utf8).write(to: root.appendingPathComponent(row.relativePath), options: .atomic)
        }
        do {
            _ = try await DuplicateDetectionService().findExactDuplicates(rootURL: root, records: rows) { _, _ in }
            XCTFail("Устаревшая версия требует повторного сканирования")
        } catch { XCTAssertEqual(error as? AresFileFailure, .staleSnapshot) }
    }

    func testLegacyRecordWithoutVersionRequiresRescan() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = try records(root).map { row in
            FileRecord(rootID: row.rootID, relativePath: row.relativePath, fileName: row.fileName,
                fileExtension: row.fileExtension, byteSize: row.byteSize, createdAt: nil, modifiedAt: nil, typeIdentifier: nil)
        }
        do {
            _ = try await DuplicateDetectionService().findExactDuplicates(rootURL: root, records: rows) { _, _ in }
            XCTFail("Нельзя вычислять доверенную версию задним числом")
        } catch { XCTAssertEqual(error as? AresFileFailure, .snapshotRequired) }
    }
}

private actor DuplicateHashRecorder {
    private(set) var count = 0
    func record(_ id: UUID) { count += 1 }
}
