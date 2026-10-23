import SwiftUI
import EcosystemLocalization
import EcosystemLocalIPC

/// Один компонент обеспечивает одинаковые подписи, состояния и подтверждение
/// в отдельных окнах Ares и Athena. Он не выполняет файловых операций.
public struct LocalRecoverySection: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AgentLocalization { AgentLocalization(language: language) }
    @StateObject private var model: LocalRecoveryViewModel
    @State private var confirmationLanguage = ConfirmationLanguage(language: .english)
    @State private var confirming = false
    public init(client: Result<LocalRPCClient, Error>) {
        _model = StateObject(wrappedValue: LocalRecoveryViewModel(client: client))
    }
    init(model: LocalRecoveryViewModel) { _model = StateObject(wrappedValue: model) }
    public var body: some View {
        Section(l10n.text(.recovery)) {
            Text(l10n.text(.recoveryIntro))
                .font(.callout).foregroundStyle(.secondary)
            Text(l10n.text(.originalContent)).font(.caption).foregroundStyle(.secondary)
            Button(l10n.text(.refreshRecovery)) { Task { await model.refresh() } }
                .disabled(model.busy).accessibilityIdentifier("recovery.refresh")
            if model.busy { ProgressView().controlSize(.small) }
            if model.hasSnapshot && model.items.isEmpty && !model.busy { Text(l10n.text(.recoveryEmpty)).foregroundStyle(.secondary) }
            ForEach(model.items) { item in
                Button(l10n.message(.inspectRecovery, .text(item.capability), .text(String(item.id.uuidString.prefix(8))))) {
                    Task { await model.inspect(item.id) }
                }.disabled(model.busy).accessibilityIdentifier("recovery.inspect")
            }
            if let details = model.details {
                if !details.item.canConfirm {
                    Text(l10n.text(.executorActive)).foregroundStyle(.secondary)
                }
                ForEach(model.recorded.filter { $0.state != .started }) { receipt in
                    VStack(alignment: .leading) {
                        Text(verbatim: receipt.summary).textSelection(.enabled)
                        Text(receipt.state == .done ? l10n.text(.actionRecorded) : l10n.text(.noEffectRecorded))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.unresolved) { receipt in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: receipt.summary).textSelection(.enabled)
                        Picker(l10n.text(.verifiedOutcome), selection: Binding(
                            get: { model.outcomes[receipt.id] ?? "" }, set: { model.outcomes[receipt.id] = $0 })) {
                            Text(l10n.text(.outcomeUnchecked)).tag("")
                            Text(l10n.text(.outcomeDone)).tag("done")
                            Text(l10n.text(.outcomeNoEffect)).tag("confirmedNoEffect")
                        }.pickerStyle(.radioGroup).accessibilityIdentifier("recovery.outcome")
                        TextField(l10n.text(.recoveryNotes), text: Binding(
                            get: { model.notes[receipt.id] ?? "" }, set: { model.notes[receipt.id] = $0 }), axis: .vertical)
                            .lineLimit(2...5).accessibilityIdentifier("recovery.note")
                    }
                }
                Toggle(l10n.text(.recoveryFacts), isOn: $model.factsChecked)
                    .accessibilityIdentifier("recovery.facts")
                Button(l10n.text(.saveRecoveryResult)) { confirmationLanguage = ConfirmationLanguage(language: language); confirming = true }
                    .disabled(model.busy || !model.readyToConfirm).accessibilityIdentifier("recovery.confirm")
                    .alert(confirmationLanguage.localization.text(.recoveryConfirmTitle), isPresented: $confirming) {
                        Button(confirmationLanguage.localization.text(.saveRecovery)) { Task { await model.confirm() } }
                        Button(confirmationLanguage.localization.text(.cancel), role: .cancel) {}
                    } message: {
                        Text(confirmationLanguage.localization.text(.recoveryConfirmBody))
                    }
            }
            if let message = model.message { Text(message.localized(using: l10n)).font(.callout).textSelection(.enabled) }
        }
        .task { await model.refresh() }
    }
}
