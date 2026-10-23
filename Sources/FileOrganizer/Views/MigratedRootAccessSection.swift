import SwiftUI
import EcosystemUI
import EcosystemLocalization
import EcosystemLocalIPC

struct MigratedRootAccessSection: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }
    @StateObject private var model: MigratedRootAccessViewModel
    init(client: Result<LocalRPCClient, Error>) {
        _model = StateObject(wrappedValue: MigratedRootAccessViewModel(client: client))
    }
    var body: some View {
        Section(l10n.text("Доступ после переноса")) {
            Text(l10n.text("Старые разрешения не включаются автоматически. Выберите каждую папку заново; индекс и история сохранятся."))
                .font(.callout).foregroundStyle(.secondary)
            Button(l10n.text("Обновить список папок")) { Task { await model.refresh() } }.disabled(model.busy)
            if model.roots.isEmpty { Text(l10n.text("Нет папок, ожидающих разрешения.")).foregroundStyle(.secondary) }
            ForEach(model.roots) { root in
                VStack(alignment: .leading) {
                    Text(root.displayName)
                    Text(root.relativePathHint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(l10n.text("Выбрать папку заново")) { Task { await model.renew(root, language: language) } }.disabled(model.busy)
                }
            }
            if let message = model.message { Text(l10n.render(message)).font(.callout) }
        }.task { await model.refresh() }
    }
}
