import XCTest
@testable import FileOrganizerCore

final class FileLocationAssessmentTests: XCTestCase {
    func testSystemBoundaryAndServiceLocations() {
        XCTAssertEqual(FileLocationAssessment.assess(rootPath: "/System", relativePath: "Library/test"), .system)
        XCTAssertEqual(FileLocationAssessment.assess(rootPath: "/Users/test", relativePath: "Library/test"), .service)
        XCTAssertEqual(FileLocationAssessment.assess(rootPath: "/Users/test/Documents", relativePath: "photo.jpg"), .ordinary)
        XCTAssertEqual(FileLocationAssessment.assess(rootPath: "/SystemCopy", relativePath: "photo.jpg"), .ordinary)
        XCTAssertEqual(FileLocationAssessment.assess(rootPath: nil, relativePath: "test"), .unknown)
    }
}
