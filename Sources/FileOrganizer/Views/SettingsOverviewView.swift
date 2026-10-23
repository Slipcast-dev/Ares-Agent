import SwiftUI
import EcosystemLocalization
import FileOrganizerCore
import EcosystemUI

/// Единая точка управления оформлением и внешними подключениями. Один владелец
/// модели сохраняет состояние всех секций на время жизни экрана.
struct SettingsOverviewView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }
    private let container: AppContainer
    @Environment(\.localLanguageModel) private var languageModel
    @AppStorage(AppTheme.storageKey) private var storedTheme = AppTheme.system.rawValue
    @StateObject private var connections: AgentConnectionsViewModel

    init(container: AppContainer) {
        self.container = container
        _connections = StateObject(wrappedValue: AgentConnectionsViewModel(container: container))
    }

    var body: some View {
        Form {
            if let languageModel { LocalLanguageSection(model: languageModel) }
            Section {
                Picker(l10n.text("Тема"), selection: $storedTheme) {
                    ForEach(AppTheme.allCases) { Text(l10n.text($0.title)).tag($0.rawValue) }
                }
            } header: { Label(l10n.text("Оформление"), systemImage: "paintpalette") }
            if let client = container.localRuntimeClient {
                LocalOperationsSection(client: client)
                LocalRecoverySection(client: client)
                LocalAccessSection(client: client)
                LocalAutomationSection(client: client)
                MigratedRootAccessSection(client: client)
            }
            AgentSettingsSections(model: connections)
        }
        .formStyle(.grouped)
        .padding()
        .task { connections.load() }
        .toolbar {
            Button(l10n.text("Обновить статусы"), systemImage: "arrow.clockwise") { connections.load() }
                .disabled(connections.isRegistering)
        }
    }
}
