import SwiftUI
import FileOrganizerCore

/// История отображает фактические action receipts и не заменяет незавершённое
/// выполнение вымышленным успехом. Повтор использует дедупликацию координатора.
struct RuleHistoryView: View {
    @StateObject private var model: RulesViewModel
    var ruleID: UUID?
    init(container: AppContainer, ruleID: UUID? = nil) { _model = StateObject(wrappedValue: RulesViewModel(container: container)); self.ruleID = ruleID }
    var body: some View {
        List {
            if model.runs.isEmpty { Text("Правила ещё не выполнялись.").foregroundStyle(.secondary) }
            ForEach(model.runs.filter { ruleID == nil || $0.ruleID == ruleID }) { run in
                DisclosureGroup {
                    ForEach(Array(run.results.enumerated()), id: \.offset) { _, result in
                        VStack(alignment: .leading) {
                            Text("\(result.kind.title) · \(RulePresentation.status(result.status))")
                            Text(result.relativePath).font(.caption).textSelection(.enabled)
                            Text(result.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.rules.contains(where: { $0.id == run.ruleID }) {
                        Button("Повторить действия с ошибкой") { model.retry(run) }.disabled(model.isBusy)
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(run.ruleName).font(.headline)
                        Text("\(run.createdAt.formatted()) · \(RulePresentation.origin(run.origin)) · \(RulePresentation.status(run.status)) · совпадений: \(run.matchedCount)").font(.caption)
                    }
                }
            }
        }
        .task { await model.load() }
        .toolbar { Button("Обновить") { Task { await model.load() } } }
        .alert("Выполнение правила", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("Закрыть", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}
