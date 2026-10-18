import XCTest
@testable import FileOrganizerCore

final class FileOrganizerProductTests: XCTestCase {
    /// Проверка фиксирует публичный контракт каркаса. И UI, и MCP будут опираться
    /// на эти данные, поэтому их изменение должно быть осознанным и тестируемым.
    func testProductIdentityIsStable() {
        XCTAssertEqual(FileOrganizerProduct.displayName, "Ares")
        XCTAssertEqual(FileOrganizerProduct.version, "0.1.0")
    }
}
