import Foundation
import Combine
import FileOrganizerCore
import EcosystemLocalIPC
import EcosystemClientAdapters

/// Состояние подключений принадлежит общему экрану настроек: перенос разделов
/// не создаёт новую регистрацию и не меняет настройки внешних клиентов.
@MainActor
final class AgentConnectionsViewModel: ObservableObject {
    @Published var tasks: [AgentTask] = []
    @Published var isChecking = false
    @Published var isHealthy = false
    @Published var healthMessage: String?
    @Published var connected: Set<ExternalAgent> = []
    @Published var registrationMessages: [ExternalAgent: String] = [:]
    @Published var isRegistering = false
    private let container: AppContainer
    private let registration: AgentRegistrationService
    private static var helperURL: URL {
        if let path = ProcessInfo.processInfo.environment["ARES_LOCAL_RUNTIME_CONFIG"] {
            return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("ares-mcp.command")
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/FileOrganizerMCP")
    }
    init(container: AppContainer) {
        self.container = container
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        let cli = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let harnessHome = environment["DSH_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".dsh")
        let identified: [ExternalAgent: URL]
        if environment["ARES_LOCAL_RUNTIME_CONFIG"] != nil {
            let folder = Self.helperURL.deletingLastPathComponent()
            identified = [.codex: folder.appendingPathComponent("ares-codex-mcp.command"), .harness: folder.appendingPathComponent("ares-deepseekHarness-mcp.command")]
        } else { identified = [:] }
        registration = AgentRegistrationService(helper: Self.helperURL, codexCLI: cli, codexHome: codexHome, harnessPatch: harnessHome.appendingPathComponent("profiles/desktop/cordis.patch.yml"), identifiedHelpers: identified)
    }
    func load() {
        Task {
            tasks = (try? await container.fileRepository.recentTasks()) ?? []
            for agent in ExternalAgent.allCases { await refresh(agent) }
        }
    }
    private func refresh(_ agent: ExternalAgent) async {
        do {
            let state = try await registration.status(agent)
            if state.connected { connected.insert(agent) } else { connected.remove(agent) }
            registrationMessages[agent] = state.message
        } catch {
            connected.remove(agent); registrationMessages[agent] = error.localizedDescription
        }
    }
    @Published var codexPlan: CodexConnectionPlan?
    @Published var harnessPlan: HarnessConnectionPlan?

    func applyCodexPlan(_ plan: CodexConnectionPlan) {
        guard !isRegistering else { return }
        codexPlan = nil; isRegistering = true
        Task {
            defer { isRegistering = false }
            do { _ = try await registration.applyCodexConnection(plan); await refresh(.codex) }
            catch { registrationMessages[.codex] = error.localizedDescription }
        }
    }

    func toggle(_ agent: ExternalAgent) {
        guard !isRegistering else { return }
        if agent == .codex {
            isRegistering = true
            Task {
                defer { isRegistering = false }
                do { codexPlan = try await registration.previewCodexConnection(connected: !connected.contains(.codex)) }
                catch { registrationMessages[.codex] = error.localizedDescription }
            }
            return
        }
        isRegistering = true
        Task {
            defer { isRegistering = false }
            do { harnessPlan = try await registration.previewHarnessConnection(connected: !connected.contains(.harness)) }
            catch { registrationMessages[.harness] = error.localizedDescription }
        }
    }

    func applyHarnessPlan(_ plan: HarnessConnectionPlan) {
        guard !isRegistering else { return }
        harnessPlan = nil; isRegistering = true
        Task {
            defer { isRegistering = false }
            do { _ = try await registration.applyHarnessConnection(plan); await refresh(.harness) }
            catch { registrationMessages[.harness] = error.localizedDescription }
        }
    }

    /// Проверка запускает только встроенный stdio-helper и передаёт безопасный
    /// `tools/list`. Она не открывает порт, не читает пользовательские файлы и
    /// не меняет конфигурации Codex или Harness.
    func checkMCP() {
        isChecking = true
        healthMessage = nil
        Task { [self] in
            defer { isChecking = false }
            let helperURL = Self.helperURL
            guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
                isHealthy = false; healthMessage = "MCP-helper отсутствует в приложении."; return
            }
            isHealthy = await MCPHealthCheck.run(helperURL: helperURL)
            healthMessage = isHealthy ? "MCP готов: список инструментов получен." : "Проверка не завершилась за 5 секунд или helper вернул ошибку. Можно повторить."
        }
    }
}
