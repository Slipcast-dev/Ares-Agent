import SwiftUI
import EcosystemLocalization
import EcosystemLocalIPC

@MainActor final class AccessModel: ObservableObject {
    @Published var scope = LocalAccessScope(roots: [], capabilities: [])
    @Published var grants: [LocalAccessGrant] = []
    @Published var pending: [LocalAccessPlan] = []
    @Published var reviewing: LocalAccessPlan?
    @Published var error: LocalRuntimeFailure?
    @Published var busy = false
    let client: Result<LocalRPCClient, Error>
    init(client: Result<LocalRPCClient, Error>) { self.client = client }
    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await readSnapshot()
    }
    private func readSnapshot() async {
        // Недоступный источник не должен оставлять действующими старые строки.
        scope = LocalAccessScope(roots: [], capabilities: []); grants = []; pending = []
        do {
            scope = try await client.get().call("access.scope", LocalAccessRequest())
            let state: LocalAccessState = try await client.get().call("access.status", LocalAccessRequest())
            grants = state.grants; pending = state.pending; error = nil
        } catch { self.error = LocalRuntimeFailure.safe(error) }
    }
    func request(_ draft: LocalAccessDraft) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { reviewing = try await client.get().call("access.request", LocalAccessRequest(draft: draft)); await readSnapshot() }
        catch { self.error = LocalRuntimeFailure.safe(error) }
    }
    func approve(_ plan: LocalAccessPlan) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let _: LocalAccessGrant = try await client.get().call("access.approve", LocalAccessRequest(planID: plan.id, fingerprint: plan.fingerprint))
            reviewing = nil; await readSnapshot()
        } catch { self.error = LocalRuntimeFailure.safe(error) }
    }
    func revoke(_ grant: LocalAccessGrant) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            struct Reply: Decodable, Sendable { let client: LocalMCPClient; let revoked: Bool }
            let _: Reply = try await client.get().call("access.revoke", LocalAccessRequest(grantID: grant.id))
            await readSnapshot()
        } catch { self.error = LocalRuntimeFailure.safe(error) }
    }
}

/// Одинаковая секция двух приложений. Разрешение операций, OS grants и план
/// конкретного действия разделены. Выбор имени клиента здесь не заменяет peer pin.
public struct LocalAccessSection: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AgentLocalization { AgentLocalization(language: language) }
    @StateObject private var model: AccessModel
    @State private var selectedClient: LocalMCPClient = .codex
    @State private var metadata = false
    @State private var roots = Set<UUID>()
    @State private var operations = Set<String>()
    @State private var hours = 24
    public init(client: Result<LocalRPCClient, Error>) { _model = StateObject(wrappedValue: AccessModel(client: client)) }
    init(model: AccessModel) { _model = StateObject(wrappedValue: model) }
    public var body: some View {
        Section {
            Text(l10n.text(.accessIntro)).font(.caption).foregroundStyle(.secondary)
            Picker(l10n.text(.client), selection: $selectedClient) {
                ForEach(LocalMCPClient.allCases, id: \.self) { Text(title($0)).tag($0) }
            }
            if (try? model.client.get().configuration.domain) == "ares" {
                Toggle(l10n.text(.shareMetadata), isOn: $metadata)
                    .onChange(of: metadata) { _, _ in resetOperations() }
                ForEach(model.scope.roots) { root in
                    Toggle(root.name, isOn: Binding(get: { roots.contains(root.id) }, set: { if $0 { roots.insert(root.id) } else { roots.remove(root.id) } }))
                }
                if model.scope.roots.isEmpty { Text(l10n.text(.chooseAresFolder)).foregroundStyle(.secondary) }
            }
            DisclosureGroup(l10n.text(.allowedOperations)) {
                ForEach(model.scope.capabilities, id: \.self) { capability in
                    if metadata || !requiresMetadata(capability) {
                        Toggle(operationTitle(capability), isOn: Binding(get: { operations.contains(capability) }, set: { if $0 { operations.insert(capability) } else { operations.remove(capability) } }))
                    }
                }
            }
            Picker(l10n.text(.accessDuration), selection: $hours) { Text(l10n.text(.oneHour)).tag(1); Text(l10n.text(.oneDay)).tag(24); Text(l10n.text(.oneWeek)).tag(168) }
            Button(l10n.text(.preparePermission)) {
                var draft = LocalAccessDraft(); draft.client = selectedClient; draft.roots = Array(roots)
                draft.capabilities = Array(operations); draft.dataClass = metadata ? .fileMetadata : .aggregate; draft.lifetimeSeconds = hours * 3600
                Task { await model.request(draft) }
            }.disabled(model.busy || operations.isEmpty)
            Button(l10n.text(.refreshPermissions)) { Task { await model.refresh() } }.disabled(model.busy)
            if let error = model.error { Text(SharedMessage.failure(error).localized(using: l10n)).foregroundStyle(.red) }
            ForEach(model.grants) { grant in
                HStack {
                    VStack(alignment: .leading) { Text(title(grant.draft.client)); Text(l10n.message(.grantExpires, .text(grant.expiresAt.formatted()), .text(l10n.text(grant.draft.dataClass == .aggregate ? .aggregateType : .metadataType)))).font(.caption) }
                    Spacer(); Button(l10n.text(.revokeAccess)) { Task { await model.revoke(grant) } }.disabled(model.busy)
                }
            }
            ForEach(model.pending) { plan in
                Button(l10n.message(.reviewRequest, .text(title(plan.draft.client)))) { model.reviewing = plan }
                    .accessibilityIdentifier("access.review." + plan.draft.client.rawValue)
            }
        } header: { Label(l10n.text(.externalPermissions), systemImage: "person.badge.key") }
        .task { await model.refresh(); resetOperations() }
        .sheet(item: $model.reviewing) { plan in
            AccessReviewView(model: model, plan: plan, language: language).id(plan.id)
        }
    }
    // Выключение metadata убирает несовместимые операции. Новые операции не
    // выбираются автоматически: пользователь явно задаёт минимальный доступ.
    private func resetOperations() { operations.formIntersection(model.scope.capabilities.filter { metadata || !requiresMetadata($0) }) }
    private func requiresMetadata(_ value: String) -> Bool { (try? model.client.get().configuration.domain) == "ares" && (value.hasPrefix("rule.") || ["file.search", "file.compute_duplicates", "file.find_duplicates"].contains(value)) }
    private func title(_ client: LocalMCPClient) -> String { AccessLabels.client(client, using: l10n) }
    private func operationTitle(_ value: String) -> String { AccessLabels.operation(value, using: l10n) }
}

enum AccessLabels {
    static func client(_ client: LocalMCPClient, using l10n: AgentLocalization) -> String { switch client { case .codex: "Codex"; case .deepseekHarness: "DeepSeek Harness"; case .legacy: l10n.text(.legacyMCP) } }
    static func operation(_ value: String, using l10n: AgentLocalization) -> String {
        let labels: [String: SharedText] = [
            "events.read": .capEvents,
            "file.list_roots": .capRoots,
            "file.scan": .capScan,
            "file.search": .capSearch,
            "file.analyze_storage": .capVolume,
            "file.compute_duplicates": .capComputeDuplicates,
            "file.find_duplicates": .capFindDuplicates,
            "file.get_audit_report": .capAudit,
            "system.get_info": .capSystemInfo,
            "system.get_metrics": .capSystemMetrics,
            "diagnostics.run": .capDiagnostics,
            "storage.get_overview": .capStorage,
            "diagnostics.history": .capDiagnosticsHistory,
            "monitor.list": .capMonitorList,
            "monitor.get": .capMonitorGet,
            "monitor.preview": .capMonitorPreview,
            "monitor.propose": .capMonitorPropose,
            "monitor.request_enable": .capMonitorEnable,
            "monitor.disable": .capMonitorDisable,
            "monitor.history": .capMonitorHistory,
            "rule.list": .capRuleList,
            "rule.get": .capRuleGet,
            "rule.validate": .capRuleValidate,
            "rule.propose": .capRulePropose,
            "rule.preview": .capRulePreview,
            "rule.run": .capRuleRun,
            "rule.request_enable": .capRuleEnable,
            "rule.disable": .capRuleDisable,
            "rule.history": .capRuleHistory,
        ]
        return labels[value].map { l10n.text($0) } ?? value
    }
}

/// Снимок языка привязан к жизни sheet. Изменение режима в другом окне не
/// меняет язык уже показанного согласия и не пересоздаёт approval plan.
struct AccessReviewView: View {
    @ObservedObject var model: AccessModel
    let plan: LocalAccessPlan
    @State private var copy: ConfirmationLanguage
    init(model: AccessModel, plan: LocalAccessPlan, language: AgentLanguage) {
        self.model = model; self.plan = plan
        _copy = State(initialValue: ConfirmationLanguage(language: language))
    }
    private var l10n: AgentLocalization { copy.localization }
    var body: some View {
        ScrollView { AccessReviewContent(model: model, plan: plan, l10n: l10n) }
            .frame(minWidth: 400, idealWidth: 560, minHeight: 340, idealHeight: 560)
    }
}

/// Единственное содержимое согласия используется sheet и offscreen preview.
/// ScrollView остаётся в обёртке, а preview проверяет реальные тексты/контролы,
/// не пытаясь захватить отдельную compositor surface NSScrollView.
struct AccessReviewContent: View {
    @ObservedObject var model: AccessModel
    let plan: LocalAccessPlan
    let l10n: AgentLocalization
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.message(.approveAccessTitle, .text(AccessLabels.client(plan.draft.client, using: l10n)))).font(.title2)
            Text(plan.draft.dataClass == .aggregate ? l10n.text(.aggregateDisclosure) : l10n.text(.metadataDisclosure))
            Text(l10n.message(.folders, .text(plan.draft.roots.map { id in model.scope.roots.first(where: { $0.id == id })?.name ?? l10n.text(.unavailableFolder) }.joined(separator: ", "))))
            Text(l10n.message(.operations, .text(plan.draft.capabilities.map { AccessLabels.operation($0, using: l10n) }.joined(separator: ", "))))
            Text(l10n.message(.accessLimits, .count(plan.draft.maximumSourceObjects), .count(Int(plan.draft.maximumSourceBytes / 1_048_576)), .count(plan.draft.maximumResultObjects), .count(plan.draft.maximumResponseBytes / 1024), .count(plan.draft.maximumRequests), .count(plan.draft.periodSeconds / 60)))
            Text(l10n.message(.accessExpiry, .count(plan.draft.lifetimeSeconds / 3600), .text(plan.expiresAt.formatted())))
            Text(l10n.text(.accessBoundary)).font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(SharedMessage.failure(error).localized(using: l10n)).foregroundStyle(.red) }
            HStack {
                Button(l10n.text(.cancel), role: .cancel) { model.reviewing = nil }
                    .keyboardShortcut(.cancelAction)
                Button(l10n.text(.approveAccess)) { Task { await model.approve(plan) } }.accessibilityIdentifier("access.approve").disabled(model.busy)
            }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
}
