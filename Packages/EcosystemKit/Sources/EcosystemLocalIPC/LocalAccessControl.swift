import Foundation

public enum LocalAccessControl {
    /// Область ОС поступает от домена, а не из MCP. Повторная сверка при approve
    /// запрещает подтверждение удалённой между preview/approve папки.
    public static func handle(policy: LocalAccessPolicy, scope: LocalAccessScope, role: LocalRole, client: LocalMCPClient?, request: LocalRPCRequest) async throws -> Data {
        guard role != .worker else { throw LocalRuntimeFailure.denied }
        let keys: Set<String>
        switch request.operation {
        case "access.status", "access.scope": keys = []
        case "access.request": keys = ["draft"]
        case "access.approve": keys = ["planID", "fingerprint"]
        case "access.revoke": keys = ["grantID"]
        default: throw LocalRuntimeFailure.denied
        }
        let value = try LocalWire.decode(LocalAccessRequest.self, request.payload, keys: keys)
        if let draft = value.draft {
            let object = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any]
            let allowed: Set<String> = ["client", "roots", "capabilities", "dataClass", "maximumResultObjects", "maximumResponseBytes", "maximumSourceObjects", "maximumSourceBytes", "maximumRequests", "periodSeconds", "lifetimeSeconds"]
            guard let fields = object?["draft"] as? [String: Any], Set(fields.keys).isSubset(of: allowed), Set(draft.roots).isSubset(of: Set(scope.roots.map(\.id))) else { throw LocalRuntimeFailure.invalidRequest }
        }
        switch request.operation {
        case "access.scope": guard role == .gui else { throw LocalRuntimeFailure.denied }; return try LocalWire.encode(scope)
        case "access.status": return try LocalWire.encode(await policy.state(client: role == .mcp ? client ?? .legacy : nil))
        case "access.request":
            guard let draft = value.draft else { throw LocalRuntimeFailure.invalidRequest }
            return try LocalWire.encode(try await policy.request(draft, client: role == .mcp ? client ?? .legacy : nil))
        case "access.approve":
            guard role == .gui, let id = value.planID, let fingerprint = value.fingerprint else { throw LocalRuntimeFailure.denied }
            let plan = try await policy.plan(id)
            guard Set(plan.draft.roots).isSubset(of: Set(scope.roots.map(\.id))) else { throw LocalRuntimeFailure.denied }
            return try LocalWire.encode(try await policy.approve(id, fingerprint: fingerprint, role: role))
        case "access.revoke":
            guard let id = value.grantID else { throw LocalRuntimeFailure.invalidRequest }
            let client = try await policy.revoke(id, role: role)
            return try JSONSerialization.data(withJSONObject: ["client": client.rawValue, "revoked": true])
        default: throw LocalRuntimeFailure.denied
        }
    }
}
