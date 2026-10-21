import Foundation
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
        let title: String
        let value: String
        let available: Bool
    }
    @Published private(set) var components: [Component] = []
    @Published private(set) var tasks: [LocalOperationalTask] = []
    @Published private(set) var emergency: QueueEmergencyStatus?
    @Published private(set) var busy = false
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var actionMessage: String?
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
        await read("runtime.status", "Служба", Runtime.self) { runtime in
            guard runtime.domain == self.domain else { throw LocalRuntimeFailure.invalidRequest }
            return runtime.healthy ? "Доступна" : "Требует внимания"
        }
        do {
            let state = try await call("operations.emergency_status", QueueEmergencyStatus.self)
            emergency = state
            components.append(.init(id: "emergency", title: "Аварийная остановка", value: state.stopped ? "Приём закрыт; незавершённых: \(state.pendingTasks); callbacks: \(state.activeCallbacks); требуют сверки: \(state.recoveryTasks)" : "Приём задач открыт", available: true))
        } catch { unavailable("emergency", "Аварийная остановка") }
        await read("automation.status", "Фоновая работа", LocalAutomationStatus.self) {
            $0.settings.paused ? "Приостановлена" : "Включена"
        }
        await read("automation.login_status", "Запуск после входа", LocalLoginStatus.self) {
            $0.disabledBySystem ? "Запрещён macOS" : ($0.configured ? "Включён" : "Выключен")
        }
        await read("access.status", "Разрешения клиентов", LocalAccessState.self) {
            "Разрешений: \($0.grants.count); ожидают согласия: \($0.pending.count)"
        }
        do {
            tasks = try await call("operations.tasks", [LocalOperationalTask].self)
            guard tasks.count <= 100, Set(tasks.map(\.id)).count == tasks.count else { throw LocalRuntimeFailure.invalidRequest }
            components.append(.init(id: "tasks", title: "Задачи", value: "Активных: \(tasks.filter { !$0.status.isTerminal }.count); требуют сверки: \(tasks.filter { $0.status == .recoveryRequired }.count)", available: true))
        } catch { tasks = []; unavailable("tasks", "Задачи") }
        do {
            var request = LocalAutomationRequest(); request.limit = 50
            let events = try await call("events.list", [LocalInboxDelivery].self, payload: LocalWire.encode(request))
            components.append(.init(id: "events", title: "Входящие события", value: "В выборке: \(events.count) (до 50)", available: true))
        } catch { unavailable("events", "Входящие события") }
        refreshedAt = Date()
    }
    private func read<T: Decodable>(_ operation: String, _ title: String, _ type: T.Type,
                                   value: (T) throws -> String) async {
        do { components.append(.init(id: operation, title: title, value: try value(await call(operation, type)), available: true)) }
        catch { unavailable(operation, title) }
    }
    private func unavailable(_ id: String, _ title: String) {
        components.append(.init(id: id, title: title, value: "Недоступно — обновите состояние", available: false))
    }
    func cancel(_ task: LocalOperationalTask) async {
        guard !busy, !task.status.isTerminal else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await call("task.cancel", LocalEmpty.self, payload: LocalWire.encode(LocalTaskID(task.id)))
            await readSnapshot()
            actionMessage = "Запрос отмены отправлен. Проверьте итоговое состояние; уже выполненные действия не откатываются."
        } catch { actionMessage = "Не удалось запросить отмену. Обновите состояние; не повторяйте изменяющую задачу вслепую." }
    }
    func setEmergencyStop(_ stopped: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            let state = try await call(stopped ? "operations.emergency_stop" : "operations.emergency_resume", QueueEmergencyStatus.self)
            guard state.stopped == stopped else { throw LocalRuntimeFailure.invalidRequest }
            await readSnapshot()
            actionMessage = stopped
                ? "Приём новых задач закрыт до явного возобновления, включая перезапуск службы. Отмена запрошена для всей очереди. Дождитесь нуля активных callbacks и проверьте восстановление; выполненные действия не откатываются."
                : "Приём задач открыт. Отменённые задачи не повторяются; планировщики и клиенты могут отправлять новые поручения."
        } catch {
            await readSnapshot()
            actionMessage = "Действие не подтверждено. Обновите состояние; не считайте агент остановленным или возобновлённым."
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
            actionMessage = "Пауза не подтверждена. Отмена задач не выполнялась."
            return
        }
        var failures = 0
        for task in tasks where !task.status.isTerminal {
            do { _ = try await call("task.cancel", LocalEmpty.self, payload: LocalWire.encode(LocalTaskID(task.id))) }
            catch { failures += 1 }
        }
        await readSnapshot()
        actionMessage = "Фон приостановлен; запросы отмены отправлены для показанных активных задач. Ошибок отмены: \(failures). Проверьте итоговые состояния. Новые ручные запросы клиентов остаются доступны."
    }
    var report: String {
        // Allowlist вместо редактирования произвольного дампа: исходные пути,
        // имена, taskId, bookmarks, события, ключи и профили не сериализуются.
        let safeDomain = ["ares", "athena"].contains(domain) ? domain : "unknown"
        let timestamp = refreshedAt?.formatted(.iso8601) ?? "not refreshed"
        return (["Ecosystem diagnostics v1", "Agent: " + safeDomain, "Snapshot: " + timestamp,
                 "Scope: local GUI snapshot; configuration is not a verified client session."] +
                components.map { "\($0.title): \($0.value)" } +
                ["Task sample: latest 100; event sample: latest 50.",
                 "No file paths, names, identifiers, secrets, configuration or event contents included."])
            .joined(separator: "\n") + "\n"
    }
}
