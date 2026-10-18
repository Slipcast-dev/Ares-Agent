import SwiftUI
import FileOrganizerCore
import EcosystemUI

/// Единая точка управления оформлением и внешними подключениями. Один владелец
/// модели сохраняет состояние всех секций на время жизни экрана.
struct SettingsOverviewView: View {
    private let container: AppContainer
    @AppStorage(AppTheme.storageKey) private var storedTheme = AppTheme.system.rawValue
    @StateObject private var connections: AgentConnectionsViewModel

    init(container: AppContainer) {
        self.container = container
        _connections = StateObject(wrappedValue: AgentConnectionsViewModel(container: container))
    }

    var body: some View {
        Form {
            Section {
                Picker("Тема", selection: $storedTheme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: { Label("Оформление", systemImage: "paintpalette") }
            if let client = container.localRuntimeClient {
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
            Button("Обновить статусы", systemImage: "arrow.clockwise") { connections.load() }
                .disabled(connections.isRegistering)
        }
    }
}
