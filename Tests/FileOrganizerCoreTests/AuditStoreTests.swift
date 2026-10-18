import XCTest
@testable import FileOrganizerCore

final class AuditStoreTests: XCTestCase {
    func testRecentEventsReturnsNewestFirstAndHonorsLimit() async throws {
        let store = InMemoryAuditStore()
        await store.record(AuditEvent(origin: .user, eventType: "plan.applied", summary: "one"))
        await store.record(AuditEvent(origin: .user, eventType: "plan.undone", summary: "two"))
        let events = await store.recentEvents(limit: 1)
        XCTAssertEqual(events.map(\.summary), ["two"])
    }
}
