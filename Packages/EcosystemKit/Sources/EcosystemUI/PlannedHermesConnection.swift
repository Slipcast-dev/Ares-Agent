import SwiftUI
import EcosystemLocalization

/// Единая строка двух приложений: отсутствие кнопки не обещает доступную установку.
public struct PlannedHermesConnection: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AgentLocalization { AgentLocalization(language: language) }
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(l10n.text(.hermesPlanned), systemImage: "clock")
            Text(l10n.text(.hermesDisclosure))
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hermes-planned")
    }
}
