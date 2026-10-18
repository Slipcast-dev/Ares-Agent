import SwiftUI
import EcosystemLocalIPC

@MainActor private final class AccessModel: ObservableObject {
    @Published var scope = LocalAccessScope(roots: [], capabilities: [])
    @Published var grants: [LocalAccessGrant] = []
    @Published var pending: [LocalAccessPlan] = []
    @Published var reviewing: LocalAccessPlan?
    @Published var error: String?
    let client: Result<LocalRPCClient, Error>
    init(client: Result<LocalRPCClient, Error>) { self.client = client }
    func refresh() async {
        do {
            scope = try await client.get().call("access.scope", LocalAccessRequest())
            let state: LocalAccessState = try await client.get().call("access.status", LocalAccessRequest())
            grants = state.grants; pending = state.pending; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func request(_ draft: LocalAccessDraft) async {
        do { reviewing = try await client.get().call("access.request", LocalAccessRequest(draft: draft)); await refresh() }
        catch { self.error = error.localizedDescription }
    }
    func approve(_ plan: LocalAccessPlan) async {
        do {
            let _: LocalAccessGrant = try await client.get().call("access.approve", LocalAccessRequest(planID: plan.id, fingerprint: plan.fingerprint))
            reviewing = nil; await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func revoke(_ grant: LocalAccessGrant) async {
        do {
            struct Reply: Decodable, Sendable { let client: LocalMCPClient; let revoked: Bool }
            let _: Reply = try await client.get().call("access.revoke", LocalAccessRequest(grantID: grant.id))
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

/// Одинаковая секция двух приложений. Разрешение операций, OS grants и план
/// конкретного действия разделены. Выбор имени клиента здесь не заменяет peer pin.
public struct LocalAccessSection: View {
    @StateObject private var model: AccessModel
    @State private var selectedClient: LocalMCPClient = .codex
    @State private var metadata = false
    @State private var roots = Set<UUID>()
    @State private var operations = Set<String>()
    @State private var hours = 24
    public init(client: Result<LocalRPCClient, Error>) { _model = StateObject(wrappedValue: AccessModel(client: client)) }
    public var body: some View {
        Section {
            Text("Подключение клиента не выдаёт разрешений. Доступ к папке, экспорт данных и подтверждение действий управляются отдельно.").font(.caption).foregroundStyle(.secondary)
            Picker("Клиент", selection: $selectedClient) {
                ForEach(LocalMCPClient.allCases, id: \.self) { Text(title($0)).tag($0) }
            }
            if (try? model.client.get().configuration.domain) == "ares" {
                Toggle("Передавать имена и относительные пути файлов", isOn: $metadata)
                    .onChange(of: metadata) { _, _ in resetOperations() }
                ForEach(model.scope.roots) { root in
                    Toggle(root.name, isOn: Binding(get: { roots.contains(root.id) }, set: { if $0 { roots.insert(root.id) } else { roots.remove(root.id) } }))
                }
                if model.scope.roots.isEmpty { Text("Сначала выберите папку в обзоре Ареса.").foregroundStyle(.secondary) }
            }
            DisclosureGroup("Разрешённые операции") {
                ForEach(model.scope.capabilities, id: \.self) { capability in
                    if metadata || !requiresMetadata(capability) {
                        Toggle(operationTitle(capability), isOn: Binding(get: { operations.contains(capability) }, set: { if $0 { operations.insert(capability) } else { operations.remove(capability) } }))
                    }
                }
            }
            Picker("Срок доступа", selection: $hours) { Text("1 час").tag(1); Text("1 день").tag(24); Text("1 неделя").tag(168) }
            Button("Подготовить разрешение") {
                var draft = LocalAccessDraft(); draft.client = selectedClient; draft.roots = Array(roots)
                draft.capabilities = Array(operations); draft.dataClass = metadata ? .fileMetadata : .aggregate; draft.lifetimeSeconds = hours * 3600
                Task { await model.request(draft) }
            }.disabled(operations.isEmpty)
            Button("Обновить разрешения") { Task { await model.refresh() } }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            ForEach(model.grants) { grant in
                HStack {
                    VStack(alignment: .leading) { Text(title(grant.draft.client)); Text("До \(grant.expiresAt.formatted()) · \(grant.draft.dataClass == .aggregate ? "Сводки" : "Метаданные файлов")").font(.caption) }
                    Spacer(); Button("Отозвать доступ") { Task { await model.revoke(grant) } }
                }
            }
            ForEach(model.pending) { plan in
                Button("Проверить запрос: " + title(plan.draft.client)) { model.reviewing = plan }
                    .accessibilityIdentifier("access.review." + plan.draft.client.rawValue)
            }
        } header: { Label("Разрешения внешних клиентов", systemImage: "person.badge.key") }
        .task { await model.refresh(); resetOperations() }
        .sheet(item: $model.reviewing) { plan in
            VStack(alignment: .leading, spacing: 12) {
                Text("Подтвердить доступ: " + title(plan.draft.client)).font(.title2)
                Text(plan.draft.dataClass == .aggregate ? "Только сводки: без имён и путей файлов." : "Имена и относительные пути — личные данные. Клиент может передать их выбранному облачному провайдеру модели.")
                Text("Папки: " + plan.draft.roots.map { id in model.scope.roots.first(where: { $0.id == id })?.name ?? "Недоступная папка" }.joined(separator: ", "))
                Text("Операции: " + plan.draft.capabilities.map(operationTitle).joined(separator: ", "))
                Text("До \(plan.draft.maximumSourceObjects) исходных объектов / \(plan.draft.maximumSourceBytes / 1_048_576) МиБ. Ответ: до \(plan.draft.maximumResultObjects) объектов / \(plan.draft.maximumResponseBytes / 1024) КиБ. До \(plan.draft.maximumRequests) операций за \(plan.draft.periodSeconds / 60) мин.")
                Text("Доступ на \(plan.draft.lifetimeSeconds / 3600) ч. План действует до \(plan.expiresAt.formatted()).")
                Text("Это не разрешает передачу содержимого файлов, секретов или произвольных команд. Изменение файлов потребует отдельного согласованного плана или правила.").font(.caption).foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Отмена") { model.reviewing = nil }
                    Button("Подтвердить доступ") { Task { await model.approve(plan) } }.accessibilityIdentifier("access.approve")
                }
            }.padding(24).frame(width: 560)
        }
    }
    private func resetOperations() { operations = Set(model.scope.capabilities.filter { metadata || !requiresMetadata($0) }) }
    private func requiresMetadata(_ value: String) -> Bool { (try? model.client.get().configuration.domain) == "ares" && (value.hasPrefix("rule.") || ["file.search", "file.compute_duplicates", "file.find_duplicates"].contains(value)) }
    private func title(_ client: LocalMCPClient) -> String { switch client { case .codex: "Codex"; case .deepseekHarness: "DeepSeek Harness"; case .legacy: "Общий MCP (совместимость)" } }
    private func operationTitle(_ value: String) -> String {
        let labels = ["events.read":"Входящие события для ИИ", "file.list_roots":"Список разрешённых папок", "file.scan":"Сканирование", "file.search":"Поиск файлов", "file.analyze_storage":"Сводка объёма", "file.compute_duplicates":"Вычисление дубликатов", "file.find_duplicates":"Просмотр дубликатов", "file.get_audit_report":"Счётчики аудита", "system.get_info":"Сведения о Mac", "system.get_metrics":"Показатели системы", "diagnostics.run":"Диагностика", "storage.get_overview":"Сводка накопителя", "diagnostics.history":"История диагностики", "monitor.list":"Список проверок", "monitor.get":"Настройки проверки", "monitor.preview":"Предварительная проверка мониторинга", "monitor.propose":"Проект мониторинга", "monitor.request_enable":"Запрос включения мониторинга", "monitor.disable":"Отключение мониторинга", "monitor.history":"История мониторинга", "rule.list":"Список правил", "rule.get":"Настройки правила", "rule.validate":"Проверка правила", "rule.propose":"Проект правила", "rule.preview":"Предварительный план", "rule.run":"Запуск правила", "rule.request_enable":"Запрос включения правила", "rule.disable":"Отключение правила", "rule.history":"История правил"]
        return labels[value] ?? value
    }
}
