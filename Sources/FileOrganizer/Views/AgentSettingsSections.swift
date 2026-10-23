import SwiftUI
import EcosystemLocalization
import EcosystemUI
import FileOrganizerCore

/// Секции встраиваются непосредственно в общую Form, без вложенного List
/// или второго ScrollView: прокрутка и группировка остаются нативными.
struct AgentSettingsSections: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }
    // Язык фиксируется до запуска асинхронной подготовки плана: открытое
    // подтверждение не должно менять смысл при переключении языка в другом окне.
    @State private var confirmationLanguage = ConfirmationLanguage(language: .russian)
    private var confirmationL10n: AresLocalization { AresLocalization(language: confirmationLanguage.language) }
    @ObservedObject var model: AgentConnectionsViewModel

    var body: some View {
        Group {
            Section {
                ForEach(ExternalAgent.allCases) { agent in
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(agent.title).font(.headline)
                            Label(model.connected.contains(agent) ? l10n.text("Настроено") : l10n.text("Не подключено"),
                                  systemImage: model.connected.contains(agent) ? "checkmark.circle" : "minus.circle")
                                .font(.caption)
                            Text(model.registrationMessages[agent].map(l10n.render) ?? l10n.text("Проверка регистрации…"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Button(model.connected.contains(agent) ? l10n.text("Отключить") : l10n.text("Подключить")) { confirmationLanguage = ConfirmationLanguage(language: language); model.toggle(agent) }
                            .buttonStyle(.bordered).controlSize(.large)
                            .disabled(model.isRegistering)
                            .accessibilityLabel(l10n.format(model.connected.contains(agent) ? "Отключить %@" : "Подключить %@", args: agent.title))
                    }.padding(.vertical, 8)
                }
                Text(l10n.text("Сведения о регистрации и план изменений показаны в исходном языке службы."))
                    .font(.caption).foregroundStyle(.secondary)
                PlannedHermesConnection()
                if model.isRegistering { ProgressView(l10n.text("Изменение подключения…")) }
                Text(l10n.text("Статус показывает наличие настройки, а не проверенный сеанс. После изменения подключения начните новый чат выбранного клиента. Уже открытый сеанс может сохранить прежний набор инструментов; автоматическое обновление не гарантируется."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label(l10n.text("Подключение агентов"), systemImage: "cpu") }

            Section {
                Text(l10n.text("Ares MCP предоставляет чтение индекса и сканирование разрешённых папок. Проверка не меняет подключения и не запускает сканирование."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(l10n.text("Проверить MCP"), systemImage: "checkmark.seal") { model.checkMCP() }
                    .disabled(model.isChecking)
                if model.isChecking { ProgressView(l10n.text("Проверка локального сервера…")) }
                if let message = model.healthMessage {
                    Label(l10n.render(message), systemImage: model.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.isHealthy ? .green : .orange).font(.caption)
                }
            } header: { Label(l10n.text("Диагностика подключения"), systemImage: "stethoscope") }

            Section {
                LabeledContent(l10n.text("Приложение"), value: "Athena")
                Text(l10n.text("Athena может передать агрегированную рекомендацию. Доступ к папкам остаётся под управлением Ares."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(l10n.text("Подключение внешнего агента не разрешает произвольные пути, shell-команды или изменение файлов. Разрешённые папки управляются в «Обзоре»."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label(l10n.text("Интеграции и безопасность"), systemImage: "lock.shield") }
        }
        .confirmationDialog(confirmationL10n.text("Подключение субагента Harness"), isPresented: Binding(
            get: { model.harnessPlan != nil }, set: { if !$0 { model.harnessPlan = nil } }
        ), titleVisibility: .visible) {
            if let plan = model.harnessPlan {
                Button(plan.connected ? confirmationL10n.text("Подключить Ares") : confirmationL10n.text("Отключить Ares")) { model.applyHarnessPlan(plan) }
            }
            Button(confirmationL10n.text("Отмена"), role: .cancel) { model.harnessPlan = nil }
        } message: {
            Text((model.harnessPlan?.changes ?? []).joined(separator: "\n") + "\n" + confirmationL10n.text("Модель и провайдер наследуются из настроек Harness."))
        }
        .confirmationDialog(confirmationL10n.text("Подключение субагента Codex"), isPresented: Binding(
            get: { model.codexPlan != nil }, set: { if !$0 { model.codexPlan = nil } }
        ), titleVisibility: .visible) {
            if let plan = model.codexPlan {
                Button(plan.connected ? confirmationL10n.text("Подключить Ares") : confirmationL10n.text("Отключить Ares")) { model.applyCodexPlan(plan) }
            }
            Button(confirmationL10n.text("Отмена"), role: .cancel) { model.codexPlan = nil }
        } message: {
            Text((model.codexPlan?.changes ?? []).joined(separator: "\n") + "\n" + confirmationL10n.text("Модель и провайдер наследуются из настроек Codex."))
        }
    }
}
