import Foundation

/// Безопасный ранний путь для проверки реальных GUI/runtime binaries. Вызывается
/// до bootstrap: не запускает службу, не открывает БД/профиль/окно и не просит TCC.
public enum LocalizationProbe {
    public static func runIfRequested(arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> Bool {
        guard arguments == ["--localization-probe"] else { return false }
        let samples = AgentLanguage.allCases.map { language -> [String: Any] in
            let localization = AgentLocalization(language: language)
            let notification = localization.notificationPreview(agent: .ares)
            let sharedComplete = SharedText.allCases.allSatisfy { key in
                let arguments = key.argumentKinds.map { $0 == .count ? SharedArgument.count(21) : .text("sample") }
                let value = localization.render(key, arguments: arguments)
                return value != "Localization resource unavailable." && value != key.rawValue && !value.isEmpty
            }
            return ["runtimeCount": localization.runtimeCatalogue.count, "runtimeComplete": localization.runtimeCatalogueComplete,
                    "sharedCount": SharedText.allCases.count, "sharedComplete": sharedComplete,
                    "sharedExample": localization.text(.externalPermissions),
                    "language": language.rawValue, "resourcesAvailable": localization.resourcesAvailable, "resourcePlacement": localization.resourcePlacement,
                    "screen": AgentText.allCases.map { localization.text($0) },
                    "notificationTitle": notification.title, "notificationBody": notification.body,
                    "plural": [0, 1, 2, 5, 11, 21, 101].map { localization.eventCount($0) }]
        }
        // Содержимое фиксированное, не содержит настроек/путей/данных пользователя.
        if let data = try? JSONSerialization.data(withJSONObject: ["localizationProbe": 1, "samples": samples], options: [.sortedKeys]),
           let output = String(data: data, encoding: .utf8) { print(output) }
        return true
    }
}
