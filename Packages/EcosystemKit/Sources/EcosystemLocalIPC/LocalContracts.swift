import Darwin
import Foundation
import EcosystemContracts
import Security
import EcosystemRuntimeSupport

/// Роль задаётся отдельным Mach listener и проверкой подписи, а не JSON-заявлением.
public enum LocalRole: String, Codable, CaseIterable, Sendable { case gui, mcp, worker }
public enum LocalRuntimeFailure: String, Error, Codable, LocalizedError, QueueDomainError, Sendable {
    case invalidConfiguration, invalidRequest, denied, unavailable, busy, conflict
    case cancelled, deadlineExceeded, recoveryRequired, operationFailed, staleSnapshot, requiresGUI
    public var knownCode: KnownErrorCode {
        switch self {
        case .denied: .permissionDenied
        case .invalidRequest, .invalidConfiguration: .invalidArgument
        case .staleSnapshot: .staleSnapshot
        case .requiresGUI: .clientUnavailable
        case .cancelled: .cancelled
        case .deadlineExceeded: .deadlineExceeded
        default: .internalError
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Локальный режим настроен некорректно."
        case .invalidRequest: "Некорректные параметры операции."
        case .denied: "Операция не разрешена этому клиенту."
        case .unavailable: "Локальный агент недоступен. Запустите свой локальный профиль."
        case .busy: "Ресурс уже занят задачей агента."
        case .conflict: "Ключ запроса уже использован с другими параметрами."
        case .cancelled: "Операция отменена."
        case .deadlineExceeded: "Время выполнения истекло."
        case .recoveryRequired: "Необходима проверка результата предыдущей операции."
        case .requiresGUI: "Это действие требует локального интерфейса и не выполнено фоновым агентом."
        case .staleSnapshot: "Файлы изменились. Обновите список файлов и повторите запрос."
        case .operationFailed: "Агент не смог завершить операцию."
        }
    }
    public static func safe(_ error: Error) -> Self {
        if let local = error as? Self { return local }
        if let domain = error as? QueueDomainError {
            switch domain.knownCode {
            case .permissionDenied: return .denied
            case .staleSnapshot: return .staleSnapshot
            case .invalidArgument: return .invalidRequest
            case .clientUnavailable: return .requiresGUI
            default: break
            }
        }
        switch error as? QueueFailure {
        case .resourceBusy, .ownerBusy, .capacityReached, .emergencyStopped: return .busy
        case .idempotencyConflict: return .conflict
        case .cancelled: return .cancelled
        case .deadlineExceeded: return .deadlineExceeded
        case .recoveryRequired: return .recoveryRequired
        default: return error is CancellationError ? .cancelled : .operationFailed
        }
    }
}

/// Идентичность назначает проверенный listener. Имя клиента в JSON не является
/// полномочием; legacy endpoint остаётся отдельным, по умолчанию без доступа.
public enum LocalMCPClient: String, Codable, CaseIterable, Sendable { case codex, deepseekHarness, legacy }

public struct LocalEndpoint: Codable, Sendable {
    public let service: String
    public let clientRequirement: String
}
/// Профиль создаёт только локальный launcher. Неизвестные поля и wildcard
/// requirements отклоняются; при ошибке нельзя откатываться к прямой записи БД.
public struct LocalRuntimeConfiguration: Codable, Sendable {
    public let version: Int
    public let mode: String
    public let domain: String
    public let serverRequirement: String
    public let endpoints: [String: LocalEndpoint]
    public var selectedMCPClient: LocalMCPClient? = nil
    public static func load(_ file: URL, domain: String) throws -> Self {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw LocalRuntimeFailure.invalidConfiguration
        }
        guard info.st_size > 0, info.st_size <= 1_048_576 else { throw LocalRuntimeFailure.invalidConfiguration }
        let data = try Data(contentsOf: file)
        let value = try LocalWire.decode(Self.self, data, keys: ["version", "mode", "domain", "serverRequirement", "endpoints", "selectedMCPClient"])
        guard value.version == 1, value.mode == "local-ad-hoc", value.domain == domain,
              ["ares", "athena"].contains(domain), Set(LocalRole.allCases.map(\.rawValue)).isSubset(of: Set(value.endpoints.keys)), Set(value.endpoints.keys).isSubset(of: ["gui", "mcp", "worker", "mcp.codex", "mcp.deepseekHarness"]) else {
            throw LocalRuntimeFailure.invalidConfiguration
        }
        if let client = value.selectedMCPClient, client != .legacy, value.endpoints["mcp." + client.rawValue] == nil { throw LocalRuntimeFailure.invalidConfiguration }
        func pinned(_ text: String) -> Bool {
            // Точный CDHash либо OR нескольких точных CDHash; identifier-only не принимается.
            let pattern = #"^cdhash H\"[0-9a-fA-F]{40}\"( or cdhash H\"[0-9a-fA-F]{40}\")*$"#
            var requirement: SecRequirement?
            return text.range(of: pattern, options: .regularExpression) != nil &&
                SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
        }
        guard pinned(value.serverRequirement) else { throw LocalRuntimeFailure.invalidConfiguration }
        for (key, endpoint) in value.endpoints {
            guard pinned(endpoint.clientRequirement),
                  endpoint.service.hasPrefix("local.ecosystem." + domain + "."),
                  endpoint.service.hasSuffix("." + key),
                  endpoint.service.count < 200,
                  endpoint.service.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else {
                throw LocalRuntimeFailure.invalidConfiguration
            }
        }
        return value
    }
    public static func environment(domain: String) throws -> (Self, URL)? {
        guard let path = ProcessInfo.processInfo.environment[domain.uppercased() + "_LOCAL_RUNTIME_CONFIG"] else { return nil }
        guard path.hasPrefix("/") else { throw LocalRuntimeFailure.invalidConfiguration }
        let file = URL(fileURLWithPath: path)
        return (try load(file, domain: domain), file)
    }
}

public struct LocalRPCRequest: Codable, Sendable {
    public let version: Int
    public let domain: String
    public let operation: String
    public let payload: Data
    public init(domain: String, operation: String, payload: Data) {
        version = 1; self.domain = domain; self.operation = operation; self.payload = payload
    }
}
struct LocalRPCReply: Codable {
    let version: Int
    let domain: String
    let result: Data?
    let error: LocalRuntimeFailure?
}
public struct LocalEmpty: Codable, Sendable { public init() {} }
public struct LocalTaskID: Codable, Sendable {
    public let id: UUID
    public init(_ id: UUID) { self.id = id }
}
public enum LocalWire {
    public static let maximumRequestBytes = 1_048_576
    public static let maximumResponseBytes = 16 * 1_048_576
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumResponseBytes else { throw LocalRuntimeFailure.invalidRequest }
        return data
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data, keys: Set<String>? = nil) throws -> T {
        guard data.count <= maximumResponseBytes else { throw LocalRuntimeFailure.invalidRequest }
        if let keys {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys).isSubset(of: keys) else {
                throw LocalRuntimeFailure.invalidRequest
            }
        }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw LocalRuntimeFailure.invalidRequest }
    }
}
