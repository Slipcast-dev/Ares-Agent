import Foundation
import EcosystemLocalIPC
import Combine
import FileOrganizerCore
import UserNotifications

/// UI владеет только редактором и выбором. Чтение/изменение файлов выполняется
/// actor-координатором, поэтому ожидание ZIP не блокирует обработку кнопок.
@MainActor
final class RulesViewModel: ObservableObject {
    @Published var pendingPlans: [RulePlanSummary] = []
    @Published var reviewingFiles: [String] = []
    @Published var nextReviewOffset: Int?
    @Published var reviewingPlan: RulePlanSummary?
    private var runAfterApproval = false
    @Published var rules: [AutomationRule] = []
    @Published var roots: [AuthorizedRoot] = []
    @Published var runs: [RuleRun] = []
    @Published var editor: AutomationRule?
    @Published var checkResults: [RuleFileSnapshot] = []
    @Published var showCheckResults = false
    @Published var message: AresMessage?
    @Published var isBusy = false
    private var work: Task<Void, Never>?
    let container: AppContainer
    init(container: AppContainer) { self.container = container }

    func load() async {
        do {
            rules = try await container.fileRepository.ruleObjects(AutomationRule.self, table: .rules)
            roots = try await container.fileRepository.fetchRoots()
            if let remote = container.localRuntimeClient { pendingPlans = try await remote.get().call("rule.pending", RuleControlRequest()) }
            runs = try await container.fileRepository.ruleObjects(RuleRun.self, table: .runs).sorted { $0.createdAt > $1.createdAt }
        } catch { message = Self.presentation(error) }
    }
    func save(_ rule: AutomationRule) {
        message = nil
        Task {
            do {
                guard !rule.name.trimmingCharacters(in: .whitespaces).isEmpty, rule.rootID != nil, !rule.actions.isEmpty else { throw RuleExecutionError.invalidConfiguration }
                guard rule.days > 0, rule.threshold >= 0,
                      rule.conditions.minimumBytes.map({ $0 >= 0 }) ?? true,
                      rule.conditions.maximumBytes.map({ $0 >= (rule.conditions.minimumBytes ?? 0) }) ?? true else { throw RuleExecutionError.invalidConfiguration }
                if [.tagAdded, .tagRemoved, .textContains, .imageText, .documentType].contains(rule.event) && rule.eventValue.isEmpty { throw RuleExecutionError.invalidConfiguration }
                if [.textContains, .imageText, .documentType].contains(rule.event) && !rule.allowContentReading { throw RuleExecutionError.contentConsentRequired }
                for action in rule.actions {
                    if [.addTag, .removeTag, .createDirectories].contains(action.kind) && action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw RuleExecutionError.invalidConfiguration }
                    if [.archive, .copy].contains(action.kind) && !roots.contains(where: { $0.id == action.destinationRootID }) { throw RuleExecutionError.invalidConfiguration }
                    if action.kind == .runRule && (action.nextRuleID == nil || action.nextRuleID == rule.id) { throw RuleExecutionError.invalidConfiguration }
                }
                var saving = rule
                if container.isLocalRuntimeClient { saving.enabled = false }
                try await container.fileRepository.saveRuleObject(saving, id: saving.id.uuidString, table: .rules)
                editor = nil
                await load()
                if container.isLocalRuntimeClient && rule.enabled { requestEnabled(rule, enabled: true) }
            } catch { message = Self.presentation(error) }
        }
    }
    func duplicate(_ rule: AutomationRule, suffix: String) {
        var copy = rule; copy.id = UUID(); copy.name += suffix; copy.enabled = false
        copy.actions = copy.actions.map { var action = $0; action.id = UUID(); return action }
        editor = copy
    }
    func remove(_ rule: AutomationRule) {
        Task { do { try await container.fileRepository.deleteRule(id: rule.id); await load() } catch { message = Self.presentation(error) } }
    }
    func check(_ rule: AutomationRule) {
        perform {
            self.checkResults = try await self.container.ruleCoordinator.check(rule)
            self.showCheckResults = true
        }
    }
    func review(_ plan: RulePlanSummary, execute: Bool = false) {
        runAfterApproval = execute; reviewingFiles = plan.files
        nextReviewOffset = plan.fileCount > plan.files.count ? plan.files.count : nil
        reviewingPlan = plan
    }
    func moreReviewFiles() {
        guard let plan = reviewingPlan, let offset = nextReviewOffset, let remote = container.localRuntimeClient else { return }
        nextReviewOffset = nil
        Task {
            do {
                let page: RulePlanFilesPage = try await remote.get().call("rule.plan_files", RuleControlRequest(planID: plan.id, offset: offset))
                guard reviewingPlan?.id == plan.id else { return }
                reviewingFiles += page.files; nextReviewOffset = page.nextOffset
            } catch { nextReviewOffset = offset; message = Self.presentation(error) }
        }
    }
    func requestEnabled(_ rule: AutomationRule, enabled: Bool) {
        guard let remote = container.localRuntimeClient else { var updated = rule; updated.enabled = enabled; save(updated); return }
        Task {
            do {
                if enabled {
                    let plan: RulePlanSummary = try await remote.get().call("rule.request_enable", RuleControlRequest(ruleID: rule.id))
                    review(plan)
                } else {
                    let _: DisabledRuleReply = try await remote.get().call("rule.disable", RuleControlRequest(ruleID: rule.id))
                    await load()
                }
            } catch { message = Self.presentation(error) }
        }
    }
    func confirmPlan(_ plan: RulePlanSummary) {
        let execute = runAfterApproval; reviewingPlan = nil
        perform {
            guard let remote = self.container.localRuntimeClient else { return }
            let client = try remote.get()
            let _: RulePlanSummary = try await client.call("rule.approve", RuleControlRequest(planID: plan.id, fingerprint: plan.fingerprint))
            if execute && plan.kind == "run" {
                let id: LocalTaskID = try await client.call("rule.run", RuleControlRequest(ruleID: plan.ruleID, planID: plan.id, key: UUID().uuidString))
                let run: RuleRun = try await client.waitForResult(id.id)
                self.message = .init("Обработано совпадений: %@. Результат: %@.", messages: [.verbatim(run.matchedCount.formatted()), Self.statusMessage(run.status)])
            } else {
                self.message = .init(plan.kind == "enable" ? "Правило включено в пределах подтверждённых настроек и лимитов." : "План подтверждён. Клиент может запустить его до истечения срока.")
            }
            await self.load()
        }
    }
    func run(_ rule: AutomationRule) {
        if let remote = container.localRuntimeClient {
            perform {
                let client = try remote.get()
                let task: LocalTaskID = try await client.call("rule.preview", RuleControlRequest(ruleID: rule.id))
                let plan: RulePlanSummary = try await client.waitForResult(task.id)
                self.review(plan, execute: true)
            }
            return
        }
        perform {
            let run = try await self.container.ruleCoordinator.run(rule)
            self.message = .init("Обработано совпадений: %@. Результат: %@. Подробности — в истории.", messages: [.verbatim(run.matchedCount.formatted()), Self.statusMessage(run.status)])
            await self.load()
        }
    }
    func cancel() { work?.cancel() }
    func retry(_ previous: RuleRun) {
        guard let rule = rules.first(where: { $0.id == previous.ruleID }) else { return }
        if container.isLocalRuntimeClient { run(rule); return }
        let paths = Set(previous.results.filter { $0.status == "failed" }.map(\.relativePath))
        guard !paths.isEmpty else { message = .init("Нет действий с безопасно подтверждённой ошибкой для повтора."); return }
        perform {
            _ = try await self.container.ruleCoordinator.run(rule, paths: paths)
            await self.load()
        }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }; isBusy = true
        work = Task {
            defer { isBusy = false; work = nil }
            do { try await operation() } catch is CancellationError { message = .init("Выполнение отменено. Завершённые действия сохранены в истории.") }
            catch { message = Self.presentation(error) }
        }
    }
    /// Известные ошибки переводятся по типу; произвольные ошибки ОС
    /// заменяются безопасным сообщением без локальных путей и секретов.
    private static func presentation(_ error: Error) -> AresMessage {
        .runtime(AresErrorLocalization.message(for: error))
    }

    private static func statusMessage(_ status: String) -> AresMessage {
        switch status {
        case "running", "recoveryRequired", "completed", "partial_or_failed", "failed", "cancelled", "interrupted", "skipped":
            return .init(RulePresentation.status(status))
        default: return .verbatim(status)
        }
    }

    func requestNotifications() {
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                message = .init(allowed ? "Уведомления разрешены." : "Уведомления выключены в macOS.")
            } catch { message = Self.presentation(error) }
        }
    }
}

private struct DisabledRuleReply: Decodable { let enabled: Bool; let currentTaskCancellationRequested: Bool }
