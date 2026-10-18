import Foundation

/// Разделы главной навигации. Идентификатор стабилен, чтобы позднее его можно
/// было сохранять в SceneStorage без привязки к локализованной подписи.
enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case files
    case duplicates
    case rules
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Обзор"
        case .files: "Файлы"
        case .duplicates: "Дубликаты"
        case .rules: "Правила"
        case .history: "Задачи и история"
        case .settings: "Настройки"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .files: "folder"
        case .duplicates: "rectangle.on.rectangle"
        case .rules: "arrow.triangle.branch"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }

    var isPrimary: Bool { self != .settings }
}
