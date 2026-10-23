import AppKit
import SwiftUI
import EcosystemLocalization

/// Ошибка запуска показывается после создания окна SwiftUI. NSAlert.runModal
/// в App.init блокирует инициализацию приложения и делает окно недоступным AX.
public struct InstalledRuntimeFailureView: View {
    private let message: String
    @Environment(\.agentLanguage) private var environmentLanguage
    private let languageOverride: AgentLanguage?
    private var localization: AgentLocalization { AgentLocalization(language: languageOverride ?? environmentLanguage) }
    // Явный язык полезен preview; обычный экран наследует только язык своего GUI.
    public init(message: String, language: AgentLanguage? = nil) {
        self.message = message
        languageOverride = language
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(localization.text(.runtimeFailureTitle), systemImage: "exclamationmark.triangle")
                .font(.title2)
            Text(message).textSelection(.enabled)
            Text(localization.text(.runtimeFailureRecovery))
                .foregroundStyle(.secondary)
            if let instruction = Bundle.main.url(forResource: "ProfileMaintenance", withExtension: "md") {
                Button(localization.text(.runtimeFailureGuide)) { NSWorkspace.shared.open(instruction) }
            }
            Button(localization.text(.closeApplication)) { NSApplication.shared.terminate(nil) }
        }
        .padding(28).frame(minWidth: 480, minHeight: 220)
    }
}
