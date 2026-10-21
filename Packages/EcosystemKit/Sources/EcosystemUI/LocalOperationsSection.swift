import SwiftUI
import UniformTypeIdentifiers
import EcosystemContracts
import EcosystemLocalIPC

/// Сохранение разрешает только явное действие в системной панели. Закрытие
/// preview ничего не записывает и ничего не отправляет во внешнюю сеть.
private struct DiagnosticsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

public struct LocalOperationsSection: View {
    @StateObject private var model: LocalOperationsModel
    @State private var preview: String?
    @State private var exporting = false
    @State private var confirmingPause = false
    @State private var confirmingEmergency = false
    @State private var confirmingResume = false
    @State private var saveMessage: String?

    public init(client: Result<LocalRPCClient, Error>) {
        _model = StateObject(wrappedValue: LocalOperationsModel(client: client))
    }
    init(model: LocalOperationsModel) { _model = StateObject(wrappedValue: model) }
    public var body: some View {
        Section {
            Text("Состояние только этого агента. Разрешения и служба второго приложения проверяются в его собственном окне.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.components) { component in
                VStack(alignment: .leading, spacing: 3) {
                    Label(component.title, systemImage: component.available && component.value != "Требует внимания" ? "checkmark.circle" : "exclamationmark.triangle")
                    Text(component.value).font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("operations." + component.id)
            }
            if let date = model.refreshedAt {
                Text("Снимок: " + date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.busy { ProgressView("Обновление состояния…") }
            DisclosureGroup("Первое подключение и безопасная проверка") {
                Text("1. Подключите Codex или DeepSeek Harness в разделе подключений и подтвердите план. Начните новый чат клиента.")
                Text("2. В разрешениях выберите этого клиента, минимальные операции чтения и короткий срок. Подготовьте и подтвердите план отдельно в каждом агенте.")
                Text("3. Поручите проверить статус и возможности, затем прочитать индекс тестовой папки Ареса и показатели Афины. Дождитесь итогов задач; файлы не изменять.")
                Text("Если один агент недоступен, используйте доступную часть результата и уточните причину. Настройка клиента не является доказательством живого соединения.")
            }
            Button("Обновить сводку") { Task { await model.refresh() } }
                .disabled(model.busy).accessibilityIdentifier("operations.refresh")
            DisclosureGroup("Последние задачи (до 100)") {
                if model.tasks.isEmpty { Text("Нет записей в выборке или очередь недоступна — проверьте статус выше.") }
                ForEach(model.tasks) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Задача " + task.id.uuidString.prefix(8) + " · " + Self.statusTitle(task.status))
                            .textSelection(.enabled)
                        if !task.status.isTerminal {
                            Button("Запросить отмену") { Task { await model.cancel(task) } }
                                .disabled(model.busy)
                                .accessibilityLabel("Запросить отмену задачи " + task.id.uuidString.prefix(8))
                        }
                    }
                }
            }.accessibilityIdentifier("operations.tasks")
            Button("Аварийно остановить этого агента", role: .destructive) { confirmingEmergency = true }
                .disabled(model.busy).accessibilityIdentifier("operations.emergencyStop")
            Button("Возобновить приём задач") { confirmingResume = true }
                .disabled(model.busy || model.emergency?.stopped != true)
                .accessibilityIdentifier("operations.emergencyResume")
            Text("Аварийная остановка блокирует новые задачи всех клиентов и планировщиков этого агента и запрашивает отмену всей очереди. Состояние сохраняется после перезапуска. Второй агент управляется отдельно.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Приостановить фон и отменить показанные задачи", role: .destructive) { confirmingPause = true }
                .disabled(model.busy || model.refreshedAt == nil)
                .accessibilityIdentifier("operations.pauseCancel")
            Text("Это запрос безопасной остановки: новые фоновые запуски ставятся на паузу, показанные активные задачи получают отмену. Ручные запросы клиентов не блокируются; закрытие окна также не останавливает службу.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = model.actionMessage { Text(message).accessibilityIdentifier("operations.result") }
            Button("Предпросмотр диагностического отчёта") { preview = model.report; saveMessage = nil }
                .disabled(model.busy || model.refreshedAt == nil)
                .accessibilityIdentifier("operations.preview")
            if let saveMessage { Text(saveMessage).font(.caption) }
        } header: { Label("Состояние и помощь", systemImage: "heart.text.square") }
        .task { await model.refresh() }
        .alert("Приостановить фон и запросить отмену?", isPresented: $confirmingPause) {
            Button("Отмена", role: .cancel) {}
            Button("Приостановить и запросить отмену", role: .destructive) { Task { await model.pauseAndCancelVisible() } }
                .accessibilityIdentifier("operations.pauseCancel.confirm")
        } message: {
            Text("Действие относится только к этому агенту и последним 100 задачам. Отмена завершается на безопасной точке, выполненные действия не откатываются. После обновления проверьте состояния и раздел восстановления. Новые ручные запросы остаются доступны.")
        }
        .alert("Аварийно остановить этого агента?", isPresented: $confirmingEmergency) {
            Button("Отмена", role: .cancel) {}
            Button("Остановить", role: .destructive) { Task { await model.setEmergencyStop(true) } }
                .accessibilityIdentifier("operations.emergencyStop.confirm")
        } message: {
            Text("Новые задачи будут запрещены до явного возобновления. Активные задачи остановятся на безопасной точке; уже выполненные изменения не откатываются. Проверьте callbacks и раздел восстановления.")
        }
        .alert("Возобновить приём задач?", isPresented: $confirmingResume) {
            Button("Отмена", role: .cancel) {}
            Button("Возобновить") { Task { await model.setEmergencyStop(false) } }
                .accessibilityIdentifier("operations.emergencyResume.confirm")
        } message: {
            Text("Клиенты и включённые планировщики смогут отправлять новые задачи. Отменённые задания не повторяются автоматически; прежние разрешения сохраняют свои ограничения.")
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Диагностический отчёт").font(.headline)
                if let saveMessage { Text(saveMessage).font(.caption) }
                Text("Проверьте текст перед сохранением. Отчёт содержит только состояния и счётчики; отправка не выполняется.")
                ScrollView { Text(preview ?? "").font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .accessibilityIdentifier("operations.preview.text")
                HStack {
                    Button("Закрыть", role: .cancel) { preview = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Сохранить отчёт…") { exporting = true }
                        .accessibilityIdentifier("operations.export")
                }
            }.padding().frame(minWidth: 400, idealWidth: 580, minHeight: 340, idealHeight: 460)
            .fileExporter(isPresented: $exporting, document: DiagnosticsDocument(text: preview ?? ""),
                          contentType: .plainText, defaultFilename: "agent-diagnostics") { result in
                switch result {
                case .success: saveMessage = "Отчёт сохранён в выбранный файл."
                case .failure: saveMessage = "Не удалось сохранить отчёт. Выберите доступную папку и повторите."
                }
            }
        }
    }
    static func statusTitle(_ status: TaskStatus) -> String {
        switch status {
        case .queued: "В очереди"
        case .running: "Выполняется"
        case .waitingForApproval: "Ожидает согласия"
        case .waitingForResource: "Ожидает ресурс"
        case .cancelling: "Отмена запрошена"
        case .completed: "Завершена"
        case .partial: "Частично выполнена"
        case .failed: "Ошибка"
        case .cancelled: "Отменена"
        case .interrupted: "Прервана"
        case .recoveryRequired: "Требует сверки"
        }
    }
}
