import Foundation
import EcosystemLocalization
import SwiftUI
import EcosystemContracts
import EcosystemRuntimeSupport
import EcosystemLocalIPC

/// Снимок никогда не считает недоступный компонент пустым или исправным.
/// При каждом обновлении старые значения очищаются до чтения новых данных.
@MainActor final class LocalOperationsModel: ObservableObject {
    typealias Transport = @Sendable (String, Data) async throws -> Data
    private struct Reply: Decodable { let version: Int; let domain: String; let result: Data?; let error: LocalRuntimeFailure? }
    struct Runtime: Codable, Sendable { let domain: String; let healthy: Bool }
    struct Component: Identifiable, Sendable {
        let id: String
        let title: SharedText
        let value: SharedMessage
        let available: Bool
        let needsAttention: Bool
        init(id: String, title: SharedText, value: SharedMessage, available: Bool, needsAttention: Bool = false) {
            self.id = id; self.title = title; self.value = value; self.available = available; self.needsAttention = needsAttention
        }
    }
    @Published private(set) var components: [Component] = []
    @Published private(set) var tasks: [LocalOperationalTask] = []
    @Published private(set) var emergency: QueueEmergencyStatus?
    @Published private(set) var busy = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var actionMessage: SharedMessage?
    private let transport: Transport
    let domain: String

    init(domain: String, transport: @escaping Transport) {
        self.domain = domain; self.transport = transport
    }
    convenience init(client: Result<LocalRPCClient, Error>) {
        self.init(domain: (try? client.get().configuration.domain) ?? "unknown") { operation, payload in
            let rpc = try client.get()
            let request = LocalRPCRequest(domain: rpc.configuration.domain, operation: operation, payload: payload)
            let bytes = try await rpc.exchange(LocalWire.encode(request))
            let reply = try LocalWire.decode(Reply.self, bytes, keys: ["version", "domain", "result", "error"])
            guard reply.version == 1, reply.domain == rpc.configuration.domain else { throw LocalRuntimeFailure.invalidRequest }
            if let error = reply.error { throw error }
            guard let result = reply.result else { throw LocalRuntimeFailure.invalidRequest }
            return result
        }
    }
    private func call<T: Decodable>(_ operation: String, _ type: T.Type, payload: Data = Data("{}".utf8)) async throws -> T {
        try LocalWire.decode(type, await transport(operation, payload))
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        actionMessage = nil
        await readSnapshot()
    }
    private func readSnapshot() async {
        components = []; tasks = []; emergency = nil; refreshedAt = nil
        // Каждая ошибка изолирована: отказ login item не скрывает очередь или
        // grants. Сообщения/пути из исключений и сервера не экспортируются.
        await read("runtime.status", .service, Runtime.self, attention: { !$0.healthy }) { runtime in
            guard runtime.domain == self.domain else { throw LocalRuntimeFailure.invalidRequest }
            return runtime.healthy ? SharedMessage(.available) : SharedMessage(.needsAttention)
        }
        do {
            let state = try await call("operations.emergency_status", QueueEmergencyStatus.self)
            emergency = state
            components.append(.init(id: "emergency", title: .emergencyStop, value: state.stopped ? SharedMessage(.admissionClosed, .count(state.pendingTasks), .count(state.activeCallbacks), .count(state.recoveryTasks)) : SharedMessage(.admissionOpen), available: true))
        } catch { unavailable("emergency", .emergencyStop) }
        await read("automation.status", .backgroundActivity, LocalAutomationStatus.self) {
            $0.settings.paused ? SharedMessage(.paused) : SharedMessage(.backgroundOn)
        }
        await read("automation.login_status", .loginComponent, LocalLoginStatus.self) {
            $0.disabledBySystem ? SharedMessage(.blockedByMacOS) : ($0.configured ? SharedMessage(.enabled) : SharedMessage(.disabled))
        }
        await read("access.status", .clientPermissions, LocalAccessState.self) {
            SharedMessage(.grantCounts, .count($0.grants.count), .count($0.pending.count))
        }
        do {
            tasks = try await call("operations.tasks", [LocalOperationalTask].self)
            guard tasks.count <= 100, Set(tasks.map(\.id)).count == tasks.count else { throw LocalRuntimeFailure.invalidRequest }
            components.append(.init(id: "tasks", title: .tasks, value: SharedMessage(.taskCounts, .count(tasks.filter { !$0.status.isTerminal }.count), .count(tasks.filter { $0.status == .recoveryRequired }.count)), available: true))
        } catch { tasks = []; unavailable("tasks", .tasks) }
        do {
            var request = LocalAutomationRequest(); request.limit = 50
            let events = try await call("events.list", [LocalInboxDelivery].self, payload: LocalWire.encode(request))
            components.append(.init(id: "events", title: .inboxEvents, value: SharedMessage(.eventSample, .count(events.count)), available: true))
        } catch { unavailable("events", .inboxEvents) }
        refreshedAt = Date()
    }
    private func read<T: Decodable>(_ operation: String, _ title: SharedText, _ type: T.Type,
                                   attention: (T) -> Bool = { _ in false }, value: (T) throws -> SharedMessage) async {
        do {
            let result = try await call(operation, type)
            components.append(.init(id: operation, title: title, value: try value(result), available: true, needsAttention: attention(result)))
        }
        catch { unavailable(operation, title) }
    }
    private func unavailable(_ id: String, _ title: SharedText) {
        components.append(.init(id: id, title: title, value: SharedMessage(.unavailableRefresh), available: false))
    }
    func cancel(_ task: LocalOperationalTask) async {
        guard !busy, !task.status.isTerminal else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await call("task.cancel", LocalEmpty.self, payload: LocalWire.encode(LocalTaskID(task.id)))
            await readSnapshot()
            actionMessage = SharedMessage(.cancellationSent)
        } catch { actionMessage = SharedMessage(.cancellationFailed) }
    }
    func setEmergencyStop(_ stopped: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let state = try await call(stopped ? "operations.emergency_stop" : "operations.emergency_resume", QueueEmergencyStatus.self)
            guard state.stopped == stopped else { throw LocalRuntimeFailure.invalidRequest }
            await readSnapshot()
            actionMessage = stopped
                ? SharedMessage(.stopSent)
                : SharedMessage(.resumeSent)
        } catch {
            await readSnapshot()
            actionMessage = SharedMessage(.actionUnconfirmed)
        }
    }
    func pauseAndCancelVisible() async {
        guard !busy, refreshedAt != nil else { return }
        busy = true; defer { busy = false }
        var request = LocalAutomationRequest(); request.paused = true
        do {
            let _: LocalAutomationStatus = try await call("automation.configure", LocalAutomationStatus.self, payload: LocalWire.encode(request))
        } catch {
            // Без подтверждённой паузы отмена не начинается: пользователь не
            // должен получить ложное обещание остановленного планировщика.
            await readSnapshot()
            actionMessage = SharedMessage(.pauseUnconfirmed)
            return
        }
        var failures = 0
        for task in tasks where !task.status.isTerminal {
            do { _ = try await call("task.cancel", LocalEmpty.self, payload: LocalWire.encode(LocalTaskID(task.id))) }
            catch { failures += 1 }
        }
        await readSnapshot()
        actionMessage = SharedMessage(.pauseResult, .count(failures))
    }
    func report(language: AgentLanguage = .russian) -> String {
        // Allowlist сохраняется: не экспортируем идентификаторы, raw ошибки,
        // пути/имена/конфигурации или параметры событий ради локализации.
        let l10n = AgentLocalization(language: language)
        let safeDomain = ["ares", "athena"].contains(domain) ? domain : "unknown"
        let timestamp = refreshedAt?.formatted(.iso8601) ?? l10n.text(.notRefreshed)
        return (["Ecosystem diagnostics v1", l10n.message(.reportAgent, .text(safeDomain)),
                 l10n.message(.reportSnapshot, .text(timestamp)), l10n.text(.reportScope)] +
                components.map { l10n.text($0.title) + ": " + $0.value.localized(using: l10n) } +
                [l10n.text(.reportSamples), l10n.text(.reportPrivacy)])
            .joined(separator: "\n") + "\n"
    }
}
