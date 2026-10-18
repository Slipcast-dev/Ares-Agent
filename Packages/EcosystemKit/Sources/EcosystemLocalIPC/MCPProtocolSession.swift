import Foundation
import CoreFoundation

/// Прогресс относится только к ожидающему MCP-запросу; отмена ожидания не отменяет
/// сохранённую задачу агента. Операции с долговечными заданиями выполняет адаптер.
public struct MCPCallContext: Sendable {
    public let progress: @Sendable (Double, Double?, String?) async -> Void
    public init(progress: @escaping @Sendable (Double, Double?, String?) async -> Void) {
        self.progress = progress
    }
}

/// Изолирует состояние одного stdio-сеанса. Длительная операция запускается в
/// отдельной Task, поэтому ping, отмена и другие запросы не ждут её завершения.
public actor MCPProtocolSession {
    public typealias Handler = @Sendable (String, Data, MCPCallContext) async throws -> Data
    private enum ID: Hashable, Sendable {
        case text(String), number(Int64)
        var json: Any { switch self { case .text(let value): return value; case .number(let value): return value } }
    }
    private struct Call {
        let generation: UUID
        let task: Task<Void, Never>
        let timer: Task<Void, Never>
        var cancelled = false
        var lastProgress: Double = -1
        var lastEmission: TimeInterval = -.infinity
    }
    private let name: String
    private let version: String
    private let tools: Data
    private let experimental: Data
    private let handler: Handler
    private let output: @Sendable (Data) -> Void
    private let timeout: TimeInterval
    private var negotiated: String?
    private var initialized = false
    private var closed = false
    private var seen = Set<ID>()
    private var calls: [ID: Call] = [:]
    private var drains: [CheckedContinuation<Void, Never>] = []
    private static let supported = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    public init(serverName: String, serverVersion: String, tools: Data, experimental: Data,
                requestTimeout: TimeInterval = 310,
                handler: @escaping Handler, output: @escaping @Sendable (Data) -> Void) {
        name = serverName; version = serverVersion; self.tools = tools
        self.experimental = experimental; self.handler = handler; self.output = output
        timeout = requestTimeout.isFinite ? min(310, max(0.01, requestTimeout)) : 310
    }

    /// Возвращается после принятия запроса, а не после выполнения tools/call.
    public func receive(_ data: Data) async {
        guard !closed else { return }
        let parsed: Any
        do { parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { self.error(nil, -32700, "Parse error"); return }
        guard let envelope = parsed as? [String: Any] else { error(nil, -32600, "Invalid Request"); return }
        let hasID = envelope.keys.contains("id")
        let id = Self.id(envelope["id"])
        // Уведомления никогда не получают ответ, даже при неверном формате.
        guard envelope["jsonrpc"] as? String == "2.0", let method = envelope["method"] as? String,
              !method.isEmpty, Set(envelope.keys).isSubset(of: ["jsonrpc", "id", "method", "params"]),
              (!hasID || id != nil) else {
            if hasID { error(nil, -32600, "Invalid Request") }; return
        }
        guard envelope["params"] == nil || envelope["params"] is [String: Any] else {
            if hasID { error(id, -32602, "Invalid params") }; return
        }
        let params = envelope["params"] as? [String: Any] ?? [:]
        guard let id else {
            if method == "notifications/initialized", negotiated != nil, params.isEmpty { initialized = true }
            if method == "notifications/cancelled", let target = Self.id(params["requestId"]), var call = calls[target] {
                call.cancelled = true; call.task.cancel(); calls[target] = call
            }
            return
        }
        guard seen.count < 4096 else { error(id, -32000, "Session request limit reached"); return }
        guard seen.insert(id).inserted else { error(id, -32600, "Duplicate request id"); return }
        if method == "ping" {
            guard params.isEmpty else { error(id, -32602, "Invalid params"); return }
            result(id, [:]); return
        }
        if method == "initialize" {
            guard negotiated == nil else { error(id, -32600, "Already initialized"); return }
            guard Set(params.keys).isSubset(of: ["protocolVersion", "clientInfo", "capabilities", "_meta"]),
                  let requested = params["protocolVersion"] as? String, !requested.isEmpty,
                  let info = params["clientInfo"] as? [String: Any],
                  let clientName = info["name"] as? String, !clientName.isEmpty,
                  let clientVersion = info["version"] as? String, !clientVersion.isEmpty,
                  params["capabilities"] is [String: Any], Self.validMeta(params["_meta"]) else {
                error(id, -32602, "Invalid initialize params"); return
            }
            let selected = Self.supported.contains(requested) ? requested : Self.supported.last!
            negotiated = selected
            var capabilities: [String: Any] = ["tools": ["listChanged": false]]
            if let value = try? JSONSerialization.jsonObject(with: experimental), value is [String: Any] {
                capabilities["experimental"] = value
            }
            result(id, ["protocolVersion": selected, "capabilities": capabilities,
                        "serverInfo": ["name": name, "version": version]])
            return
        }
        guard negotiated != nil, initialized else { error(id, -32000, "Session is not initialized"); return }
        if method == "tools/list" {
            guard Set(params.keys).isSubset(of: ["_meta"]), Self.validMeta(params["_meta"]) else {
                error(id, -32602, "Invalid params"); return
            }
            var definitions = (try? JSONSerialization.jsonObject(with: tools)) as? [[String: Any]] ?? []
            if !supportsStructured { definitions = definitions.map { var copy = $0; copy.removeValue(forKey: "outputSchema"); return copy } }
            result(id, ["tools": definitions]); return
        }
        guard method == "tools/call" else { error(id, -32601, "Method not found"); return }
        guard Set(params.keys).isSubset(of: ["name", "arguments", "_meta"]),
              let tool = params["name"] as? String, !tool.isEmpty,
              params["arguments"] == nil || params["arguments"] is [String: Any],
              Self.validMeta(params["_meta"]) else { error(id, -32602, "Invalid tool params"); return }
        let definitions = (try? JSONSerialization.jsonObject(with: tools)) as? [[String: Any]] ?? []
        guard definitions.contains(where: { $0["name"] as? String == tool }) else {
            error(id, -32602, "Unknown tool"); return
        }
        guard calls.count < 8 else { error(id, -32000, "Too many concurrent calls"); return }
        let arguments = (try? JSONSerialization.data(withJSONObject: params["arguments"] ?? [:], options: [.sortedKeys])) ?? Data("{}".utf8)
        // Полная рекурсивная схема проверяется до admission/выполнения: неверный
        // вложенный аргумент не должен создать задачу либо изменить состояние.
        do {
            guard let schema = definitions.first(where: { $0["name"] as? String == tool })?["inputSchema"] else {
                error(id, -32603, "Tool schema unavailable"); return
            }
            try MCPInputSchemaValidator.validate(arguments: arguments,
                schema: JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]))
        } catch { self.error(id, -32602, "Invalid tool arguments"); return }
        let token = Self.id((params["_meta"] as? [String: Any])?["progressToken"])
        let generation = UUID(), handler = self.handler
        let context = MCPCallContext { [weak self] progress, total, message in
            await self?.progress(id, generation, token, progress, total, message)
        }
        let task = Task { [weak self] in
            do {
                let value = try await handler(tool, arguments, context)
                await self?.completed(id, generation, value, failed: false)
            } catch {
                // Текст исключения может содержать локальные пути или содержимое;
                // наружу уходит нейтральная ошибка, а не произвольный error.description.
                await self?.completed(id, generation, Data(), failed: true)
            }
        }
        let seconds = timeout
        let timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            await self?.expired(id, generation)
        }
        calls[id] = Call(generation: generation, task: task, timer: timer)
    }

    /// EOF перестаёт принимать ввод, но даёт принятым запросам ограниченное время.
    public func finish() async {
        closed = true
        guard !calls.isEmpty else { return }
        await withCheckedContinuation { drains.append($0) }
    }

    /// Закрытие транспортного ожидания не выполняет task.cancel у durable queue.
    public func close() {
        closed = true
        for call in calls.values { call.task.cancel(); call.timer.cancel() }
        calls.removeAll(); drained()
    }

    private var supportsStructured: Bool { (negotiated ?? "") >= "2025-06-18" }
    private static func id(_ value: Any?) -> ID? {
        if let value = value as? String {
            // seen удерживает id до конца сеанса: предел строки ограничивает
            // память таблицы 4096 запросов даже при враждебных входных кадрах.
            guard value.utf8.count <= 512 else { return nil }
            return .text(value)
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // Целочисленный NSNumber сохраняет полный Int64 без округления через Double.
        if let exact = Int64(number.stringValue) { return .number(exact) }
        guard number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= -9_007_199_254_740_991, number.doubleValue <= 9_007_199_254_740_991 else { return nil }
        return .number(number.int64Value)
    }
    private static func validMeta(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let object = value as? [String: Any] else { return false }
        return object["progressToken"] == nil || id(object["progressToken"]) != nil
    }
    private func progress(_ id: ID, _ generation: UUID, _ token: ID?, _ value: Double, _ total: Double?, _ message: String?) {
        guard let token, var call = calls[id], call.generation == generation, !call.cancelled,
              value.isFinite, value >= 0, value >= call.lastProgress,
              total == nil || (total!.isFinite && total! >= value) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - call.lastEmission >= 0.25 else { return }
        call.lastEmission = now; call.lastProgress = value; calls[id] = call
        var params: [String: Any] = ["progressToken": token.json, "progress": value]
        if let total { params["total"] = total }
        if let message { params["message"] = String(message.prefix(256)) }
        emit(["jsonrpc": "2.0", "method": "notifications/progress", "params": params], fallbackID: nil)
    }
    private func completed(_ id: ID, _ generation: UUID, _ data: Data, failed: Bool) {
        guard let call = calls[id], call.generation == generation else { return }
        calls.removeValue(forKey: id); call.timer.cancel()
        defer { drained() }
        guard !call.cancelled else { return }
        guard !failed, var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["content"] is [Any], object["isError"] == nil || object["isError"] is Bool else {
            error(id, -32603, "Tool execution failed"); return
        }
        if !supportsStructured { object.removeValue(forKey: "structuredContent") }
        result(id, object)
    }
    private func expired(_ id: ID, _ generation: UUID) {
        guard let call = calls[id], call.generation == generation else { return }
        calls.removeValue(forKey: id); call.task.cancel()
        if !call.cancelled { error(id, -32000, "Request timeout") }
        drained()
    }
    private func drained() {
        guard calls.isEmpty else { return }
        let pending = drains; drains.removeAll(); for continuation in pending { continuation.resume() }
    }
    private func result(_ id: ID, _ result: [String: Any]) {
        emit(["jsonrpc": "2.0", "id": id.json, "result": result], fallbackID: id)
    }
    private func error(_ id: ID?, _ code: Int, _ message: String) {
        emit(["jsonrpc": "2.0", "id": id?.json ?? NSNull(), "error": ["code": code, "message": message]], fallbackID: id)
    }
    private func emit(_ envelope: [String: Any], fallbackID: ID?) {
        if let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]), data.count <= 1_048_576 {
            output(data); return
        }
        let fallback: [String: Any] = ["jsonrpc": "2.0", "id": fallbackID?.json ?? NSNull(),
                                      "error": ["code": -32603, "message": "MCP_RESPONSE_LIMIT"]]
        if let data = try? JSONSerialization.data(withJSONObject: fallback, options: [.sortedKeys]) { output(data) }
    }
}
