import Foundation
import EcosystemLocalization

public struct LocalAutomationRequest: Codable, Sendable {
    public var paused: Bool?
    public var notificationsEnabled: Bool?
    public var limit: Int?
    public var leaseSeconds: Int?
    public var eventID: UUID?
    public var token: UUID?
    public var processingToken: UUID?
    public init() {}
}
public enum LocalAutomationControl {
    public static func handle(service: LocalAutomationService, policy: LocalAccessPolicy?, role: LocalRole,
                              client: LocalMCPClient?, validRoots: Set<UUID> = [], request: LocalRPCRequest) async throws -> Data {
        let keys: Set<String>
        switch request.operation {
        case "automation.status", "automation.request_notifications": keys = []
        case "automation.configure": keys = ["paused", "notificationsEnabled"]
        case "events.list": keys = ["limit"]
        case "events.claim": keys = ["limit", "leaseSeconds"]
        case "events.ack": keys = ["eventID", "token"]
        case "events.claim_processing": keys = ["eventID", "leaseSeconds"]
        case "events.ack_processing": keys = ["eventID", "processingToken"]
        default: throw LocalRuntimeFailure.denied
        }
        let value = try LocalWire.decode(LocalAutomationRequest.self, request.payload, keys: keys)
        if request.operation.hasPrefix("automation.") {
            guard role == .gui else { throw LocalRuntimeFailure.denied }
            if request.operation == "automation.configure" { try await service.configure(paused: value.paused, notificationsEnabled: value.notificationsEnabled) }
            if request.operation == "automation.request_notifications" { _ = try await service.requestNotifications() }
            return try LocalWire.encode(await service.status())
        }
        guard role != .worker else { throw LocalRuntimeFailure.denied }
        guard (1...50).contains(value.limit ?? 50) else { throw LocalRuntimeFailure.invalidRequest }
        let owner = client ?? .legacy
        var allowed: Set<UUID>? = nil
        var grantID: UUID?
        var ticket: LocalAccessTicket?
        if role == .mcp {
            guard let policy else { throw LocalRuntimeFailure.denied }
            let accepted = try await policy.authorize(client: owner, capability: "events.read")
            let grant = try await policy.check(accepted); ticket = accepted; grantID = grant.id
            allowed = Set(try await service.inbox.events().filter {
                grant.draft.capabilities.contains($0.capability) && Set($0.rootIDs).isSubset(of: Set(grant.draft.roots)) && Set($0.rootIDs).isSubset(of: validRoots)
            }.map(\.id))
        }
        let result: Data
        switch request.operation {
        case "events.claim_processing":
            guard role == .mcp, let id = value.eventID, allowed?.contains(id) == true,
                  let grantID else { throw LocalRuntimeFailure.denied }
            result = try LocalWire.encode(await service.inbox.claimProcessing(id: id, client: owner,
                authorizationID: grantID, leaseSeconds: Double(value.leaseSeconds ?? 120)))
        case "events.ack_processing":
            guard role == .mcp, let id = value.eventID, let token = value.processingToken,
                  allowed?.contains(id) == true, let grantID else { throw LocalRuntimeFailure.denied }
            try await service.inbox.ackProcessing(id: id, client: owner, token: token, authorizationID: grantID)
            result = try LocalWire.encode(LocalEmpty())
        case "events.list":
            if role == .gui {
                let rows = try await service.inbox.events().suffix(value.limit ?? 50).reversed().map {
                    LocalInboxDelivery(event: $0, state: .pending, token: nil, leaseExpiresAt: nil)
                }
                result = try LocalWire.encode(rows)
            } else { result = try LocalWire.encode(await service.inbox.list(client: owner, allowedEventIDs: allowed, limit: value.limit ?? 50)) }
        case "events.claim": result = try LocalWire.encode(await service.inbox.claim(client: owner, allowedEventIDs: allowed, limit: value.limit ?? 50, leaseSeconds: Double(value.leaseSeconds ?? 120), authorizationID: grantID))
        case "events.ack":
            guard let id = value.eventID, let token = value.token, allowed?.contains(id) ?? true else { throw LocalRuntimeFailure.denied }
            try await service.inbox.ack(id: id, client: owner, token: token, authorizationID: grantID)
            result = try LocalWire.encode(LocalEmpty())
        default: throw LocalRuntimeFailure.denied
        }
        // Проверяем право ещё раз после actor hop; отзыв закрывает выдачу результата.
        if let ticket, let policy { return try await policy.export(result, ticket: ticket) }
        return result
    }
}
public enum LocalInboxMCP {
    public static let names = ["events.list", "events.claim", "events.ack", "events.claim_processing", "events.ack_processing"]
    public static var tools: [[String: Any]] {
        names.map { name in
            var properties: [String: Any] = [:]
            var required: [String] = []
            if name == "events.ack" || name == "events.ack_processing" {
                let token = name == "events.ack" ? "token" : "processingToken"
                properties = ["eventID": ["type": "string", "format": "uuid"], token: ["type": "string", "format": "uuid"]]; required = ["eventID", token]
            } else if name == "events.claim_processing" {
                properties = ["eventID": ["type": "string", "format": "uuid"], "leaseSeconds": ["type": "integer", "minimum": 30, "maximum": 300]]
                required = ["eventID"]
            } else {
                properties["limit"] = ["type": "integer", "minimum": 1, "maximum": 50]
                if name == "events.claim" { properties["leaseSeconds"] = ["type": "integer", "minimum": 30, "maximum": 300] }
            }
            return ["name": name, "description": RuntimeLocalization.bilingual("Сохранённые локальные события: явное чтение, временный захват и подтверждение; модель автоматически не запускается."), "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
        }
    }
    public static func call(_ name: String, args: [String: Any], client: LocalRPCClient) async throws -> [String: Any] {
        guard names.contains(name) else { throw LocalRuntimeFailure.invalidRequest }
        let keys: Set<String>
        switch name {
        case "events.ack": keys = ["eventID", "token"]
        case "events.claim": keys = ["limit", "leaseSeconds"]
        case "events.claim_processing": keys = ["eventID", "leaseSeconds"]
        case "events.ack_processing": keys = ["eventID", "processingToken"]
        default: keys = ["limit"]
        }
        let request = try LocalWire.decode(LocalAutomationRequest.self, JSONSerialization.data(withJSONObject: args), keys: keys)
        if name == "events.ack" || name == "events.ack_processing" {
            let _: LocalEmpty = try await client.call(name, request); return ["acknowledged": true]
        }
        if name == "events.claim_processing" {
            let claim: LocalProcessingClaim = try await client.call(name, request)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            guard let result = try JSONSerialization.jsonObject(with: encoder.encode(claim)) as? [String: Any] else { throw LocalRuntimeFailure.operationFailed }
            return result
        }
        let rows: [LocalInboxDelivery] = try await client.call(name, request)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return ["items": try JSONSerialization.jsonObject(with: encoder.encode(rows))]
    }
}
