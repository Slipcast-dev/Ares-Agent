import EcosystemLocalization
import Foundation
import FileOrganizerCore

/// Экспериментальный worker для локальной сборки. Не регистрирует LaunchAgent
/// сам и никогда не включает правила. --once позволяет проверить пустую тестовую
/// БД без доступа к реальным разрешённым папкам пользователя.
@main
struct RulesWorker {
    static func main() async {
        if LocalizationProbe.runIfRequested() { return }
        let arguments = CommandLine.arguments
        let databaseURL: URL
        if let index = arguments.firstIndex(of: "--database"), arguments.indices.contains(index + 1) {
            databaseURL = URL(fileURLWithPath: arguments[index + 1])
        } else { databaseURL = AppContainer.defaultApplicationSupportDatabaseURL() }
        let container = AppContainer(databaseURL: databaseURL, localRole: .worker)
        do {
            try container.preparePersistentStore()
            try await container.ruleCoordinator.poll(appLaunch: true)
            if arguments.contains("--once") { return }
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                try await container.ruleCoordinator.poll()
            }
        } catch {
            fputs(AgentLocalization(language: RuntimeLocalization.clientLanguage).runtimeText("ruleworker.failure") + "\n", stderr)
            exit(1)
        }
    }
}
