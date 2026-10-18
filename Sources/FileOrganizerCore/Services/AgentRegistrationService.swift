import Foundation
import EcosystemClientAdapters

public enum ExternalAgent: String, CaseIterable, Identifiable, Sendable {
    case codex, harness
    public var id: String { rawValue }
    public var title: String { self == .codex ? "Codex" : "DeepSeek Harness" }
}

public struct AgentRegistrationStatus: Sendable {
    public let connected: Bool
    public let message: String
}

public enum AgentRegistrationError: Error, LocalizedError {
    case unavailable, conflict, invalidConfiguration, changedDuringWrite, commandFailed, timedOut
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Клиент или его конфигурация не найдены. Установите и один раз запустите приложение."
        case .conflict: "Запись ares уже существует и не принадлежит этому приложению. Она не изменена."
        case .invalidConfiguration: "Формат конфигурации не поддерживается или блок Ares был изменён вручную. Файл не изменён."
        case .changedDuringWrite: "Конфигурация изменена другим процессом. Обновите статус и повторите."
        case .commandFailed: "Клиент отклонил команду настройки MCP. Проверьте его конфигурацию."
        case .timedOut: "Клиент не ответил за 15 секунд. Повторите проверку."
        }
    }
}

/// Регистрирует реальный stdio-сервер, а не локальный UI-переключатель.
/// Codex получает собственную роль и MCP-запись через общий адаптер.
/// Harness получает собственную patch-запись,
/// не затрагивающую модели, секреты и другие плагины пользователя.
public actor AgentRegistrationService {
    private let helper: URL
    private let identifiedHelpers: [ExternalAgent: URL]
    private let codexCLI: URL?
    private let codexHome: URL
    private let harnessPatch: URL
    private let harnessInstalledVersion: String

    public init(helper: URL, codexCLI: URL?, codexHome: URL, harnessPatch: URL, identifiedHelpers: [ExternalAgent: URL] = [:], harnessInstalledVersion: String? = HarnessInstallation.detectedVersion()) {
        self.helper = helper; self.codexCLI = codexCLI; self.identifiedHelpers = identifiedHelpers
        self.codexHome = codexHome; self.harnessPatch = harnessPatch
        self.harnessInstalledVersion = harnessInstalledVersion ?? "unavailable"
    }

    public func status(_ agent: ExternalAgent) async throws -> AgentRegistrationStatus {
        if agent == .codex {
            let value = try await codexAdapter.status()
            return AgentRegistrationStatus(connected: value.connected, message: value.detail)
        }
        let value = try await harnessAdapter.status()
        return AgentRegistrationStatus(connected: value.connected, message: value.detail)
    }

    public func setConnected(_ connected: Bool, agent: ExternalAgent) async throws {
        let helper = identifiedHelpers[agent] ?? self.helper
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw AgentRegistrationError.unavailable }
        if agent == .codex {
            // План привязан к исходным байтам обоих файлов. Даже если другая
            // программа изменит их после просмотра, адаптер откажет в записи.
            let plan = try await previewCodexConnection(connected: connected)
            _ = try await applyCodexConnection(plan)
        } else {
            let plan = try await previewHarnessConnection(connected: connected)
            _ = try await applyHarnessConnection(plan)
        }
    }

    public func previewHarnessConnection(connected: Bool) async throws -> HarnessConnectionPlan {
        try await harnessAdapter.preview(connected: connected)
    }

    @discardableResult
    public func applyHarnessConnection(_ plan: HarnessConnectionPlan) async throws -> AgentRegistrationStatus {
        let value = try await harnessAdapter.apply(plan)
        return AgentRegistrationStatus(connected: value.connected, message: value.detail)
    }

    private var harnessAdapter: HarnessAdapter {
        HarnessAdapter(configuration: HarnessAdapterConfiguration(domain: .ares,
            patchURL: harnessPatch, helperURL: identifiedHelpers[.harness] ?? helper,
            installedVersion: harnessInstalledVersion, profile: "desktop"))
    }

    /// UI может показать конкретный план до пользовательского подтверждения.
    /// Этот метод не изменяет конфигурацию и не запускает модель Codex.
    public func previewCodexConnection(connected: Bool) async throws -> CodexConnectionPlan {
        try await codexAdapter.preview(connected: connected)
    }

    /// Применяет только ранее просмотренный план с проверкой его отпечатка.
    @discardableResult
    public func applyCodexConnection(_ plan: CodexConnectionPlan) async throws -> AgentRegistrationStatus {
        let value = try await codexAdapter.apply(plan)
        return AgentRegistrationStatus(connected: value.connected, message: value.detail)
    }

    private var codexAdapter: CodexAdapter {
        CodexAdapter(configuration: CodexAdapterConfiguration(
            domain: .ares,
            configDirectory: codexHome,
            helperURL: identifiedHelpers[.codex] ?? helper,
            codexExecutableURL: codexCLI
        ))
    }
}
