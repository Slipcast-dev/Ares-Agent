import SwiftUI
import EcosystemLocalIPC
import EcosystemUI
import AppKit
import FileOrganizerCore

/// Точка входа графического приложения. Предпочтение темы хранится локально в
/// настройках приложения и не влияет на системную тему macOS.
@main
struct FileOrganizerApp: App {
    @NSApplicationDelegateAdaptor(OrganizerAppDelegate.self) private var appDelegate
    @AppStorage(AppTheme.storageKey) private var storedTheme = AppTheme.system.rawValue
    @StateObject private var overviewViewModel: OverviewViewModel

    private let startupError: String?

    init() {
        do {
            try InstalledRuntimeBootstrap.configureEnvironment(domain: "ares")
            startupError = nil
            _overviewViewModel = StateObject(wrappedValue: OverviewViewModel())
        } catch {
            startupError = error.localizedDescription
            // Ошибочный IPC-клиент не открывает legacy БД. Экран ошибки не
            // запускает ни load, ни миграции; /dev/null служит неиспользуемым URL.
            let container = AppContainer(databaseURL: URL(fileURLWithPath: "/dev/null"),
                localClientOverride: .failure(error))
            _overviewViewModel = StateObject(wrappedValue: OverviewViewModel(container: container))
        }
    }

    private var selectedTheme: AppTheme {
        AppTheme(rawValue: storedTheme) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            if let startupError {
                InstalledRuntimeFailureView(message: startupError)
            } else {
                ContentView(viewModel: overviewViewModel)
                    .preferredColorScheme(selectedTheme.preferredColorScheme)
            }
        }
        // Начальный размер — только предпочтение для нового окна, не предел
        // уменьшения. Сохранённый пользователем размер macOS восстанавливает.
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.automatic)
    }
}

/// SwiftPM-приложение при открытии bundle получает обычную политику активации:
/// окно становится активным и принимает клавиатурный фокус как desktop app.
final class OrganizerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
