import Foundation
import XCTest
import EcosystemLocalIPC
import EcosystemLocalization
import EcosystemRuntimeSupport
@testable import FileOrganizerCore
@testable import FileOrganizer

/// Интеграция реальных UI model, SQLite, governance и очереди на временных данных.
/// RPC вызывается через service.handle: этот тест не имитирует системный XPC,
/// проверку подписи клиента или нажатие кнопки в настоящем окне согласия.
@MainActor
final class AresRuleLanguageWorkflowTests: XCTestCase {
    func testLanguageSwitchPreservesApprovalFingerprintAndIdempotentCopy() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/ares-l10n-workflow-" + UUID().uuidString)
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        defer { try? FileManager.default.removeItem(at: base) }
        for directory in [source, target] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let original = Data("Language-neutral source bytes 100% %@".utf8)
        try original.write(to: source.appendingPathComponent("Исходник.txt"))
        // Явное отключение environment-based client исключает подключение теста
        // к установленному агенту даже при унаследованной переменной окружения.
        let container = AppContainer(databaseURL: base.appendingPathComponent("state.sqlite"), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = try await container.authorizedRootAccess.addRoot(from: source)
        let destination = try await container.authorizedRootAccess.addRoot(from: target)
        let model = RulesViewModel(container: container)
        // Экран сначала загружает разрешённые папки; без этого UI validation
        // правильно отклоняет copy, даже если root уже существует в SQLite.
        await model.load()
        XCTAssertEqual(Set(model.roots.map(\.id)), Set([root.id, destination.id]))
        var rule = AutomationRule()
        rule.name = "Правило %@ / Sample"
        rule.rootID = root.id
        rule.conditions.extensions = ["txt"]
        rule.maximumFiles = 10
        rule.maximumBytes = 4096
        var action = RuleAction(kind: .copy)
        action.destinationRootID = destination.id
        rule.actions = [action]
        let initialRevision = try RulePolicy.revision(rule)
        model.editor = rule
        model.save(rule)
        try await waitUntil("save", model: model) { model.editor == nil && model.rules.contains(where: { $0.id == rule.id }) }
        XCTAssertNil(model.message)
        model.check(rule)
        try await waitUntil("check", model: model) { !model.isBusy }
        XCTAssertTrue(model.showCheckResults)
        XCTAssertEqual(model.checkResults.map(\.relativePath), ["Исходник.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Ares Results").path))

        let queue = try DurableTaskQueue(directory: base.appendingPathComponent("queue"), agentID: .ares)
        let work = try AresQueuedWork(queue: queue, repository: container.fileRepository,
                                      access: container.authorizedRootAccess, rules: container.ruleCoordinator)
        let service = AresRuntimeService(container: container, work: work)
        do {
            let previewTask: LocalTaskID = try await call(service, "rule.preview", RuleControlRequest(ruleID: rule.id), role: .mcp)
            let preview = try await finish(work, previewTask.id)
            let plan = try LocalWire.decode(RulePlanSummary.self, XCTUnwrap(preview.result))
            XCTAssertEqual(plan.fileCount, 1)
            XCTAssertEqual(plan.revision, initialRevision)
            XCTAssertFalse(plan.approved)
            let ru = AresLocalization(language: .russian), en = AresLocalization(language: .english)
            let frozen = ConfirmationLanguage(language: .russian)
            model.review(plan)
            XCTAssertEqual(ru.ruleActionTitle(plan.actions[0]), "Скопировать")
            XCTAssertEqual(en.ruleActionTitle(plan.actions[0]), "Copy")
            XCTAssertEqual(en.render(.verbatim(plan.name)), rule.name)
            XCTAssertTrue(AresLocalization(language: frozen.language).text("Подтвердить план?").contains("Подтвердить"))
            XCTAssertEqual(en.text("Подтвердить план?"), "Approve plan?")
            // Перевод текста не создаёт полномочий: роль MCP всё ещё не может
            // подтвердить просмотренный план даже после смены отображения.
            do {
                let _: RulePlanSummary = try await call(service, "rule.approve",
                    RuleControlRequest(planID: plan.id, fingerprint: plan.fingerprint), role: .mcp)
                XCTFail("MCP acquired approval through a language change")
            } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
            let checked = try await work.governance.checkedPlan(plan.id)
            XCTAssertEqual(checked.fingerprint, plan.fingerprint)
            let persistedBefore = try await container.fileRepository.ruleObject(AutomationRule.self, id: rule.id.uuidString, table: .rules)
            XCTAssertEqual(persistedBefore, rule)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("Ares Results").path))

            let approved: RulePlanSummary = try await call(service, "rule.approve",
                RuleControlRequest(planID: plan.id, fingerprint: plan.fingerprint), role: .gui)
            XCTAssertEqual(approved.fingerprint, plan.fingerprint)
            let request = RuleControlRequest(ruleID: rule.id, planID: plan.id, key: "bilingual-copy-once")
            let task: LocalTaskID = try await call(service, "rule.run", request, role: .gui)
            let result = try await finish(work, task.id)
            XCTAssertEqual(result.status.rawValue, "completed")
            let run = try LocalWire.decode(RuleRun.self, XCTUnwrap(result.result))
            XCTAssertEqual(run.status, "completed")
            XCTAssertEqual(en.ruleStatus(run.status), "Completed")
            XCTAssertEqual(ru.ruleStatus(run.status), "Завершено")
            let repeated: LocalTaskID = try await call(service, "rule.run", request, role: .gui)
            XCTAssertEqual(repeated.id, task.id)
            let output = try FileManager.default.contentsOfDirectory(at: target.appendingPathComponent("Ares Results"), includingPropertiesForKeys: nil)
            XCTAssertEqual(output.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(output.first)), original)
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("Исходник.txt")), original)
            let receipts = try await queue.receipts(task.id)
            XCTAssertEqual(receipts.count, 1)
            XCTAssertEqual(receipts.first?.state.rawValue, "done")
            await model.load()
            XCTAssertEqual(model.rules, [rule])
            XCTAssertEqual(try RulePolicy.revision(XCTUnwrap(model.rules.first)), initialRevision)
            let savedPlan = try await container.fileRepository.ruleObject(RulePlan.self, id: plan.id.uuidString, table: .plans)
            XCTAssertEqual(savedPlan?.fingerprint, plan.fingerprint)
            XCTAssertNotNil(savedPlan?.consumedAt)
            let historyBefore = try LocalWire.encode(model.runs)
            XCTAssertEqual(en.ruleStatus("cancelled"), "Cancelled")
            XCTAssertEqual(ru.ruleStatus("cancelled"), "Отменено")
            XCTAssertEqual(en.ruleStatus("recoveryRequired"), "Result review required")
            XCTAssertEqual(ru.ruleStatus("recoveryRequired"), "Требуется проверка результата")
            XCTAssertEqual(en.ruleStatus("Проверить"), "Проверить")
            XCTAssertEqual(try LocalWire.encode(model.runs), historyBefore)
            await work.shutdown()
        } catch {
            await work.shutdown()
            throw error
        }
    }

    private func waitUntil(_ phase: String, model: RulesViewModel, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            if let message = model.message {
                throw NSError(domain: "AresRuleLanguageWorkflowTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "UI phase \(phase) failed: " + AresLocalization(language: .english).render(message)])
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "AresRuleLanguageWorkflowTests", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "UI phase \(phase) timed out; busy=\(model.isBusy), editorOpen=\(model.editor != nil), rules=\(model.rules.count), roots=\(model.roots.count)"])
    }

    private func call<T: Decodable>(_ service: AresRuntimeService, _ operation: String,
                                    _ request: RuleControlRequest, role: LocalRole) async throws -> T {
        let data = try await service.handle(role: role,
            request: LocalRPCRequest(domain: "ares", operation: operation, payload: LocalWire.encode(request)))
        return try LocalWire.decode(T.self, data)
    }

    private func finish(_ work: AresQueuedWork, _ id: UUID) async throws -> DurableTask {
        for _ in 0..<500 {
            if let task = try await work.queue.task(id), task.status.isTerminal { return task }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw LocalRuntimeFailure.deadlineExceeded
    }
}
