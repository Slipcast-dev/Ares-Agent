import Foundation
import EcosystemLocalIPC
import CryptoKit
import EcosystemContracts
import EcosystemRuntimeSupport

/// План хранится только в приватной БД. Разрешение связывается с конфигурацией,
/// конкретными версиями файлов и TTL; входное approved=true не является правом.
public struct RulePlan: Codable, Identifiable, Sendable {
    public let id: UUID
    public let ruleID: UUID
    public let revision: String
    public let kind: String
    public let createdAt: Date
    public let expiresAt: Date
    public let files: [RuleFileSnapshot]
    public var accessTicket: LocalAccessTicket? = nil
    public var approvedAt: Date?
    public var consumedAt: Date?
    public var fingerprint: String {
        let versions = files.sorted { $0.relativePath < $1.relativePath }.map(\.fingerprint).joined(separator: "\n")
        return RulePolicy.digest(Data((id.uuidString + revision + kind + String(expiresAt.timeIntervalSince1970) + versions + (accessTicket?.grantID.uuidString ?? "localGUI") + (accessTicket?.client.rawValue ?? "localGUI")).utf8))
    }
}
public struct RulePermission: Codable, Sendable {
    public let revision: String
    public let approvedAt: Date
}
public enum RulePolicy {
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func versionFingerprint(_ version: FileVersion) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest((try? encoder.encode(version)) ?? Data())
    }
    public static func revision(_ rule: AutomationRule) throws -> String {
        // enabled — состояние, а не новая конфигурация. Все параметры и лимиты
        // входят в hash, поэтому редактирование автоматически отзывает approval.
        var value = rule; value.enabled = false
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(value))
    }
    public static func requiresGUI(_ rule: AutomationRule) -> Bool {
        rule.actions.contains { [.showFiles, .showDuplicates].contains($0.kind) }
    }
    public static func quotas(_ files: [RuleFileSnapshot], rule: AutomationRule) throws -> Int64 {
        let maxFiles = rule.maximumFiles ?? 1000, maxBytes = rule.maximumBytes ?? 1_073_741_824
        guard (1...1000).contains(maxFiles), (1...1_073_741_824).contains(maxBytes), files.count <= maxFiles else { throw RulePolicyError.quota }
        var bytes: Int64 = 0
        for file in files {
            let (next, overflow) = bytes.addingReportingOverflow(file.isDirectory ? 0 : file.byteSize)
            guard !overflow, next <= maxBytes else { throw RulePolicyError.quota }; bytes = next
        }
        return bytes
    }
}
public enum RulePolicyError: String, Error, LocalizedError, QueueDomainError, Sendable {
    case invalid, permission, stale, quota, guiRequired, space
    public var knownCode: KnownErrorCode {
        switch self { case .permission: .permissionDenied; case .stale: .staleSnapshot; case .guiRequired: .clientUnavailable; default: .invalidArgument }
    }
    public var errorDescription: String? {
        switch self {
        case .invalid: "Проверьте параметры, связи и циклы правила."
        case .permission: "Нужно локальное подтверждение этой версии правила или плана."
        case .stale: "План устарел или файлы изменились. Создайте новый предварительный просмотр."
        case .quota: "Превышен лимит объектов, исходных данных или общий бюджет цепочки правил."
        case .guiRequired: "Действие требует интерфейса или разрешения macOS и не выполнено фоновым агентом."
        case .space: "Недостаточно свободного места с учётом результата и резерва."
        }
    }
}
/// Единая типизированная граница для GUI/MCP. Сервер проверяет поля по операции.
public struct RuleControlRequest: Codable, Sendable {
    public var cursor: String? = nil
    public var rule: AutomationRule?
    public var ruleID: UUID?
    public var runID: UUID?
    public var planID: UUID?
    public var fingerprint: String?
    public var key: String?
    public var offset: Int?
    public var eventID: UUID?
    public var processingToken: UUID?
    public init(rule: AutomationRule? = nil, ruleID: UUID? = nil, runID: UUID? = nil, planID: UUID? = nil, fingerprint: String? = nil, key: String? = nil, offset: Int? = nil, eventID: UUID? = nil, processingToken: UUID? = nil, cursor: String? = nil) {
        self.cursor = cursor
        self.eventID = eventID; self.processingToken = processingToken
        self.rule = rule; self.ruleID = ruleID; self.runID = runID; self.planID = planID; self.fingerprint = fingerprint; self.key = key; self.offset = offset
    }
}

/// Проекция плана ограничена сотней имён, полный набор остаётся в runtime DB.
public struct RulePlanSummary: Codable, Identifiable, Sendable {
    public let id: UUID
    public let ruleID: UUID
    public let name: String
    public let kind: String
    public let revision: String
    public let fingerprint: String
    public let expiresAt: Date
    public let fileCount: Int
    public let byteSize: Int64
    public let maximumFiles: Int
    public let maximumBytes: Int64
    public let sourceRootID: UUID
    public let destinationRootIDs: [UUID]
    public let source: String
    public let destinations: [String]
    public let actions: [String]
    public let files: [String]
    public let approved: Bool
}

public struct RulePlanFilesPage: Codable, Sendable {
    public let files: [String]
    public let nextOffset: Int?
}
