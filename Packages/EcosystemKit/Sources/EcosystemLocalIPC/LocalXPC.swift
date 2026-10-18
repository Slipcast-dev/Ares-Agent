import Darwin
import Foundation

@objc public protocol LocalRuntimeXPC {
    func exchange(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

/// Reply/error/timeout/cancellation соревнуются; continuation завершается один раз.
private final class ReplyLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    func install(_ value: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    func finish(_ value: Result<Data, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: value)
    }
}

/// Каждое короткое обращение создаёт проверенное соединение. После ошибки
/// запрос не повторяется автоматически: для мутаций клиент сохраняет ключ.
public struct LocalRPCClient: Sendable {
    public let configuration: LocalRuntimeConfiguration
    public let role: LocalRole
    public init(configuration: LocalRuntimeConfiguration, role: LocalRole) {
        self.configuration = configuration; self.role = role
    }
    public func call<P: Encodable, T: Decodable & Sendable>(_ operation: String, _ payload: P, as type: T.Type = T.self) async throws -> T {
        let request = LocalRPCRequest(domain: configuration.domain, operation: operation, payload: try LocalWire.encode(payload))
        let data = try await exchange(try LocalWire.encode(request))
        let reply = try LocalWire.decode(LocalRPCReply.self, data, keys: ["version", "domain", "result", "error"])
        guard reply.version == 1, reply.domain == configuration.domain else { throw LocalRuntimeFailure.invalidRequest }
        if let error = reply.error { throw error }
        guard let result = reply.result else { throw LocalRuntimeFailure.invalidRequest }
        return try LocalWire.decode(type, result)
    }
    public func exchange(_ data: Data) async throws -> Data {
        guard data.count <= LocalWire.maximumRequestBytes,
              let endpoint = configuration.endpoints[role == .mcp && configuration.selectedMCPClient != nil && configuration.selectedMCPClient != .legacy ? "mcp." + configuration.selectedMCPClient!.rawValue : role.rawValue] else { throw LocalRuntimeFailure.invalidRequest }
        let connection = NSXPCConnection(machServiceName: endpoint.service, options: [])
        connection.setCodeSigningRequirement(configuration.serverRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: LocalRuntimeXPC.self)
        let latch = ReplyLatch()
        connection.invalidationHandler = { latch.finish(.failure(LocalRuntimeFailure.unavailable)) }
        connection.resume()
        defer { connection.invalidate() }
        let timer = DispatchWorkItem { latch.finish(.failure(LocalRuntimeFailure.unavailable)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
        defer { timer.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                latch.install(continuation)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    latch.finish(.failure(LocalRuntimeFailure.unavailable))
                }) as? LocalRuntimeXPC else { latch.finish(.failure(LocalRuntimeFailure.unavailable)); return }
                proxy.exchange(data) { result in
                    guard result.count <= LocalWire.maximumResponseBytes else {
                        latch.finish(.failure(LocalRuntimeFailure.invalidRequest)); return
                    }
                    latch.finish(.success(result))
                }
            }
        }, onCancel: { latch.finish(.failure(CancellationError())) })
    }
}

private final class LocalBridge: NSObject, LocalRuntimeXPC {
    let domain: String
    let role: LocalRole
    let clientID: LocalMCPClient?
    let handler: @Sendable (LocalRole, LocalMCPClient?, LocalRPCRequest) async throws -> Data
    init(domain: String, role: LocalRole, clientID: LocalMCPClient?, handler: @escaping @Sendable (LocalRole, LocalMCPClient?, LocalRPCRequest) async throws -> Data) {
        self.domain = domain; self.role = role; self.clientID = clientID; self.handler = handler
    }
    func exchange(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        Task {
            let response: LocalRPCReply
            do {
                guard data.count <= LocalWire.maximumRequestBytes else { throw LocalRuntimeFailure.invalidRequest }
                let request = try LocalWire.decode(LocalRPCRequest.self, data, keys: ["version", "domain", "operation", "payload"])
                guard request.version == 1, request.domain == domain else { throw LocalRuntimeFailure.denied }
                let result = try await handler(role, clientID, request)
                response = LocalRPCReply(version: 1, domain: domain, result: result, error: nil)
            } catch {
                response = LocalRPCReply(version: 1, domain: domain, result: nil, error: .safe(error))
            }
            // Не отдаём описание NSError: оно может содержать локальный путь.
            if let encoded = try? LocalWire.encode(response), role != .mcp || encoded.count <= LocalWire.maximumRequestBytes { reply(encoded) }
            else if let encoded = try? LocalWire.encode(LocalRPCReply(version: 1, domain: domain, result: nil, error: .operationFailed)) { reply(encoded) }
        }
    }
}
private final class LocalListenerDelegate: NSObject, NSXPCListenerDelegate {
    let bridge: LocalBridge
    init(bridge: LocalBridge) { self.bridge = bridge }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.exportedInterface = NSXPCInterface(with: LocalRuntimeXPC.self)
        connection.exportedObject = bridge; connection.resume(); return true
    }
}
/// Три listener одного доменного процесса дают разным подписанным клиентам
/// разные разрешения. GUI не может назвать себя worker/MCP полем запроса.
public final class LocalRPCServer {
    private var started = false
    private var listeners: [NSXPCListener] = []
    private var delegates: [LocalListenerDelegate] = []
    public convenience init(configuration: LocalRuntimeConfiguration,
                handler: @escaping @Sendable (LocalRole, LocalRPCRequest) async throws -> Data) throws {
        try self.init(configuration: configuration, identifiedHandler: { role, _, request in try await handler(role, request) })
    }
    public init(configuration: LocalRuntimeConfiguration,
                identifiedHandler handler: @escaping @Sendable (LocalRole, LocalMCPClient?, LocalRPCRequest) async throws -> Data) throws {
        for (key, endpoint) in configuration.endpoints {
            guard let role: LocalRole = key.hasPrefix("mcp.") ? .mcp : LocalRole(rawValue: key) else { throw LocalRuntimeFailure.invalidConfiguration }
            let clientID: LocalMCPClient? = role == .mcp ? (key == "mcp" ? .legacy : LocalMCPClient(rawValue: String(key.dropFirst(4)))) : nil
            let listener = NSXPCListener(machServiceName: endpoint.service)
            listener.setConnectionCodeSigningRequirement(endpoint.clientRequirement)
            let delegate = LocalListenerDelegate(bridge: LocalBridge(domain: configuration.domain, role: role, clientID: clientID, handler: handler))
            listener.delegate = delegate; listeners.append(listener); delegates.append(delegate)
        }
    }
    public func resume() { guard !started else { return }; started = true; listeners.forEach { $0.resume() } }
    deinit { if started { listeners.forEach { $0.suspend() } } }
}
