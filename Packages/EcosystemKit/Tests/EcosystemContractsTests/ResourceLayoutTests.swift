import Foundation
import XCTest
@testable import EcosystemContracts

final class ResourceLayoutTests: XCTestCase {
    func testBothSwiftPMResourceLayoutsResolveTheSameRole() throws {
        // Независимые fixture деревья воспроизводят layouts локального Xcode и
        // GitHub runner; ожидаемые байты не получаем через код загрузчика.
        for prefix in ["Resources/", ""] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: base) }
            let file = base.appendingPathComponent(prefix + "Roles/ares.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let expected = Data("{\"agentId\":\"ares\"}".utf8)
            try expected.write(to: file)
            XCTAssertEqual(try ContractResources.data(relativePath: "Roles/ares.json", resourceRoot: base), expected)
        }
    }
    func testResourceLayoutFallbackStillRejectsTraversalAndMissingFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try ContractResources.data(relativePath: "../outside.json", resourceRoot: base))
        XCTAssertThrowsError(try ContractResources.data(relativePath: "/outside.json", resourceRoot: base))
        XCTAssertThrowsError(try ContractResources.data(relativePath: "Roles/missing.json", resourceRoot: base))
    }
}
