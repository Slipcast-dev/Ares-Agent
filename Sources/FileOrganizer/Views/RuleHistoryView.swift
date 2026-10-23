import SwiftUI
import FileOrganizerCore
import EcosystemLocalization
import EcosystemUI

/// История отображает фактические action receipts и не заменяет незавершённое
/// выполнение вымышленным успехом. Повтор использует дедупликацию координатора.
struct RuleHistoryView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }
    @StateObject private var model: RulesViewModel
    var ruleID: UUID?
    init(container: AppContainer, ruleID: UUID? = nil) { _model = StateObject(wrappedValue: RulesViewModel(container: container)); self.ruleID = ruleID }
    var body: some View {
        List {
            if model.runs.isEmpty { Text(l10n.text("Правила ещё не выполнялись.")).foregroundStyle(.secondary) }
            ForEach(model.runs.filter { ruleID == nil || $0.ruleID == ruleID }) { run in
                DisclosureGroup {
                    ForEach(Array(run.results.enumerated()), id: \.offset) { _, result in
                        VStack(alignment: .leading) {
                            Text(l10n.format("%@ · %@", l10n.text(result.kind.title), l10n.ruleStatus(result.status)))
                            Text(result.relativePath).font(.caption).textSelection(.enabled)
                            Text(result.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.rules.contains(where: { $0.id == run.ruleID }) {
                        Button(l10n.text("Повторить действия с ошибкой")) { model.retry(run) }.disabled(model.isBusy)
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(run.ruleName).font(.headline)
                        Text(l10n.format("%@ · %@ · %@ · совпадений: %@", run.createdAt.formatted(), l10n.ruleOrigin(run.origin), l10n.ruleStatus(run.status), run.matchedCount.formatted())).font(.caption)
                    }
                }
            }
        }
        .task { await model.load() }
        .toolbar { Button(l10n.text("Обновить")) { Task { await model.load() } } }
        .alert(l10n.text("Выполнение правила"), isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button(l10n.text("Закрыть"), role: .cancel) { model.message = nil }
        } message: { Text(model.message.map(l10n.render) ?? "") }
    }
}


extension AresLocalization {
    /// Переводим только известные машинные статусы, а неизвестное значение
    /// сохраняем буквально: оно может принадлежать более новой версии runtime.
    func ruleStatus(_ value: String) -> String {
        switch value {
        case "running", "recoveryRequired", "completed", "partial_or_failed", "failed", "cancelled", "interrupted", "skipped":
            return text(RulePresentation.status(value))
        default: return value
        }
    }

    func ruleOrigin(_ value: String) -> String {
        switch value {
        case "manual", "automatic", "retry", "chain": return text(RulePresentation.origin(value))
        default: return value
        }
    }

    /// План содержит подписи действий текущего протокола; произвольные
    /// серверные строки не ищем в каталоге локализации.
    func ruleActionTitle(_ value: String) -> String {
        guard RuleActionKind.allCases.contains(where: { $0.title == value }) else { return value }
        return text(value)
    }
}
