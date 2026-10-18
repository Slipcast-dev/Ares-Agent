import SwiftUI
import FileOrganizerCore

/// Секции встраиваются непосредственно в общую Form, без вложенного List
/// или второго ScrollView: прокрутка и группировка остаются нативными.
struct AgentSettingsSections: View {
    @ObservedObject var model: AgentConnectionsViewModel

    var body: some View {
        Group {
            Section {
                ForEach(ExternalAgent.allCases) { agent in
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(agent.title).font(.headline)
                            Label(model.connected.contains(agent) ? "Зарегистрирован" : "Не подключён",
                                  systemImage: model.connected.contains(agent) ? "checkmark.circle" : "minus.circle")
                                .font(.caption)
                            Text(model.registrationMessages[agent] ?? "Проверка регистрации…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)
                        Button(model.connected.contains(agent) ? "Отключить" : "Подключить") { model.toggle(agent) }
                            .buttonStyle(.bordered).controlSize(.large)
                            .disabled(model.isRegistering)
                            .accessibilityLabel("\(model.connected.contains(agent) ? "Отключить" : "Подключить") \(agent.title)")
                    }.padding(.vertical, 8)
                }
                if model.isRegistering { ProgressView("Изменение подключения…") }
                Text("После изменения подключения начните новый чат выбранного клиента. Уже открытый сеанс может сохранить прежний набор инструментов; автоматическое обновление не гарантируется.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Подключение агентов", systemImage: "cpu") }

            Section {
                Text("Ares MCP предоставляет чтение индекса и сканирование разрешённых папок. Проверка не меняет подключения и не запускает сканирование.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Проверить MCP", systemImage: "checkmark.seal") { model.checkMCP() }
                    .disabled(model.isChecking)
                if model.isChecking { ProgressView("Проверка локального сервера…") }
                if let message = model.healthMessage {
                    Label(message, systemImage: model.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.isHealthy ? .green : .orange).font(.caption)
                }
            } header: { Label("Диагностика подключения", systemImage: "stethoscope") }

            Section {
                LabeledContent("Приложение", value: "Athena")
                Text("Athena может передать агрегированную рекомендацию. Доступ к папкам остаётся под управлением Ares.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Подключение внешнего агента не разрешает произвольные пути, shell-команды или изменение файлов. Разрешённые папки управляются в «Обзоре».")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("Интеграции и безопасность", systemImage: "lock.shield") }

            Section {
                if model.tasks.isEmpty { Text("Фоновые MCP-задачи ещё не запускались.").foregroundStyle(.secondary) }
                ForEach(model.tasks) { task in
                    LabeledContent(task.origin.rawValue, value: task.status.rawValue)
                        .accessibilityLabel("Задача \(task.origin.rawValue), статус \(task.status.rawValue)")
                }
            } header: { Label("Последние MCP-задачи", systemImage: "clock") }
        }
        .confirmationDialog("Подключение субагента Harness", isPresented: Binding(
            get: { model.harnessPlan != nil }, set: { if !$0 { model.harnessPlan = nil } }
        ), titleVisibility: .visible) {
            if let plan = model.harnessPlan {
                Button(plan.connected ? "Подключить Ares" : "Отключить Ares") { model.applyHarnessPlan(plan) }
            }
            Button("Отмена", role: .cancel) { model.harnessPlan = nil }
        } message: {
            Text((model.harnessPlan?.changes ?? []).joined(separator: "\n") + "\nМодель и провайдер наследуются из настроек Harness.")
        }
        .confirmationDialog("Подключение субагента Codex", isPresented: Binding(
            get: { model.codexPlan != nil }, set: { if !$0 { model.codexPlan = nil } }
        ), titleVisibility: .visible) {
            if let plan = model.codexPlan {
                Button(plan.connected ? "Подключить Ares" : "Отключить Ares") { model.applyCodexPlan(plan) }
            }
            Button("Отмена", role: .cancel) { model.codexPlan = nil }
        } message: {
            Text((model.codexPlan?.changes ?? []).joined(separator: "\n") + "\nМодель и провайдер наследуются из настроек Codex.")
        }
    }
}
