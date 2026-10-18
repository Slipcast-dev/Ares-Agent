import SwiftUI
import EcosystemLocalIPC

/// Один компонент обеспечивает одинаковые подписи, состояния и подтверждение
/// в отдельных окнах Ares и Athena. Он не выполняет файловых операций.
public struct LocalRecoverySection: View {
    @StateObject private var model: LocalRecoveryViewModel
    @State private var confirming = false
    public init(client: Result<LocalRPCClient, Error>) {
        _model = StateObject(wrappedValue: LocalRecoveryViewModel(client: client))
    }
    public var body: some View {
        Section("Восстановление") {
            Text("После сбоя некоторые действия требуют сверки. Проверьте исходный файл, результат и журнал правила перед подтверждением.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Обновить задания для сверки") { Task { await model.refresh() } }
                .disabled(model.busy).accessibilityIdentifier("recovery.refresh")
            if model.busy { ProgressView().controlSize(.small) }
            if model.items.isEmpty && !model.busy { Text("Заданий для сверки нет.").foregroundStyle(.secondary) }
            ForEach(model.items) { item in
                Button("Проверить задание «\(item.capability)» · \(item.id.uuidString.prefix(8))") {
                    Task { await model.inspect(item.id) }
                }.disabled(model.busy).accessibilityIdentifier("recovery.inspect")
            }
            if let details = model.details {
                if !details.item.canConfirm {
                    Text("Исполнитель ещё не остановился. Дождитесь его завершения и обновите список.").foregroundStyle(.secondary)
                }
                ForEach(model.recorded.filter { $0.state != .started }) { receipt in
                    VStack(alignment: .leading) {
                        Text(receipt.summary).textSelection(.enabled)
                        Text(receipt.state == .done ? "Действие уже подтверждено журналом." : "Отсутствие изменений уже подтверждено.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(model.unresolved) { receipt in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(receipt.summary).textSelection(.enabled)
                        Picker("Проверенный результат", selection: Binding(
                            get: { model.outcomes[receipt.id] ?? "" }, set: { model.outcomes[receipt.id] = $0 })) {
                            Text("Результат пока не проверен").tag("")
                            Text("Действие выполнено").tag("done")
                            Text("Действие не изменило файлы").tag("confirmedNoEffect")
                        }.pickerStyle(.radioGroup).accessibilityIdentifier("recovery.outcome")
                        TextField("Что именно проверено (20–2000 символов)", text: Binding(
                            get: { model.notes[receipt.id] ?? "" }, set: { model.notes[receipt.id] = $0 }), axis: .vertical)
                            .lineLimit(2...5).accessibilityIdentifier("recovery.note")
                    }
                }
                Toggle("Я проверил файлы и журнал для каждого действия", isOn: $model.factsChecked)
                    .accessibilityIdentifier("recovery.facts")
                Button("Сохранить результат сверки") { confirming = true }
                    .disabled(model.busy || !model.readyToConfirm).accessibilityIdentifier("recovery.confirm")
                    .alert("Сохранить сверку и снять блокировку?", isPresented: $confirming) {
                        Button("Сохранить сверку") { Task { await model.confirm() } }
                        Button("Отмена", role: .cancel) {}
                    } message: {
                        Text("Файлы не будут изменены и задание не будет повторено. Приостановленные правила остаются выключенными.")
                    }
            }
            if let message = model.message { Text(message).font(.callout).textSelection(.enabled) }
        }
        .task { await model.refresh() }
    }
}
