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
        return Self.authorizationState(for: settings.authorizationStatus)
    }
    /// Тихое provisional-разрешение не подтверждает право показывать баннер.
    /// Отдельное преобразование сохраняет точный статус в GUI и позволяет
    /// проверить контракт без обращения к системному центру уведомлений.
    static func authorizationState(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .provisional: return "provisional"
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
        let state = await authorization()
        // provisional сохраняет штатную тихую доставку. Отличающийся статус
        // нужен интерфейсу и приёмке: успешная отправка не доказывает баннер.
        guard state == "authorized" || state == "provisional" else { throw LocalRuntimeFailure.denied }
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        // Стабильный identifier не накапливает копии pending/delivered запроса
        // при повторе после crash между add и фиксацией собственного журнала.
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
    }
}
