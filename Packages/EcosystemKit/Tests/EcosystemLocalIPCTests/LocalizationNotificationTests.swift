import Foundation
import XCTest
import EcosystemLocalization
@testable import EcosystemLocalIPC

/// Двойник штатного sender: тест не вызывает UNUserNotificationCenter/TCC.
private actor LocalizationSender: LocalNotificationSending {
    private(set) var deliveries: [(UUID, String, String)] = []
    func authorization() async -> String { "authorized" }
    func requestAuthorization() async throws -> String { "authorized" }
    func send(id: UUID, title: String, body: String) async throws {
        deliveries.append((id, title, body))
    }
}

final class LocalizationNotificationTests: XCTestCase {
    func testPreviewThroughNotificationSendingBoundary() async throws {
        let sender = LocalizationSender()
        let id = UUID()
        for language in AgentLanguage.allCases {
            let content = AgentLocalization(language: language).notificationPreview(agent: .athena)
            try await sender.send(id: id, title: content.title, body: content.body)
        }
        let deliveries = await sender.deliveries
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries.map(\.0), [id, id])
        XCTAssertEqual(deliveries.map(\.1), ["Афина: тестовое уведомление", "Athena: test notification"])
        XCTAssertEqual(deliveries[1].2, "Notification language check. Operations and user data have not been changed.")
    }
}
