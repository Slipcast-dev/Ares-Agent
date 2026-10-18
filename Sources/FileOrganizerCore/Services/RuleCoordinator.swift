import Foundation
import EcosystemLocalIPC
import EcosystemRuntimeSupport
import CryptoKit
import UserNotifications

/// Одна очередь на экземпляр приложения: actor не допускает одновременные
/// мутации, а цепочка UUID ограничивает рекурсию. Папки назначений получают
/// собственный scope и никогда не выбираются произвольной строкой пути.
public actor RuleCoordinator {
    private let repository: any FileRepository
    private let access: AuthorizedRootAccessService
    private let actions = RuleFileActions()
    private let analyzer = RuleContentAnalyzer()
    private var busy = false
    private var polling = false
    private var scheduler: LocalAutomationScheduleStore?
    private var recordNotification: (@Sendable (String) async throws -> Void)?
    public func configureAutomation(scheduler: LocalAutomationScheduleStore, recordNotification: @escaping @Sendable (String) async throws -> Void) {
        self.scheduler = scheduler; self.recordNotification = recordNotification
    }
    // Общий бюджет всей цепочки, включая ветвления, не только глубина рекурсии.
    private var chainObjects = 0
    private var chainBytes: Int64 = 0
    private var chainRuns = 0
    private var chainOutputBytes: Int64 = 0
    private var chainMaximumObjects = 1000
    private var chainMaximumBytes: Int64 = 1_073_741_824
    private let executionLock: RuleExecutionLock
    private let remote: Result<LocalRPCClient, Error>?
    public init(repository: any FileRepository, access: AuthorizedRootAccessService, lockURL: URL, remote: Result<LocalRPCClient, Error>? = nil) {
        self.repository = repository; self.access = access; self.executionLock = RuleExecutionLock(url: lockURL); self.remote = remote
    }

    public func check(_ rule: AutomationRule) async throws -> [RuleFileSnapshot] {
        if let remote {
            let client = try remote.get()
            let task: LocalTaskID = try await client.call("work.submit", AresSubmission(capability: "rule.check", job: AresJob(rule: rule), key: UUID().uuidString))
            return try await client.waitForResult(task.id)
        }
        let (_, url) = try await resolve(rule.rootID)
        guard url.startAccessingSecurityScopedResource() else { throw RuleExecutionError.accessRevoked }
        defer { url.stopAccessingSecurityScopedResource() }
        let previous = try await observation(rule.id)
        return try snapshot(url, previous: previous).filter { RuleMatching.matches($0, rule: rule) }
    }

    public func run(_ rule: AutomationRule, origin: String = "manual", paths: Set<String>? = nil, chain: Set<UUID> = [], context: QueueExecutionContext? = nil, plannedFiles: [RuleFileSnapshot]? = nil) async throws -> RuleRun {
        if let remote {
            let client = try remote.get()
            let task: LocalTaskID = try await client.call("rule.run", RuleControlRequest(ruleID: rule.id, key: UUID().uuidString))
            return try await client.waitForResult(task.id)
        }
        try await context?.checkpoint()
        if let root = rule.rootID { try await context?.authorizeRoot(root) }
        if context != nil {
            let governance = RuleGovernance(repository: repository, access: access, coordinator: self)
            try await governance.validate(rule)
            guard !RulePolicy.requiresGUI(rule) else { throw RulePolicyError.guiRequired }
            if plannedFiles == nil { try await governance.authorized(rule) }
        }
        guard !busy else { throw RuleExecutionError.busy }
        guard !chain.contains(rule.id), chain.count < 8 else { throw RuleExecutionError.invalidConfiguration }
        var descriptor: Int32? = try executionLock.acquire()
        defer { if let descriptor { executionLock.release(descriptor) } }
        busy = true
        defer { busy = false }
        let (_, url) = try await resolve(rule.rootID)
        guard url.startAccessingSecurityScopedResource() else { throw RuleExecutionError.accessRevoked }
        defer { url.stopAccessingSecurityScopedResource() }
        var run = RuleRun(rule: rule, origin: origin)
        run.taskID = context?.lease.taskID
        try await persist(run)
        do {
        let previous = try await observation(rule.id)
        let initial = try snapshot(url, previous: previous)
        // Ручной запуск тоже ждёт стабильного состояния, а не читает растущий файл.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let fresh = try snapshot(url, previous: RuleObservation(files: initial))
        let oldByPath = Dictionary(uniqueKeysWithValues: initial.map { ($0.relativePath, $0) })
        var matched = fresh.filter {
            RuleMatching.matches($0, rule: rule) && (paths == nil || paths!.contains($0.relativePath)) &&
            oldByPath[$0.relativePath]?.fingerprint == $0.fingerprint
        }
        // Проверяем budget до чтения OCR/text/hash условий, а не только
        // по оставшимся совпадениям после чтения содержимого.
        let conditionCandidates = fresh.filter { RuleMatching.matches($0, rule: rule) }
        let conditionBytes = try RulePolicy.quotas(conditionCandidates, rule: rule)
        let readsConditionContent = [.textContains, .imageText, .documentType, .duplicate].contains(rule.event)
        try await context?.authorizeBudget(objects: conditionCandidates.count, bytes: readsConditionContent ? conditionBytes : 0)
        matched = try await evaluated(rule, root: url, files: matched)
        if let plannedFiles {
            // Не расширяем утверждённый набор при новом файле между preview/run.
            let current = try await evaluated(rule, root: url, files: fresh.filter { RuleMatching.matches($0, rule: rule) })
            guard Set(current.map(\.relativePath)) == Set(plannedFiles.map(\.relativePath)),
                  Dictionary(current.map { ($0.relativePath, $0.fingerprint) }, uniquingKeysWith: { first, _ in first }) == Dictionary(plannedFiles.map { ($0.relativePath, $0.fingerprint) }, uniquingKeysWith: { first, _ in first }) else { throw RulePolicyError.stale }
        }
        let inputBytes = try RulePolicy.quotas(matched, rule: rule)
        if chain.isEmpty {
            chainObjects = 0; chainBytes = 0; chainRuns = 0; chainOutputBytes = 0
            chainMaximumObjects = rule.maximumFiles ?? 1000; chainMaximumBytes = rule.maximumBytes ?? 1_073_741_824
        }
        let (nextBytes, overflow) = chainBytes.addingReportingOverflow(inputBytes)
        guard !overflow, chainRuns < 8, chainObjects + matched.count <= chainMaximumObjects, nextBytes <= chainMaximumBytes else { throw RulePolicyError.quota }
        chainObjects += matched.count; chainBytes = nextBytes; chainRuns += 1
        try await context?.authorizeBudget(objects: chainObjects, bytes: chainBytes)
        var executionVersions = Dictionary(matched.compactMap { file in file.version.map { (file.relativePath, $0) } }, uniquingKeysWith: { first, _ in first })
        if context != nil {
            var destinations: [UUID: Int64] = [:]
            for action in rule.actions where [.copy, .archive].contains(action.kind) {
                guard let id = action.destinationRootID else { throw RulePolicyError.invalid }
                let estimated = inputBytes * (action.kind == .archive ? 2 : 1)
                destinations[id, default: 0] += estimated
                chainOutputBytes += estimated
                guard chainOutputBytes <= 3_221_225_472 else { throw RulePolicyError.quota }
            }
            for (id, bytes) in destinations {
                try await context?.authorizeRoot(id)
                let (_, target) = try await resolve(id)
                guard target.startAccessingSecurityScopedResource() else { throw RuleExecutionError.accessRevoked }
                defer { target.stopAccessingSecurityScopedResource() }
                try SecureRuleIO.space(SecureRuleIO.directory(target), bytes: bytes)
            }
        }
        run.matchedCount = matched.count
        var nextRules: [UUID] = []
        var failedPaths = Set<String>()
        for action in rule.actions {
            // Сначала одно действие для всех совпадений, затем следующее: ZIP
            // после тегирования видит обновлённые метаданные всего набора.
            for file in matched {
                guard !failedPaths.contains(file.relativePath) else {
                    // Не скрываем невыполненные шаги: журнал должен объяснить,
                    // почему цепочка остановилась для конкретного файла.
                    run.results.append(RuleActionResult(actionID: action.id, kind: action.kind, relativePath: file.relativePath, status: "skipped", message: "Предыдущее действие для файла завершилось ошибкой"))
                    continue
                }
                try Task.checkCancellation()
                try await context?.checkpoint()
                // Проверяем bookmark перед каждым действием: удалённый доступ
                // приостанавливает правило даже при уже открытом scope.
                guard let rootID = rule.rootID, try await repository.root(withID: rootID) != nil else { throw RuleExecutionError.accessRevoked }
                try await context?.authorizeRoot(rootID)
                if let target = action.destinationRootID { try await context?.authorizeRoot(target) }
                if origin != "manual" {
                    guard let saved = try await repository.ruleObject(AutomationRule.self, id: rule.id.uuidString, table: .rules), saved.enabled else { throw CancellationError() }
                }
                let version = action.kind == .archive && action.archiveTogether ? matched.map(\.fingerprint).sorted().joined(separator: "\n") : file.fingerprint
                let keyText = rule.id.uuidString + action.id.uuidString + version
                let receipt = SHA256.hash(data: Data(keyText.utf8)).map { String(format: "%02x", $0) }.joined()
                let status = try await repository.ruleObject(String.self, id: receipt, table: .receipts)
                if status != nil && status != "failed" {
                    run.results.append(RuleActionResult(actionID: action.id, kind: action.kind, relativePath: file.relativePath, status: "skipped", message: status == "done" ? "Уже выполнено для этой версии файла" : "Предыдущее выполнение требует проверки"))
                    continue
                }
                // Для UI действий без доступного GUI нет вымышленного success.
                if [.showFiles, .showDuplicates].contains(action.kind), context != nil { throw RulePolicyError.guiRequired }
                var currentFile = file
                if let version = executionVersions[file.relativePath] { currentFile.version = version }
                try await repository.saveRuleObject("started", id: receipt, table: .receipts)
                do {
                    if action.kind == .runRule {
                        guard let next = action.nextRuleID, !chain.contains(next), next != rule.id else { throw RuleExecutionError.invalidConfiguration }
                        if !nextRules.contains(next) { nextRules.append(next) }
                    } else {
                        let executionFile = currentFile
                        let batch = matched.filter { !failedPaths.contains($0.relativePath) }.map { original -> RuleFileSnapshot in
                            var value = original; value.version = executionVersions[value.relativePath]; return value
                        }
                        if let context {
                            // Started фиксируется ДО API файловой системы. Ошибка
                            // после входа в callback оставляет неизвестный исход.
                            var destination = "Не применяется"
                            if let destinationID = action.destinationRootID, let target = try await repository.root(withID: destinationID) { destination = target.relativePathHint + "/Ares Results" }
                            // Контекст хранится в приватной очереди и выдаётся только
                            // GUI. Нужны обе папки, чтобы оператор мог найти результат.
                            let summary = "Правило: \(rule.name)\nДействие: \(action.kind.title)\nИсходная папка: \(url.path)\nФайл: \(file.relativePath)\nНазначение: \(destination)\nПараметр: \(action.value)"
                            _ = try await context.recordedAction(key: "rule." + receipt, summary: String(summary.prefix(900))) { [self] in
                                try await self.execute(action, file: executionFile, rootURL: url, receipt: receipt, batch: batch)
                                return Data("effect-confirmed".utf8)
                            }
                        } else {
                            try await execute(action, file: executionFile, rootURL: url, receipt: receipt, batch: batch)
                        }
                    }
                    try await repository.saveRuleObject("done", id: receipt, table: .receipts)
                    run.results.append(RuleActionResult(actionID: action.id, kind: action.kind, relativePath: file.relativePath, status: "completed", message: "Выполнено"))
                } catch {
                    // Безопасные отказы допускают повтор; неопределённый started
                    // после аварийного завершения остаётся блокировкой повтора.
                    if context != nil {
                        // Не разрешаем повтор неизвестного эффекта: общая очередь
                        // сохранит recoveryRequired и доменный карантин.
                        throw error
                    }
                    try await repository.saveRuleObject("failed", id: receipt, table: .receipts)
                    run.results.append(RuleActionResult(actionID: action.id, kind: action.kind, relativePath: file.relativePath, status: "failed", message: (error as? LocalizedError)?.errorDescription ?? "Операция не выполнена"))
                    failedPaths.insert(file.relativePath)
                }
                if [.addTag, .removeTag].contains(action.kind), !file.isDirectory {
                    executionVersions[file.relativePath] = try VerifiedFileReader.capture(root: url, relative: file.relativePath)
                }
                try await persist(run)
            }
        }
        run.status = run.results.contains { $0.status == "failed" } ? "partial_or_failed" : "completed"
        try await persist(run)
        if !matched.isEmpty, rule.actions.contains(where: { $0.kind == .showFiles || $0.kind == .showDuplicates }) {
            let rootID = rule.rootID!
            for file in matched where !file.isDirectory { try await repository.upsertRuleFile(file, rootID: rootID) }
            let paths = matched.map(\.relativePath)
            let duplicates = rule.actions.contains { $0.kind == .showDuplicates }
            await MainActor.run {
                NotificationCenter.default.post(name: Notification.Name("FileOrganizer.ruleNavigation"), object: nil,
                    userInfo: ["rootID": rootID, "paths": paths, "duplicates": duplicates])
            }
        }
        // Снимок после своих действий предотвращает реакцию на собственные теги,
        // ZIP и копии того же правила при следующем цикле наблюдения.
        var after = previous
        after.files = try snapshot(url, previous: previous)
        after.initialized = true
        after.lastCheckedAt = Date()
        try await repository.saveRuleObject(after, id: rule.id.uuidString, table: .observations)
        busy = false
        if let held = descriptor { executionLock.release(held); descriptor = nil }
        var nextChain = chain; nextChain.insert(rule.id)
        let rules = try await repository.ruleObjects(AutomationRule.self, table: .rules)
        let followers = rules.filter { $0.enabled && $0.sourceRuleID == rule.id && (($0.event == .ruleSucceeded && run.status == "completed") || ($0.event == .ruleFailed && run.status != "completed")) }
        for next in Set(nextRules + followers.map(\.id)) {
            if let target = rules.first(where: { $0.id == next && $0.enabled }), !nextChain.contains(next) {
                _ = try await self.run(target, origin: "chain", chain: nextChain, context: context)
            }
        }
        return run
        } catch {
            run.status = error is CancellationError ? "cancelled" : "failed"
            run.results.append(RuleActionResult(actionID: UUID(), kind: .log, relativePath: "", status: run.status,
                message: (error as? LocalizedError)?.errorDescription ?? "Выполнение остановлено; завершённые действия сохранены."))
            try await persist(run)
            throw error
        }
    }

    public func poll(appLaunch: Bool = false, context: QueueExecutionContext? = nil) async throws {
        if let remote {
            let client = try remote.get()
            do {
                let task: LocalTaskID = try await client.call("work.submit", AresSubmission(capability: "rule.poll", job: AresJob(appLaunch: appLaunch), key: UUID().uuidString))
                let _: LocalEmpty = try await client.waitForResult(task.id, cancelOnCancellation: false)
            } catch LocalRuntimeFailure.busy { return }
            return
        }
        try await context?.checkpoint()
        guard !busy, !polling else { return }
        polling = true
        defer { polling = false }
        if appLaunch {
            // Не помечаем работу другого живого процесса как прерванную.
            if let held = try? executionLock.acquire() {
                defer { executionLock.release(held) }
                for var interrupted in try await repository.ruleObjects(RuleRun.self, table: .runs) where interrupted.status == "running" {
                    interrupted.status = "interrupted"
                    try await persist(interrupted)
                }
            }
        }
        let rules = try await repository.ruleObjects(AutomationRule.self, table: .rules)
        var recovering = appLaunch
        for rule in rules where rule.enabled {
            if let last = try await observation(rule.id).lastCheckedAt, Date().timeIntervalSince(last) > 90 { recovering = true }
        }
        var slots: [UUID: LocalAutomationSlot] = [:]
        if let scheduler {
            let existing = await scheduler.schedules()
            for rule in rules where rule.event == .scheduled {
                let trigger: LocalAutomationTrigger
                var anchor = rule.scheduleDate.addingTimeInterval(-1)
                var calendar = Calendar(identifier: .gregorian)
                if let zone = rule.scheduleTimeZone, let timeZone = TimeZone(identifier: zone) { calendar.timeZone = timeZone }
                switch rule.schedule {
                case .once: trigger = .once(at: rule.scheduleDate)
                case .daily where rule.scheduleTimeZone != nil:
                    trigger = .daily(hour: calendar.component(.hour, from: rule.scheduleDate), minute: calendar.component(.minute, from: rule.scheduleDate), timeZoneIdentifier: calendar.timeZone.identifier)
                case .weekly where rule.scheduleTimeZone != nil:
                    trigger = .weekly(weekday: calendar.component(.weekday, from: rule.scheduleDate), hour: calendar.component(.hour, from: rule.scheduleDate), minute: calendar.component(.minute, from: rule.scheduleDate), timeZoneIdentifier: calendar.timeZone.identifier)
                default:
                    let seconds = rule.schedule == .daily ? 86400 : rule.schedule == .weekly ? 604800 : rule.intervalSeconds
                    trigger = .interval(seconds: seconds); anchor = rule.scheduleDate.addingTimeInterval(-Double(seconds))
                }
                let schedule = LocalAutomationSchedule(id: rule.id, trigger: trigger, createdAt: anchor, paused: !rule.enabled, catchUpOnce: rule.catchUpOnce)
                try await scheduler.upsert(schedule)
                if let old = existing.first(where: { $0.id == rule.id }), old.paused != schedule.paused { try await scheduler.setPaused(rule.id, paused: schedule.paused, now: Date()) }
            }
            for old in existing where !rules.contains(where: { $0.id == old.id && $0.event == .scheduled }) { try await scheduler.remove(old.id) }
            slots = Dictionary(uniqueKeysWithValues: try await scheduler.due(now: Date(), recovering: recovering).map { ($0.scheduleID, $0) })
        }
        for rule in rules where rule.enabled && rule.event != .manual && rule.event != .ruleSucceeded && rule.event != .ruleFailed {
            try Task.checkCancellation()
            do {
                if context != nil { try await RuleGovernance(repository: repository, access: access, coordinator: self).authorized(rule) }
                let (_, url) = try await resolve(rule.rootID)
                guard url.startAccessingSecurityScopedResource() else { throw RuleExecutionError.accessRevoked }
                if rule.event == .diskConnected,
                   (try? url.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) != false {
                    url.stopAccessingSecurityScopedResource()
                    throw RuleExecutionError.invalidConfiguration
                }
                let state: RuleObservation
                let files: [RuleFileSnapshot]
                do { state = try await observation(rule.id); files = try snapshot(url, previous: state) }
                catch { url.stopAccessingSecurityScopedResource(); throw error }
                url.stopAccessingSecurityScopedResource()
                var updated = state
                let before = Dictionary(uniqueKeysWithValues: state.files.map { ($0.relativePath, $0) })
                let identities = Dictionary(state.files.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
                var total: Int64 = 0
                for file in files where !file.isDirectory {
                    let (next, overflow) = total.addingReportingOverflow(file.byteSize)
                    guard !overflow else { throw RulePolicyError.quota }; total = next
                }
                let now = Date()
                let scheduleDue = scheduler == nil ? due(rule, state: state, now: now, launching: appLaunch) : slots[rule.id] != nil
                var paths = Set<String>()
                for file in files where RuleMatching.matches(file, rule: rule) {
                    let old = before[file.relativePath]
                    let isStable = now.timeIntervalSince(file.stableSince) >= 2
                    var trigger = false
                    switch rule.event {
                    case .arrived, .stabilized: trigger = old == nil
                    case .modified: trigger = old.map { $0.fingerprint != file.fingerprint } ?? rule.processExisting
                    case .renamed: trigger = old == nil && identities[file.identity].map { $0.relativePath != file.relativePath } == true
                    case .directoryCreated: trigger = file.isDirectory && old == nil
                    case .tagAdded: trigger = file.tags.contains(rule.eventValue) && !(old?.tags.contains(rule.eventValue) ?? false)
                    case .tagRemoved: trigger = !file.tags.contains(rule.eventValue) && (old?.tags.contains(rule.eventValue) ?? false)
                    case .unchanged: trigger = file.modifiedAt.map { now.timeIntervalSince($0) >= Double(rule.days) * 86_400 } ?? false
                    case .resident: trigger = now.timeIntervalSince(file.firstSeenAt) >= Double(rule.days) * 86_400
                    case .fileSize: trigger = file.byteSize >= rule.threshold
                    case .folderSize: trigger = total >= rule.threshold
                    case .fileCount: trigger = Int64(files.filter { !$0.isDirectory }.count) >= rule.threshold
                    case .scheduled: trigger = scheduleDue
                    case .appLaunch: trigger = appLaunch
                    case .diskConnected: trigger = !state.initialized
                    case .textContains, .imageText, .documentType, .duplicate: trigger = old == nil || old?.fingerprint != file.fingerprint
                    default: break
                    }
                    if !state.initialized && !rule.processExisting && ![RuleEvent.scheduled, .appLaunch, .diskConnected].contains(rule.event) { trigger = false }
                    if trigger { updated.pending[file.relativePath] = file.fingerprint }
                    if updated.pending[file.relativePath] != nil && (isStable || file.isDirectory) {
                        if updated.processed[file.relativePath] != file.fingerprint { paths.insert(file.relativePath) }
                        updated.pending.removeValue(forKey: file.relativePath)
                    }
                }
                updated.files = files
                updated.lastCheckedAt = now
                updated.initialized = true
                if scheduleDue && !paths.isEmpty { updated.lastScheduledAt = now }
                if appLaunch && rule.event == .scheduled && !rule.catchUpOnce && now > rule.scheduleDate { updated.lastScheduledAt = now }
                try await repository.saveRuleObject(updated, id: rule.id.uuidString, table: .observations)
                if let slot = slots[rule.id], let scheduler { try await scheduler.acknowledge(slot, now: now) }
                if !paths.isEmpty {
                    let completed = try await run(rule, origin: "automatic", paths: paths, context: context)
                    if completed.status == "completed" {
                        var finished = try await observation(rule.id)
                        for file in finished.files where paths.contains(file.relativePath) { finished.processed[file.relativePath] = file.fingerprint }
                        try await repository.saveRuleObject(finished, id: rule.id.uuidString, table: .observations)
                    }
                }
            } catch {
                if rule.event == .diskConnected {
                    var disconnected = try await observation(rule.id)
                    disconnected.initialized = false
                    try await repository.saveRuleObject(disconnected, id: rule.id.uuidString, table: .observations)
                }
                var entry = RuleRun(rule: rule, origin: "automatic")
                entry.status = "failed"
                entry.results = [RuleActionResult(actionID: UUID(), kind: .log, relativePath: "", status: "failed", message: (error as? LocalizedError)?.errorDescription ?? "Не удалось проверить папку")]
                try await persist(entry)
            }
        }
    }

    private func due(_ rule: AutomationRule, state: RuleObservation, now: Date, launching: Bool) -> Bool {
        guard rule.event == .scheduled, now >= rule.scheduleDate else { return false }
        let seconds: TimeInterval
        switch rule.schedule {
        case .once: return state.lastScheduledAt == nil && (!launching || rule.catchUpOnce || now.timeIntervalSince(rule.scheduleDate) < 30)
        case .daily: seconds = 86_400
        case .weekly: seconds = 7 * 86_400
        case .interval: seconds = Double(max(rule.intervalSeconds, 30))
        }
        let last = state.lastScheduledAt ?? rule.scheduleDate.addingTimeInterval(-seconds)
        return now.timeIntervalSince(last) >= seconds && (!launching || rule.catchUpOnce)
    }

    public func preview(_ rule: AutomationRule, context: QueueExecutionContext? = nil) async throws -> [RuleFileSnapshot] {
        try await context?.checkpoint()
        if let root = rule.rootID { try await context?.authorizeRoot(root) }
        let (_, url) = try await resolve(rule.rootID)
        guard url.startAccessingSecurityScopedResource() else { throw RuleExecutionError.accessRevoked }
        defer { url.stopAccessingSecurityScopedResource() }
        let previous = try await observation(rule.id)
        let initial = try snapshot(url, previous: previous)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let fresh = try snapshot(url, previous: RuleObservation(files: initial))
        let old = Dictionary(initial.map { ($0.relativePath, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        let candidates = fresh.filter { RuleMatching.matches($0, rule: rule) }
        let candidateBytes = try RulePolicy.quotas(candidates, rule: rule)
        let readsContent = [.textContains, .imageText, .documentType, .duplicate].contains(rule.event)
        try await context?.authorizeBudget(objects: candidates.count, bytes: readsContent ? candidateBytes : 0)
        guard candidates.allSatisfy({ old[$0.relativePath] == $0.fingerprint }) else { throw RulePolicyError.stale }
        return try await evaluated(rule, root: url, files: candidates)
    }
    public func verifyPlanVersions(_ rule: AutomationRule, files: [RuleFileSnapshot]) async throws {
        let (_, root) = try await resolve(rule.rootID)
        guard root.startAccessingSecurityScopedResource() else { throw RuleExecutionError.accessRevoked }
        defer { root.stopAccessingSecurityScopedResource() }
        for file in files where !file.isDirectory {
            try Task.checkCancellation()
            guard let expected = file.version, try VerifiedFileReader.capture(root: root, relative: file.relativePath) == expected else { throw RulePolicyError.stale }
        }
    }
    public func verifyPlan(_ rule: AutomationRule, files: [RuleFileSnapshot], context: QueueExecutionContext? = nil) async throws {
        let current = try await preview(rule, context: context)
        guard current.map(\.fingerprint).sorted() == files.map(\.fingerprint).sorted() else { throw RulePolicyError.stale }
    }
    private func evaluated(_ rule: AutomationRule, root: URL, files: [RuleFileSnapshot]) async throws -> [RuleFileSnapshot] {
        var result = files
        if rule.actions.contains(where: { [.copy, .archive, .addTag, .removeTag].contains($0.kind) }) { result.removeAll { $0.isDirectory } }
        if [.textContains, .imageText, .documentType].contains(rule.event) {
            let candidates = result; result = []
            for file in candidates where !file.isDirectory {
                guard let version = file.version else { throw RulePolicyError.stale }
                guard try VerifiedFileReader.capture(root: root, relative: file.relativePath) == version else { throw RulePolicyError.stale }
                if try await analyzer.matchesVerified(root: root, relative: file.relativePath, expected: version, event: rule.event, value: rule.eventValue, consent: rule.allowContentReading) { result.append(file) }
                guard try VerifiedFileReader.capture(root: root, relative: file.relativePath) == version else { throw RulePolicyError.stale }
            }
        }
        if rule.event == .duplicate {
            var hashes: [String: [RuleFileSnapshot]] = [:]
            for candidates in Dictionary(grouping: files.filter { !$0.isDirectory }, by: \.byteSize).values where candidates.count > 1 {
                for file in candidates {
                    guard let version = file.version else { throw RulePolicyError.stale }
                    let hash = try VerifiedFileReader.hash(root: root, relative: file.relativePath, expected: version)
                    hashes[hash, default: []].append(file)
                }
            }
            result = hashes.values.filter { $0.count > 1 }.flatMap { $0 }
        }
        if rule.actions.contains(where: { [.addTag, .removeTag].contains($0.kind) }) {
            for file in result {
                guard let version = file.version else { throw RulePolicyError.stale }
                try SecureRuleIO.singleLink(root: root, relative: file.relativePath, version: version)
            }
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }
    private func execute(_ action: RuleAction, file: RuleFileSnapshot, rootURL: URL, receipt: String, batch: [RuleFileSnapshot]) async throws {
        let source = try safe(file.relativePath, in: rootURL)
        if !file.isDirectory {
            let current = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard Int64(current.fileSize ?? 0) == file.byteSize, current.contentModificationDate == file.modifiedAt else { throw RuleExecutionError.verificationFailed }
        }
        switch action.kind {
        case .addTag, .removeTag:
            guard let version = file.version else { throw RuleExecutionError.invalidConfiguration }
            try SecureRuleIO.tag(root: rootURL, relative: file.relativePath, version: version, value: action.value, remove: action.kind == .removeTag)
        case .archive, .copy:
            guard !file.isDirectory else { throw RuleExecutionError.invalidConfiguration }
            let (_, target) = try await resolve(action.destinationRootID)
            guard target.startAccessingSecurityScopedResource() else { throw RuleExecutionError.accessRevoked }
            defer { target.stopAccessingSecurityScopedResource() }
            guard let version = file.version else { throw RulePolicyError.stale }
            let suffix = String(receipt.prefix(12))
            let base = SecureRuleIO.shortName(action.archiveTogether ? "Archive" : source.lastPathComponent)
            let ext = source.pathExtension.utf8.count <= 40 && !source.pathExtension.isEmpty ? "." + source.pathExtension : ""
            let name = action.kind == .archive ? base + "-" + suffix + ".zip" : SecureRuleIO.shortName(source.deletingPathExtension().lastPathComponent) + "-" + suffix + ext
            if action.kind == .copy {
                try SecureRuleIO.copy(root: rootURL, relative: file.relativePath, version: version, destinationRoot: target, name: name)
            } else {
                try await actions.archiveVerified(root: rootURL, files: action.archiveTogether ? batch.filter { !$0.isDirectory } : [file], destinationRoot: target, name: name)
            }
        case .createDirectories:
            for path in action.value.split(separator: "\n").map(String.init) {
                _ = try SecureRuleIO.directory(rootURL, relative: path, create: true)
            }
        case .notify:
            if let recordNotification { try await recordNotification(receipt); return }
            guard Bundle.main.bundleURL.pathExtension == "app" else { throw RuleExecutionError.notificationsDisabled }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { throw RuleExecutionError.notificationsDisabled }
            let content = UNMutableNotificationContent()
            content.title = "Ares"
            content.body = "Правило обработало файл. Подробности в истории приложения."
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: receipt, content: content, trigger: nil))
        case .log, .showFiles, .showDuplicates, .runRule: break
        }
    }

    private func resolve(_ id: UUID?) async throws -> (AuthorizedRoot, URL) {
        guard let id, let root = try await repository.root(withID: id) else { throw RuleExecutionError.accessRevoked }
        return (root, try await access.resolveURL(for: root))
    }
    private func observation(_ id: UUID) async throws -> RuleObservation {
        try await repository.ruleObject(RuleObservation.self, id: id.uuidString, table: .observations) ?? RuleObservation()
    }
    private func persist(_ run: RuleRun) async throws { try await repository.saveRuleObject(run, id: run.id.uuidString, table: .runs) }
    private func safe(_ path: String, in root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw RuleExecutionError.unsafePath }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path == url.path, url.path.hasPrefix(base.path + "/") else { throw RuleExecutionError.unsafePath }
        return url
    }

    private func snapshot(_ root: URL, previous: RuleObservation) throws -> [RuleFileSnapshot] {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard canonical.hasPrefix(temporary) || FileLocationAssessment.assess(rootPath: canonical, relativePath: "") == .ordinary else { throw RuleExecutionError.unsafePath }
        let rootIsProject = [".git", "package.json", "Package.swift", "pyproject.toml", "Cargo.toml", "CMakeLists.txt"].contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        if rootIsProject { return [] }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .fileResourceIdentifierKey, .tagNamesKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw RuleExecutionError.accessRevoked }
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let previousByIdentity = Dictionary(previous.files.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [RuleFileSnapshot] = []
        let now = Date()
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            let itemPath = url.standardizedFileURL.path
            guard values.isSymbolicLink != true, itemPath.hasPrefix(prefix) else { continue }
            let relative = String(itemPath.dropFirst(prefix.count))
            let parts = relative.split(separator: "/")
            let blocked = ["Library", "System", "Applications", "node_modules", "Pods", "vendor", "Ares Results", "File Organizer Results"]
            if parts.contains(where: { part in blocked.contains(where: { $0.lowercased() == part.lowercased() }) || part.lowercased().hasSuffix(".app") || part.lowercased().hasSuffix(".framework") || part.lowercased().hasSuffix(".bundle") }) { enumerator.skipDescendants(); continue }
            if values.isDirectory == true {
                let project = [".git", "package.json", "Package.swift", "pyproject.toml", "Cargo.toml", "CMakeLists.txt"].contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
                if project { enumerator.skipDescendants(); continue }
            }
            guard values.isRegularFile == true || values.isDirectory == true,
                  !["download", "part", "crdownload"].contains(url.pathExtension.lowercased()) else { continue }
            guard result.count < 50_000 else { throw RulePolicyError.quota }
            let fileVersion = values.isRegularFile == true ? try VerifiedFileReader.capture(root: root, relative: relative) : nil
            let identity = values.fileResourceIdentifier.map { String(describing: $0) } ?? relative
            let old = previousByIdentity[identity]
            let same = old?.byteSize == Int64(values.fileSize ?? 0) && old?.modifiedAt == values.contentModificationDate
            result.append(RuleFileSnapshot(version: fileVersion, relativePath: relative, identity: identity, byteSize: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, createdAt: values.creationDate, tags: values.tagNames ?? [], firstSeenAt: old?.firstSeenAt ?? now, stableSince: same ? old!.stableSince : now, isDirectory: values.isDirectory == true))
        }
        return result
    }
}

private extension RuleObservation {
    init(files: [RuleFileSnapshot]) { self.init(); self.files = files }
}
