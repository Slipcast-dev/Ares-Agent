import SwiftUI
import EcosystemLocalIPC

struct MigratedRootAccessSection: View {
    @StateObject private var model: MigratedRootAccessViewModel
    init(client: Result<LocalRPCClient, Error>) {
        _model = StateObject(wrappedValue: MigratedRootAccessViewModel(client: client))
    }
    var body: some View {
        Section("Доступ после переноса") {
            Text("Старые разрешения не включаются автоматически. Выберите каждую папку заново; индекс и история сохранятся.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Обновить список папок") { Task { await model.refresh() } }.disabled(model.busy)
            if model.roots.isEmpty { Text("Нет папок, ожидающих разрешения.").foregroundStyle(.secondary) }
            ForEach(model.roots) { root in
                VStack(alignment: .leading) {
                    Text(root.displayName)
                    Text(root.relativePathHint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Выбрать папку заново") { Task { await model.renew(root) } }.disabled(model.busy)
                }
            }
            if let message = model.message { Text(message).font(.callout) }
        }.task { await model.refresh() }
    }
}
