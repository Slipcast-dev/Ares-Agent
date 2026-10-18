import XCTest
@testable import FileOrganizerCore

final class AIProviderProfileTests: XCTestCase {
    func testCloudProfileRejectsHTTP() {
        XCTAssertThrowsError(try AIProviderProfile(name: "Cloud", kind: .openAI, endpoint: URL(string: "http://example.com")!))
    }
    func testLocalOllamaAllowsLoopbackHTTP() throws {
        XCTAssertNoThrow(try AIProviderProfile(name: "Local", kind: .ollama, endpoint: URL(string: "http://127.0.0.1:11434")!))
    }
}
