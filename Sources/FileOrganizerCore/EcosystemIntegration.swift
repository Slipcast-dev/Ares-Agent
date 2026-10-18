import EcosystemContracts

/// Общая версия отделена от старых DB AgentTask моделей; их миграция — E3–E5.
public enum AresEcosystem {
    public static let descriptor = EcosystemDescriptor(agentID: .ares)
    public static func experimentalCapability(runtimeIntegrated: Bool) -> [String: Any] {
        var value = descriptor.experimentalCapability
        value["runtimeIntegrated"] = runtimeIntegrated
        if runtimeIntegrated { value["runtimeMode"] = "local-ad-hoc" }
        return value
    }
}
