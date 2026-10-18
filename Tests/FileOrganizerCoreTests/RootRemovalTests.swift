import Foundation
import XCTest
@testable import FileOrganizerCore

final class RootRemovalTests: XCTestCase {
    /// Отзыв одной папки удаляет её bookmark и индекс, сохраняя другой корень.
    func testRemovalIsScopedAndPersists() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let container = AppContainer(databaseURL: databaseURL)
        try container.preparePersistentStore()
        let root = AuthorizedRoot(displayName: "Test", relativePathHint: "test")
        let other = AuthorizedRoot(displayName: "Keep", relativePathHint: "keep")
        let repository = container.fileRepository
        try await repository.save(root: root, bookmarkData: Data([1]))
        try await repository.save(root: other, bookmarkData: Data([2]))
        try await repository.removeRoot(withID: root.id)
        let reopened = SQLiteFileRepository(databaseURL: databaseURL)
        let roots = try await reopened.fetchRoots()
        let bookmark = try await reopened.bookmarkData(forRootID: root.id)
        XCTAssertEqual(roots.map(\.id), [other.id])
        XCTAssertNil(bookmark)
    }
}
