import EcosystemContracts
import Foundation

/// Unknown никогда не повышается до supported из-за наличия конфигурационного файла.
public typealias IntegrationSupport = SupportLevel

public extension SupportLevel {
    var isSupported: Bool { self == .supported }
}

/// Возможности относятся к проверенному адаптером формату, а не к успешному handshake.
public struct IntegrationCapabilities: Codable, Sendable, Equatable {
    public var localMCP: IntegrationSupport = .unknown
    public var nativeDelegation: IntegrationSupport = .unknown
    public var namedRoles: IntegrationSupport = .unknown
    public var toolFiltering: IntegrationSupport = .unknown
    public var hotReload: IntegrationSupport = .unknown
    public var headlessRunner: IntegrationSupport = .unknown
    public var resumableSessions: IntegrationSupport = .unknown
    public init() {}
}

public struct IntegrationDetection: Codable, Sendable {
    public let clientId: String
    public let version: String?
    public let executablePath: String?
    public let profilePath: String?
    public let availability: IntegrationSupport
    public init(clientId: String, version: String?, executablePath: String?,
                profilePath: String?, availability: IntegrationSupport) {
        self.clientId = clientId; self.version = version; self.executablePath = executablePath
        self.profilePath = profilePath; self.availability = availability
    }
}

/// Регистрация, живой MCP и делегирование — три независимых доказательства.
public struct IntegrationRegistration: Codable, Sendable {
    public let clientId: String
    public let domain: String
    public let state: String
    public let detail: String
    public let configured: Bool
    public let handshakeVerified: Bool
    public let delegationVerified: Bool
    public init(clientId: String, domain: String, state: String, detail: String,
                configured: Bool = false, handshakeVerified: Bool = false,
                delegationVerified: Bool = false) {
        self.clientId = clientId; self.domain = domain; self.state = state; self.detail = detail
        self.configured = configured; self.handshakeVerified = handshakeVerified
        self.delegationVerified = delegationVerified
    }
}

/// Payload переносит существующий проверяемый план; реестр не интерпретирует его
/// и не заменяет fingerprint/ownership/backup конкретного адаптера.
public struct IntegrationRegistrationPlan: Sendable {
    public let clientId: String
    public let domain: String
    public let changes: [String]
    let payload: Data
    public init(clientId: String, domain: String, changes: [String], payload: Data) {
        self.clientId = clientId; self.domain = domain; self.changes = changes; self.payload = payload
    }
}

/// Нейтральный экспорт не является записью в конфигурацию конкретного клиента.
public struct IntegrationRole: Sendable {
    public let roleId: String
    public let manifest: Data
    public let instructions: String
}

public enum IntegrationAdapterError: Error, Equatable {
    case invalidIdentifier, duplicateAdapter, unknownAdapter, wrongPlan
    case programMissing, unsupportedVersion, delegationUnavailable
    case registrationUnavailable, connectionUnverified
}

/// Третья реализация добавляется только в реестр: доменные сервисы о ней не знают.
public protocol ClientIntegrationAdapter: Sendable {
    var clientId: String { get }
    var domain: String { get }
    func detect() async -> IntegrationDetection
    func inspectCapabilities() async -> IntegrationCapabilities
    func inspectRegistration() async throws -> IntegrationRegistration
    func previewRegistration(connected: Bool) async throws -> IntegrationRegistrationPlan
    func applyRegistration(_ plan: IntegrationRegistrationPlan) async throws -> IntegrationRegistration
    func removeOwnedRegistration() async throws -> IntegrationRegistration
    func validateConnection() async throws -> IntegrationRegistration
    func exportRoles() async throws -> [IntegrationRole]
    func inspectDelegationSupport() async -> IntegrationSupport
    func diagnose() async throws -> IntegrationRegistration
}

public extension ClientIntegrationAdapter {
    func removeOwnedRegistration() async throws -> IntegrationRegistration {
        try await applyRegistration(previewRegistration(connected: false))
    }
    func inspectDelegationSupport() async -> IntegrationSupport {
        await inspectCapabilities().nativeDelegation
    }
    func diagnose() async throws -> IntegrationRegistration { try await inspectRegistration() }
    func validateConnection() async throws -> IntegrationRegistration {
        // Проверка наличия записей не выдаётся за обращение живого MCP-клиента.
        let status = try await inspectRegistration()
        guard status.handshakeVerified else { throw IntegrationAdapterError.connectionUnverified }
        return status
    }
    func exportRoles() async throws -> [IntegrationRole] {
        guard ["ares", "athena", "coordinator"].contains(domain) else {
            throw IntegrationAdapterError.invalidIdentifier
        }
        return try [domain].map { role in
            let manifest = try ContractResources.data(relativePath: "Roles/\(role).json")
            let text = try ContractResources.data(relativePath: "Roles/\(role).md")
            return IntegrationRole(roleId: role, manifest: manifest, instructions: String(decoding: text, as: UTF8.self))
        }
    }
}

/// Один реестр на домен сохраняет разделение Ареса и Афины. ID не является enum
/// и проверяется тем же контрактом, что clientContext.clientId старых задач.
public actor ClientAdapterRegistry {
    public let domain: String
    private var adapters: [String: any ClientIntegrationAdapter] = [:]
    public init(domain: String) { self.domain = domain }
    public func register(_ adapter: any ClientIntegrationAdapter) throws {
        _ = try ClientContext(clientID: adapter.clientId)
        guard adapter.domain == domain else { throw IntegrationAdapterError.invalidIdentifier }
        guard adapters[adapter.clientId] == nil else { throw IntegrationAdapterError.duplicateAdapter }
        adapters[adapter.clientId] = adapter
    }
    public func adapter(clientId: String, requireNativeDelegation: Bool = false) async throws -> any ClientIntegrationAdapter {
        guard let adapter = adapters[clientId] else { throw IntegrationAdapterError.unknownAdapter }
        if requireNativeDelegation, !(await adapter.inspectDelegationSupport()).isSupported {
            throw IntegrationAdapterError.delegationUnavailable
        }
        return adapter
    }
    public func identifiers() -> [String] { adapters.keys.sorted() }
}
