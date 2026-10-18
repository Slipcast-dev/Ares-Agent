import Foundation

/// Оценка по расположению, а не по содержимому. Она не гарантирует, что файл
/// безопасно удалять: библиотеки приложений и проекты часто требуют всех копий.
public enum FileLocationAssessment: String, Sendable {
    case system = "Системный каталог"
    case service = "Служебные данные или приложение"
    case ordinary = "Вне известных системных каталогов"
    case unknown = "Расположение не определено"

    public static func assess(rootPath: String?, relativePath: String) -> Self {
        guard let rootPath, rootPath.hasPrefix("/") else { return .unknown }
        let path = URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath).standardizedFileURL.path
        let systemRoots = ["/System", "/bin", "/sbin", "/usr", "/private", "/dev", "/etc", "/var"]
        if systemRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .system }
        let components = path.split(separator: "/").map(String.init)
        if components.contains("Library") || components.contains("Applications") || components.contains(where: { $0.hasSuffix(".app") || $0 == "node_modules" || $0 == ".git" || $0 == ".build" }) { return .service }
        return .ordinary
    }
}
