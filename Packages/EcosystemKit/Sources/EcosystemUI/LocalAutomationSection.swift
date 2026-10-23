import AppKit
import SwiftUI
import EcosystemLocalization
import EcosystemLocalIPC

/// Модель обращается только к GUI-каналу своего агента. Чтение состояния не
/// включает login item, не запрашивает системное разрешение и не подтверждает
/// доставку событий за внешнего клиента.
@MainActor final class AutomationModel: ObservableObject {
    @Published var status: LocalAutomationStatus?
    @Published var login: LocalLoginStatus?
    @Published var events: [LocalInboxDelivery] = []
    @Published var error: SharedText?
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
        if failed { error = .partialData }
    }

    func configure(paused: Bool? = nil, notificationsEnabled: Bool? = nil) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        var request = LocalAutomationRequest()
        request.paused = paused; request.notificationsEnabled = notificationsEnabled
        do {
            status = try await client.get().call("automation.configure", request)
            error = nil
        } catch { self.error = .automationSaveFailed }
    }

    func requestNotifications() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            // Единственное место запроса macOS-разрешения — явное нажатие.
            status = try await client.get().call("automation.request_notifications", LocalAutomationRequest())
            error = nil
        } catch { self.error = .notificationRequestFailed }
    }

    func openNotificationSettings() {
        // Открываем штатную панель, не меняя согласие или стиль показа.
        // Разрешение принадлежит runtime bundle, а не окну основного приложения.
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
              NSWorkspace.shared.open(url) else {
            error = .notificationSettingsManual
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
        } catch { self.error = .loginSaveFailed }
    }
}

/// Общий интерфейс не объединяет процессы и разрешения Ареса и Афины:
/// каждый экземпляр получает client только собственного runtime.
public struct LocalAutomationSection: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AgentLocalization { AgentLocalization(language: language) }
    @StateObject private var model: AutomationModel
    @State private var loginLanguage = ConfirmationLanguage(language: .english)
    @State private var confirmingLogin = false

    public init(client: Result<LocalRPCClient, Error>) {
        _model = StateObject(wrappedValue: AutomationModel(client: client))
    }

    init(model: AutomationModel) { _model = StateObject(wrappedValue: model) }
    public var body: some View {
        Section {
            if let status = model.status {
                Label(status.settings.paused ? l10n.text(.backgroundPaused) : l10n.text(.backgroundEnabled),
                      systemImage: status.settings.paused ? "pause.circle" : "play.circle")
                Toggle(l10n.text(.pauseBackground), isOn: Binding(
                    get: { model.status?.settings.paused ?? false },
                    set: { value in Task { await model.configure(paused: value) } }
                ))
                .accessibilityIdentifier("automation.pause")
                .disabled(model.busy)
                Text(l10n.text(.pauseScope))
                    .font(.caption).foregroundStyle(.secondary)

                Toggle(l10n.text(.importantNotifications), isOn: Binding(
                    get: { model.status?.settings.notificationsEnabled ?? false },
                    set: { value in Task { await model.configure(notificationsEnabled: value) } }
                ))
                .accessibilityIdentifier("automation.notifications.enabled")
                .disabled(model.busy)
                Text(notificationTitle(status.notificationAuthorization))
                    .font(.caption).foregroundStyle(.secondary)
                Button(l10n.text(.allowNotifications)) {
                    Task { await model.requestNotifications() }
                }
                .accessibilityIdentifier("automation.notifications.request")
                .disabled(model.busy || status.notificationAuthorization == "authorized")
                Text(l10n.text(.notificationConsent))
                    .font(.caption).foregroundStyle(.secondary)
                if let domain = try? model.client.get().configuration.domain,
                   domain == "ares" || domain == "athena" {
                    Text(l10n.message(.notificationSender, .text(domain == "ares" ? "Ares Background" : "Athena Background")))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(l10n.text(.openNotifications)) { model.openNotificationSettings() }
                    .accessibilityIdentifier("automation.notifications.settings")
                if let failure = status.lastFailure { Text(verbatim: failure).font(.caption).foregroundStyle(.orange) }
            } else {
                Text(l10n.text(.backgroundUnavailable)).foregroundStyle(.secondary)
            }

            if let login = model.login {
                LabeledContent(l10n.text(.loginStartup), value: loginTitle(login))
                if login.configured {
                    Button(l10n.text(.disableLogin)) { Task { await model.configureLogin(enabled: false) } }
                        .accessibilityIdentifier("automation.login.disable")
                        .disabled(model.busy)
                } else {
                    Button(l10n.text(.enableLogin)) { loginLanguage = ConfirmationLanguage(language: language); confirmingLogin = true }
                        .accessibilityIdentifier("automation.login.enable")
                        .disabled(model.busy || login.disabledBySystem)
                }
                Text(login.registered ? l10n.text(.serviceRegistered) : l10n.text(.serviceUnregistered))
                    .font(.caption).foregroundStyle(.secondary)
                Text(l10n.text(.loginDisableScope))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(l10n.text(.backgroundBoundary))
                .font(.caption).foregroundStyle(.secondary)

            DisclosureGroup {
                if model.events.isEmpty {
                    Text(l10n.text(.eventsEmpty)).foregroundStyle(.secondary)
                }
                ForEach(model.events, id: \.event.id) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        // Не показываем технические токены, UUID папок и grants.
                        Text(verbatim: row.event.summary)
                        Text(row.event.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
                Text(l10n.text(.originalContent)).font(.caption).foregroundStyle(.secondary)
                Text(l10n.text(.eventsReadOnly))
                    .font(.caption).foregroundStyle(.secondary)
            } label: {
                Text(l10n.text(.agentEvents))
                    .accessibilityIdentifier("automation.events")
            }
            if let error = model.error { Text(l10n.text(error)).foregroundStyle(.red) }
            Button(l10n.text(.refreshBackground)) { Task { await model.refresh() } }
                .accessibilityIdentifier("automation.refresh")
                .disabled(model.busy)
        } header: {
            Label(l10n.text(.backgroundNotifications), systemImage: "clock.badge.checkmark")
        }
        .task { await model.refresh() }
        .alert(loginLanguage.localization.text(.loginConfirmTitle), isPresented: $confirmingLogin) {
            Button(loginLanguage.localization.text(.cancel), role: .cancel) {}
            Button(loginLanguage.localization.text(.enable)) { Task { await model.configureLogin(enabled: true) } }
                .accessibilityIdentifier("automation.login.confirm")
        } message: {
            Text(loginLanguage.localization.text(.loginConfirmBody))
        }
    }

    private func notificationTitle(_ value: String) -> String {
        switch value {
        case "authorized": l10n.text(.notificationsAuthorized)
        case "denied": l10n.text(.notificationsDenied)
        case "notDetermined", "not_determined": l10n.text(.notificationsUndetermined)
        case "provisional": l10n.text(.notificationsProvisional)
        default: l10n.text(.notificationsUnavailable)
        }
    }

    private func loginTitle(_ status: LocalLoginStatus) -> String {
        if status.disabledBySystem { return l10n.text(.loginSystemDenied) }
        return status.configured ? l10n.text(.enabled) : l10n.text(.disabled)
    }
}
