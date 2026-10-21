import Foundation

/// Обнаружение не запускает Harness и не читает его ключи или пользовательские
/// выражения YAML. Формат desktop-профиля проверен для 0.2.0-rc.2 и установленного 0.2.1-rc.2.
public enum HarnessInstallation {
    public static func detectedVersion(applicationURL: URL? = nil) -> String? {
        let candidates = applicationURL.map { [$0] } ?? [
            URL(fileURLWithPath: "/Applications/DeepSeek Harness.app"),
            URL(fileURLWithPath: "/Applications/DeepSeek Harness WebUI.app")
        ]
        for candidate in candidates {
            if let version = Bundle(url: candidate)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                return version
            }
        }
        return nil
    }

    /// Явный тестовый home не должен незаметно обратиться к рабочему DSH_HOME.
    /// Переменную среды учитываем только при использовании настоящего home.
    public static func homeDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        override: URL? = nil
    ) -> URL {
        if let override { return override }
        if homeDirectory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
           let path = ProcessInfo.processInfo.environment["DSH_HOME"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".dsh", isDirectory: true)
    }

    public static func patchURL(homeDirectory: URL, profile: String = "desktop") -> URL {
        homeDirectory.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(profile, isDirectory: true).appendingPathComponent("cordis.patch.yml")
    }
}
