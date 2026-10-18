import XCTest
@testable import FileOrganizerCore

final class AgentIntegrationMessageTests: XCTestCase {
    func testRejectsEmptyAgentIdentity() {
        XCTAssertThrowsError(try AgentIntegrationMessage(sourceAgentID: "", targetAgentID: "ares", taskID: UUID(), correlationID: "test", payloadClassification: .storageRecommendation))
    }
}
