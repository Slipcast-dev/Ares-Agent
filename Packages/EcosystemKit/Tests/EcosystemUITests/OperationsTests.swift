import AppKit
import SwiftUI
import EcosystemLocalization
import XCTest
import EcosystemContracts
import EcosystemRuntimeSupport
import EcosystemLocalIPC
@testable import EcosystemUI

/// Fixture моделирует отказы отдельных RPC без чтения настоящих профилей.
private actor OperationsFixture {
    var failed: Set<String> = []
    var requests: [String] = []
    var statuses: [TaskStatus] = [.running, .completed, .recoveryRequired]
    let ids = [UUID(), UUID(), UUID()]
    var healthy = true
    func makeUnhealthy() { healthy = false }
    var duplicate = false
    var stopped = false
    func fail(_ operations: Set<String>) { failed = operations }
    func duplicateTasks() { duplicate = true }
    func history() -> [String] { requests }
    func call(_ operation: String, _ payload: Data) throws -> Data {
        requests.append(operation)
        if failed.contains(operation) { throw NSError(domain: "/Users/private/SECRET_TOKEN", code: 1) }
        let object: Any
        switch operation {
        case "runtime.status": object = ["domain": "ares", "healthy": healthy, "privatePath": "/Users/private/SECRET_TOKEN"] as [String: Any]
        case "automation.status", "automation.configure":
            object = ["settings": ["paused": operation == "automation.configure", "notificationsEnabled": false, "createdAt": 0], "notificationAuthorization": "denied", "pendingEvents": 0, "lastFailure": "SECRET_TOKEN"] as [String: Any]
        case "automation.login_status": object = ["configured": false, "registered": true, "disabledBySystem": false]
        case "access.status": object = ["grants": [], "pending": []]
        case "events.list":
            let request = try LocalWire.decode(LocalAutomationRequest.self, payload)
            guard (1...50).contains(request.limit ?? 50) else { throw LocalRuntimeFailure.invalidRequest }
            object = [] as [String]
        case "operations.tasks":
            let rows = zip(ids, statuses).map { LocalOperationalTask(id: $0, status: $1) }
            return try LocalWire.encode(duplicate ? [rows[0], rows[0]] : rows)
        case "operations.emergency_status", "operations.emergency_stop", "operations.emergency_resume":
            if operation == "operations.emergency_stop" { stopped = true }
            if operation == "operations.emergency_resume" { stopped = false }
            return try LocalWire.encode(QueueEmergencyStatus(stopped: stopped, pendingTasks: 0, recoveryTasks: 0))
        case "task.cancel": object = [:] as [String: String]
        default: throw LocalRuntimeFailure.denied
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

@MainActor final class OperationsTests: XCTestCase {
    private func model(_ fixture: OperationsFixture) -> LocalOperationsModel {
        LocalOperationsModel(domain: "ares", transport: { try await fixture.call($0, $1) })
    }
    func testLanguageSwitchRendersExistingSnapshotWithoutRPCAndRetainsWarningState() async {
        let fixture = OperationsFixture(); await fixture.makeUnhealthy()
        let model = model(fixture); await model.refresh()
        let before = await fixture.history()
        let service = model.components.first { $0.id == "runtime.status" }
        XCTAssertEqual(service?.needsAttention, true)
        let ru = AgentLocalization(language: .russian), en = AgentLocalization(language: .english)
        XCTAssertEqual(service?.value.localized(using: ru), "Требует внимания")
        XCTAssertEqual(service?.value.localized(using: en), "Needs attention")
        XCTAssertTrue(model.report(language: .english).contains("Needs attention"))
        XCTAssertFalse(model.report(language: .english).contains("SECRET_TOKEN"))
        let after = await fixture.history(); XCTAssertEqual(after, before)
        XCTAssertEqual(service?.needsAttention, true)
    }
    func testAllTaskStatusesTranslateAndKeepMachineStates() {
        XCTAssertEqual(LocalOperationsSection.statusTitle(.cancelled, language: .english), "Cancelled")
        XCTAssertEqual(LocalOperationsSection.statusTitle(.recoveryRequired, language: .english), "Review required")
        XCTAssertEqual(Set(TaskStatus.allCases.map { LocalOperationsSection.statusTitle($0, language: .english) }).count, TaskStatus.allCases.count)
    }
    func testHealthyRuntimeHasNoUnavailableComponentsAndUsesSupportedEventLimit() async {
        let model = model(OperationsFixture()); await model.refresh()
        XCTAssertEqual(model.components.count, 7)
        XCTAssertTrue(model.components.allSatisfy(\.available))
    }
    func testOneUnavailableComponentDoesNotHideOtherResults() async {
        let fixture = OperationsFixture(); await fixture.fail(["automation.login_status"])
        let model = model(fixture); await model.refresh()
        XCTAssertEqual(model.components.count, 7)
        XCTAssertEqual(model.components.filter { !$0.available }.map(\.title), [.loginComponent])
        XCTAssertEqual(model.tasks.count, 3)
    }
    func testFailedRefreshClearsPreviousTasksAndNeverReportsEmptySuccess() async {
        let fixture = OperationsFixture(); let model = model(fixture)
        await model.refresh(); XCTAssertEqual(model.tasks.count, 3)
        await fixture.fail(["operations.tasks", "runtime.status"]); await model.refresh()
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertTrue(model.components.contains { $0.id == "tasks" && !$0.available })
        XCTAssertTrue(model.components.contains { $0.id == "runtime.status" && !$0.available })
    }
    func testDiagnosticAllowlistExcludesIdentifiersServerStringsAndErrors() async {
        let fixture = OperationsFixture(); let model = model(fixture); await model.refresh()
        let taskID = model.tasks[0].id.uuidString
        XCTAssertFalse(model.report().contains(taskID))
        XCTAssertFalse(model.report().contains("SECRET_TOKEN"))
        XCTAssertFalse(model.report().contains("/Users/"))
        await fixture.fail(["runtime.status"]); await model.refresh()
        XCTAssertFalse(model.report().contains("SECRET_TOKEN"))
        XCTAssertTrue(model.report().contains("Недоступно"))
    }
    func testFailedPauseNeverAttemptsCancellation() async {
        let fixture = OperationsFixture(); let model = model(fixture); await model.refresh()
        await fixture.fail(["automation.configure"]); await model.pauseAndCancelVisible()
        let history = await fixture.history()
        XCTAssertFalse(history.contains("task.cancel"))
        XCTAssertEqual(model.actionMessage?.key, .pauseUnconfirmed)
    }
    func testPausePrecedesCancellationAndPreservesPartialFailure() async {
        let fixture = OperationsFixture(); let model = model(fixture); await model.refresh()
        await fixture.fail(["task.cancel"]); await model.pauseAndCancelVisible()
        let history = await fixture.history()
        XCTAssertEqual(history.filter { $0 == "task.cancel" }.count, 1)
        XCTAssertLessThan(history.firstIndex(of: "automation.configure")!, history.firstIndex(of: "task.cancel")!)
        XCTAssertTrue(model.actionMessage?.localized(using: AgentLocalization(language: .russian)).contains("Ошибок отмены: 1") == true)
        XCTAssertTrue(model.actionMessage?.localized(using: AgentLocalization(language: .russian)).contains("ручные запросы") == true)
    }
    func testEmergencyControlUsesWholeQueueEndpointAndRequiresExplicitResume() async {
        let fixture = OperationsFixture(); let model = model(fixture)
        await model.refresh(); await model.setEmergencyStop(true)
        XCTAssertEqual(model.emergency?.stopped, true)
        let calls = await fixture.history()
        XCTAssertTrue(calls.contains("operations.emergency_stop")); XCTAssertFalse(calls.contains("task.cancel"))
        await model.setEmergencyStop(false); XCTAssertEqual(model.emergency?.stopped, false)
    }
    func testFailedEmergencyStopDoesNotClaimSuccess() async {
        let fixture = OperationsFixture(); let model = model(fixture); await model.refresh()
        await fixture.fail(["operations.emergency_stop"]); await model.setEmergencyStop(true)
        XCTAssertEqual(model.emergency?.stopped, false)
        XCTAssertTrue(model.actionMessage?.localized(using: AgentLocalization(language: .russian)).contains("не подтверждено") == true)
    }
    func testTerminalTasksCannotBeCancelled() async {
        let fixture = OperationsFixture(); let model = model(fixture); await model.refresh()
        await model.cancel(model.tasks[1])
        let history = await fixture.history(); XCTAssertFalse(history.contains("task.cancel"))
    }
    func testDuplicateTaskIDsMakeQueueUnavailable() async {
        let fixture = OperationsFixture(); await fixture.duplicateTasks()
        let model = model(fixture); await model.refresh()
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertTrue(model.components.contains { $0.id == "tasks" && !$0.available })
    }
    func testEveryTaskStateHasDistinctRussianPresentation() {
        let titles = TaskStatus.allCases.map { LocalOperationsSection.statusTitle($0) }
        XCTAssertEqual(Set(titles).count, TaskStatus.allCases.count)
        XCTAssertTrue(titles.allSatisfy { !$0.isEmpty && $0.range(of: "[А-Яа-я]", options: .regularExpression) != nil })
    }
    func testOperationsRenderAtNarrowWidthInBothThemes() async throws {
        let fixture = OperationsFixture(); let model = model(fixture); await model.refresh()
        for language in AgentLanguage.allCases {
            for theme in [ColorScheme.light, .dark] {
                for width: CGFloat in [440, 720] {
                    let host = NSHostingView(rootView: Form { LocalOperationsSection(model: model) }
                        .formStyle(.grouped).environment(\.colorScheme, theme).environment(\.agentLanguage, language)
                        .frame(width: width, height: 620))
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 620)
                    let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                    window.contentView = host
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(150))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    XCTAssertEqual(bitmap.pixelsWide, Int(width * window.backingScaleFactor))
                    if let output = ProcessInfo.processInfo.environment["ECOSYSTEM_UI_SNAPSHOTS_DIR"] {
                        let folder = URL(fileURLWithPath: output)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: folder.appendingPathComponent("E12-operations-\(language.rawValue)-\(theme == .light ? "light" : "dark")-\(Int(width)).png"))
                    }
                }
            }
        }
    }
}
