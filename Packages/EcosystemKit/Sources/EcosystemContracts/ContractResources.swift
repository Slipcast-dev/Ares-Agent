import Foundation

/// Версия описывает общий формат, а не готовность production runtime.
public struct EcosystemDescriptor: Sendable {
    public let agentID: AgentID
    public let version = ContractVersion.current
    public init(agentID: AgentID) { self.agentID = agentID }
    public var experimentalCapability: [String: Any] {
        ["agentId": agentID.rawValue, "major": version.major, "minor": version.minor,
         "runtimeIntegrated": false]
    }
}
public enum ContractResources {
    public static func data(relativePath: String) throws -> Data {
        guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains(".."),
              let base = Bundle.module.resourceURL else { throw ContractFailure.invalidArgument }
        return try Data(contentsOf: base.appendingPathComponent("Resources/" + relativePath))
    }
}
