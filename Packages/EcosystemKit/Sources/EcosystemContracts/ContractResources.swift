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
        // SwiftPM на разных версиях Xcode размещает .copy("Resources") либо
        // под resourceURL/Resources, либо прямо под resourceURL. Выбираем только
        // ресурс собственного bundle; внешние каталоги и cwd не участвуют.
        let nested = base.appendingPathComponent("Resources/" + relativePath)
        let direct = base.appendingPathComponent(relativePath)
        let resource = FileManager.default.fileExists(atPath: nested.path) ? nested : direct
        return try Data(contentsOf: resource)
    }
}
