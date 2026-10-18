import SwiftUI

/// Выбранный пользователем внешний вид. Неопределённое значение означает
/// системную тему, а не «светлую по умолчанию», поэтому приложение уважает
/// настройки доступности и внешний вид macOS.
enum AppTheme: String, CaseIterable, Identifiable {
    static let storageKey = "fileOrganizer.interfaceTheme"

    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как в системе"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
