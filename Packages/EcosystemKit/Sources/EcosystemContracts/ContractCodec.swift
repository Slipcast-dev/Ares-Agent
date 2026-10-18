import Foundation

public enum ContractFailure: Error, Equatable {
    case invalidArgument, incompatibleVersion, messageTooLarge, staleSnapshot, forbiddenTransition
}

/// Внешние границы используют codec: синтезированный Codable не проверяет
/// межполевые инварианты. Домен проверяет строгую схему конкретных parameters.
public protocol EcosystemContract: Codable, Sendable {
    static var allowedRequestKeys: Set<String>? { get }
    func validate() throws
}
public extension EcosystemContract {
    static var allowedRequestKeys: Set<String>? { nil }
}
public enum ContractCodec {
    public static let maximumBytes = 1_048_576
    public static func encode<T: EcosystemContract>(_ value: T) throws -> Data {
        try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw ContractFailure.messageTooLarge }
        return data
    }
    public static func decode<T: EcosystemContract>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumBytes else { throw ContractFailure.messageTooLarge }
        if let allowed = T.allowedRequestKeys {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: allowed) else { throw ContractFailure.invalidArgument }
        }
        let value = try JSONDecoder().decode(type, from: data)
        try value.validate()
        return value
    }
}

/// Int64 не проходит через Double: большие размеры сохраняют точность на wire.
public struct NonnegativeInt: Codable, Equatable, Sendable {
    public let value: Int64
    public init(_ value: Int64) throws {
        guard value >= 0 else { throw ContractFailure.invalidArgument }
        self.value = value
    }
    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(Int64.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(value)
    }
}

/// Только UTC ISO 8601 с Z; локальный timezone не участвует в обмене.
public struct UTCTimestamp: Codable, Equatable, Comparable, Sendable {
    public let value: String
    private let date: Date
    public init(_ value: String) throws {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,3})?Z\\z",
                          options: .regularExpression) != nil else { throw ContractFailure.invalidArgument }
        let formatter = ISO8601DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.formatOptions = [.withInternetDateTime]
        if value.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        guard let parsed = formatter.date(from: value) else { throw ContractFailure.invalidArgument }
        // ISO8601DateFormatter нормализует 30 февраля в март. Обратное
        // форматирование исключает такой скрытый сдвиг срока задания.
        formatter.formatOptions = [.withInternetDateTime]
        guard formatter.string(from: parsed).prefix(19) == value.prefix(19) else {
            throw ContractFailure.invalidArgument
        }
        self.value = value; date = parsed
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(value)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.date < rhs.date }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.date == rhs.date }
}

public struct ContractVersion: Codable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public static let current = ContractVersion(major: 1, minor: 0)
    public init(major: Int, minor: Int = 0) { self.major = major; self.minor = minor }
    private enum CodingKeys: String, CodingKey { case major, minor }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        major = try c.decode(Int.self, forKey: .major)
        minor = try c.decodeIfPresent(Int.self, forKey: .minor) ?? 0
    }
    public func requireCompatible() throws {
        guard major == Self.current.major else { throw ContractFailure.incompatibleVersion }
        guard minor >= 0 else { throw ContractFailure.invalidArgument }
    }
}

/// Типизированные operation payloads не связывают протокол со старой DB-моделью.
public struct EmptyParameters: Codable, Equatable, Sendable {
    public init() {}
    public init(from decoder: Decoder) throws {
        try ContractValidation.rejectUnknownFields(decoder, allowed: [])
    }
}
public struct RootParameters: Codable, Equatable, Sendable {
    public let rootID: UUID
    public init(rootID: UUID) { self.rootID = rootID }
    private enum CodingKeys: String, CodingKey { case rootID = "rootId" }
    public init(from decoder: Decoder) throws {
        try ContractValidation.rejectUnknownFields(decoder, allowed: ["rootId"])
        rootID = try decoder.container(keyedBy: CodingKeys.self).decode(UUID.self, forKey: .rootID)
    }
}
public enum AgentID: String, Codable, CaseIterable, Sendable { case ares, athena }
public enum OriginVerification: String, Codable, Sendable { case unverified, localPeerVerified }
public enum TaskOrigin: String, Codable, Sendable { case user, localRule, externalConnection }
public enum DisconnectPolicy: String, Codable, Sendable { case continueOnDisconnect, cancelOnDisconnect }
public enum Completeness: String, Codable, Sendable { case complete, partial, unavailable }
public enum DataClassification: String, Codable, CaseIterable, Sendable {
    case aggregate, fileMetadata, localContent, contentExport, secret
    public var exportableInFirstVersion: Bool { self == .aggregate || self == .fileMetadata }
}
public enum ImplementationStatus: String, Codable, Sendable { case planned, implemented }
public enum CapabilityMode: String, Codable, Sendable { case readOnly, mutating }
public enum SupportLevel: String, Codable, Sendable { case supported, unsupported, unknown }
public enum ErrorScope: String, Codable, Sendable { case transport, operation }
public enum EventSeverity: String, Codable, Sendable { case info, warning, error }

/// Проверенная identity НЕ Codable: клиентские JSON labels не дают полномочий.
public struct VerifiedLocalPeer: Sendable {
    public let userID: UInt32
    public let signingIdentifier: String
    public init(userID: UInt32, signingIdentifier: String) {
        self.userID = userID; self.signingIdentifier = signingIdentifier
    }
}
private struct AnyContractKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
public enum ContractValidation {
    public static func rejectUnknownFields(_ decoder: Decoder, allowed: Set<String>) throws {
        let container = try decoder.container(keyedBy: AnyContractKey.self)
        guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw ContractFailure.invalidArgument
        }
    }
    public static func identifier(_ value: String) throws {
        guard value.range(of: "^[a-z][a-z0-9_.-]{0,127}\\z", options: .regularExpression) != nil else {
            throw ContractFailure.invalidArgument
        }
    }
    public static func boundedText(_ value: String, maximum: Int = 4096) throws {
        guard !value.isEmpty, value.utf8.count <= maximum else { throw ContractFailure.invalidArgument }
    }
    public static func percentage(_ value: Double) throws {
        // Нормализованная общая ёмкость CPU: 100 означает загрузку всех ядер.
        guard value.isFinite, (0...100).contains(value) else { throw ContractFailure.invalidArgument }
    }
}
