import AppKit
import SwiftUI
import EcosystemLocalIPC

/// Модель обращается только к GUI-каналу своего агента. Чтение состояния не
/// включает login item, не запрашивает системное разрешение и не подтверждает
/// доставку событий за внешнего клиента.
@MainActor private final class AutomationModel: ObservableObject {
    @Published var status: LocalAutomationStatus?
    @Published var login: LocalLoginStatus?
    @Published var events: [LocalInboxDelivery] = []
    @Published var error: String?
    @Published var busy = false
    let client: Result<LocalRPCClient, Error>

    init(client: Result<LocalRPCClient, Error>) { self.client = client }

    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        // Отказ одного компонента не оставляет устаревшие значения других.
        status = nil; login = nil; events = []; error = nil
        await readStatus()
    }

    private func readStatus() async {
        var failed = false
        do { status = try await client.get().call("automation.status", LocalAutomationRequest()) }
        catch { failed = true }
        do { login = try await client.get().call("automation.login_status", LocalEmpty()) }
        catch { failed = true }
        do {
            var request = LocalAutomationRequest(); request.limit = 20
            let rows: [LocalInboxDelivery] = try await client.get().call("events.list", request)
            events = rows.sorted { $0.event.createdAt > $1.event.createdAt }
        } catch { failed = true }
        if failed { error = "Часть данных недоступна. Проверьте сводку состояния и обновите её." }
    }

    func configure(paused: Bool? = nil, notificationsEnabled: Bool? = nil) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        var request = LocalAutomationRequest()
        request.paused = paused; request.notificationsEnabled = notificationsEnabled
        do {
            status = try await client.get().call("automation.configure", request)
            error = nil
        } catch { self.error = "Не удалось сохранить настройки фоновой работы." }
    }

    func requestNotifications() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            // Единственное место запроса macOS-разрешения — явное нажатие.
            status = try await client.get().call("automation.request_notifications", LocalAutomationRequest())
            error = nil
        } catch { self.error = "Не удалось запросить разрешение на уведомления. События доступны в приложении." }
    }

    func openNotificationSettings() {
        // Открываем штатную панель, не меняя согласие или стиль показа.
        // Разрешение принадлежит runtime bundle, а не окну основного приложения.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
              NSWorkspace.shared.open(url) else {
            error = "Откройте «Системные настройки → Уведомления» вручную."
            return
        }
    }

    func configureLogin(enabled: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        struct Request: Encodable, Sendable { let enabled: Bool }
        do {
            login = try await client.get().call("automation.login_configure", Request(enabled: enabled))
            error = nil
        } catch { self.error = "Не удалось изменить автозапуск. Если macOS запретила его, проверьте настройки фоновых объектов системы." }
    }
}

/// Общий интерфейс не объединяет процессы и разрешения Ареса и Афины:
/// каждый экземпляр получает client только собственного runtime.
public struct LocalAutomationSection: View {
    @StateObject private var model: AutomationModel
    @State private var confirmingLogin = false

    public init(client: Result<LocalRPCClient, Error>) {
        _model = StateObject(wrappedValue: AutomationModel(client: client))
    }

    public var body: some View {
        Section {
            if let status = model.status {
                Label(status.settings.paused ? "Фоновая работа приостановлена" : "Фоновая работа включена",
                      systemImage: status.settings.paused ? "pause.circle" : "play.circle")
                Toggle("Приостановить новые фоновые запуски", isOn: Binding(
                    get: { model.status?.settings.paused ?? false },
                    set: { value in Task { await model.configure(paused: value) } }
                ))
                .accessibilityIdentifier("automation.pause")
                .disabled(model.busy)
                Text("Пауза относится к новым фоновым запускам. Текущие задачи можно отменить в очереди задач.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Показывать уведомления о важных событиях", isOn: Binding(
                    get: { model.status?.settings.notificationsEnabled ?? false },
                    set: { value in Task { await model.configure(notificationsEnabled: value) } }
                ))
                .accessibilityIdentifier("automation.notifications.enabled")
                .disabled(model.busy)
                Text(notificationTitle(status.notificationAuthorization))
                    .font(.caption).foregroundStyle(.secondary)
                Button("Разрешить системные уведомления") {
                    Task { await model.requestNotifications() }
                }
                .accessibilityIdentifier("automation.notifications.request")
                .disabled(model.busy || status.notificationAuthorization == "authorized")
                Text("Переключатель включает уведомления этого агента. Разрешение macOS запрашивается отдельной кнопкой. Без него события сохраняются в приложении.")
                    .font(.caption).foregroundStyle(.secondary)
                if let domain = try? model.client.get().configuration.domain,
                   domain == "ares" || domain == "athena" {
                    Text("В системных настройках выберите «\(domain == "ares" ? "Ares Background" : "Athena Background")». Разрешение выдаётся этой фоновой службе.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Открыть уведомления macOS") { model.openNotificationSettings() }
                    .accessibilityIdentifier("automation.notifications.settings")
                if let failure = status.lastFailure { Text(failure).font(.caption).foregroundStyle(.orange) }
            } else {
                Text("Состояние фоновой работы пока недоступно.").foregroundStyle(.secondary)
            }

            if let login = model.login {
                LabeledContent("Запуск после входа в систему", value: loginTitle(login))
                if login.configured {
                    Button("Отключить запуск после входа") { Task { await model.configureLogin(enabled: false) } }
                        .accessibilityIdentifier("automation.login.disable")
                        .disabled(model.busy)
                } else {
                    Button("Включить запуск после входа") { confirmingLogin = true }
                        .accessibilityIdentifier("automation.login.enable")
                        .disabled(model.busy || login.disabledBySystem)
                }
                Text(login.registered ? "Служба зарегистрирована в macOS; доступность проверяется в сводке." : "Локальная служба сейчас не зарегистрирована.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Отключение автозапуска действует на следующий вход и не останавливает работающую службу.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("В фоне выполняются только локальные проверки и отдельно подтверждённые правила. Разрешения внешних клиентов управляются отдельно; модель ИИ автоматически не запускается.")
                .font(.caption).foregroundStyle(.secondary)

            DisclosureGroup {
                if model.events.isEmpty {
                    Text("В выборке нет событий или источник недоступен — проверьте сводку состояния.").foregroundStyle(.secondary)
                }
                ForEach(model.events, id: \.event.id) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        // Не показываем технические токены, UUID папок и grants.
                        Text(row.event.summary)
                        Text(row.event.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                Text("Просмотр не подтверждает получение события за Codex или DeepSeek Harness.")
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                Text("События локального агента")
                    .accessibilityIdentifier("automation.events")
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            Button("Обновить состояние фоновой работы") { Task { await model.refresh() } }
                .accessibilityIdentifier("automation.refresh")
                .disabled(model.busy)
        } header: {
            Label("Фоновая работа и уведомления", systemImage: "clock.badge.checkmark")
        }
        .task { await model.refresh() }
        .alert("Включить запуск после входа?", isPresented: $confirmingLogin) {
            Button("Отмена", role: .cancel) {}
            Button("Включить") { Task { await model.configureLogin(enabled: true) } }
                .accessibilityIdentifier("automation.login.confirm")
        } message: {
            Text("Этот агент будет работать в фоне после входа в macOS, даже если окно приложения закрыто. Он сможет выполнять локальные проверки и ранее подтверждённые правила в разрешённых папках. Доступ к новым папкам и операциям по-прежнему требует подтверждения. Модель ИИ автоматически не запускается.")
        }
    }

    private func notificationTitle(_ value: String) -> String {
        switch value {
        case "authorized": "macOS разрешила системные уведомления."
        case "denied": "macOS запретила уведомления. Изменить разрешение можно в системных настройках."
        case "notDetermined", "not_determined": "Разрешение macOS ещё не запрошено."
        case "provisional": "macOS разрешила тихие уведомления."
        default: "Системные уведомления недоступны; события сохраняются в приложении."
        }
    }

    private func loginTitle(_ status: LocalLoginStatus) -> String {
        if status.disabledBySystem { return "Запрещён в настройках macOS" }
        return status.configured ? "Включён" : "Выключен"
    }
}
