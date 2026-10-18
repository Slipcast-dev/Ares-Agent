import Foundation
import UserNotifications

/// Системный адаптер отделён от устойчивого журнала: отключённые уведомления
/// не превращают завершённую локальную операцию в ошибку и не теряют AI-событие.
public protocol LocalNotificationSending: Sendable {
    func authorization() async -> String
    func requestAuthorization() async throws -> String
    func send(id: UUID, title: String, body: String) async throws
}
public struct NativeLocalNotifications: LocalNotificationSending {
    public init() {}
    private var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    public func authorization() async -> String {
        // UNUserNotificationCenter аварийно завершает небандлированный CLI.
        // Unit/probe CLI остаются безопасными; launcher создаёт отдельный .app runtime.
        guard bundled else { return "unavailable" }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        default: return "unavailable"
        }
    }
    public func requestAuthorization() async throws -> String {
        guard bundled else { return "unavailable" }
        // Запрос вызывается только явно из GUI. Он никогда не выполняется таймером.
        _ = try await askPermission()
        return await authorization()
    }
    @MainActor private func askPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    public func send(id: UUID, title: String, body: String) async throws {
        guard await authorization() == "authorized" else { throw LocalRuntimeFailure.denied }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        // Стабильный identifier не накапливает копии pending/delivered запроса
        // при повторе после crash между add и фиксацией собственного журнала.
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
    }
}
