import XCTest
@testable import FileOrganizerCore

final class EcosystemIntegrationTests: XCTestCase {
    func testMCPUsesSharedContractWithoutClaimingRuntimeIntegration() {
        let info = AresEcosystem.descriptor.experimentalCapability
        XCTAssertEqual(info["agentId"] as? String, "ares")
        XCTAssertEqual(info["major"] as? Int, 1)
        XCTAssertEqual(info["minor"] as? Int, 0)
        XCTAssertEqual(info["runtimeIntegrated"] as? Bool, false)
    }
}
