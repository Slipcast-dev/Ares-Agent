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
        guard let base = Bundle.module.resourceURL else { throw ContractFailure.invalidArgument }
        return try data(relativePath: relativePath, resourceRoot: base)
    }

    /// SwiftPM/Xcode создают разные layout resource bundle. В одном resourceURL
    /// указывает на корень с вложенным Resources, в другом — уже на Resources.
    /// Пробуем только две известные схемы внутри собственного bundle. Ошибку
    /// чтения существующего файла не маскируем повтором из другого расположения.
    static func data(relativePath: String, resourceRoot: URL) throws -> Data {
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw ContractFailure.invalidArgument
        }
        let candidates = [resourceRoot.appendingPathComponent("Resources/" + relativePath),
                          resourceRoot.appendingPathComponent(relativePath)]
        for file in candidates where FileManager.default.fileExists(atPath: file.path) {
            return try Data(contentsOf: file)
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
}
