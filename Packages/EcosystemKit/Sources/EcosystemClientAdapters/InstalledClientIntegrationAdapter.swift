import Foundation

/// Мост к существующим транзакционным адаптерам. UI/CLI E9/E10 сохраняют свои
/// API, а новые координаторы могут работать с ними через нейтральный реестр.
public struct InstalledClientIntegrationAdapter: ClientIntegrationAdapter {
    public let clientId: String
    public let domain: String
    private let detection: IntegrationDetection
    private let capabilities: IntegrationCapabilities
    private let readStatus: @Sendable () async throws -> IntegrationRegistration
    private let preview: @Sendable (Bool) async throws -> IntegrationRegistrationPlan
    private let apply: @Sendable (IntegrationRegistrationPlan) async throws -> IntegrationRegistration

    private init(clientId: String, domain: String, detection: IntegrationDetection,
                 capabilities: IntegrationCapabilities,
                 readStatus: @escaping @Sendable () async throws -> IntegrationRegistration,
                 preview: @escaping @Sendable (Bool) async throws -> IntegrationRegistrationPlan,
                 apply: @escaping @Sendable (IntegrationRegistrationPlan) async throws -> IntegrationRegistration) {
        self.clientId = clientId; self.domain = domain; self.detection = detection
        self.capabilities = capabilities; self.readStatus = readStatus; self.preview = preview; self.apply = apply
    }
    public func detect() async -> IntegrationDetection { detection }
    public func inspectCapabilities() async -> IntegrationCapabilities { capabilities }
    public func inspectRegistration() async throws -> IntegrationRegistration { try await readStatus() }
    public func previewRegistration(connected: Bool) async throws -> IntegrationRegistrationPlan { try await preview(connected) }
    public func applyRegistration(_ plan: IntegrationRegistrationPlan) async throws -> IntegrationRegistration {
        guard plan.clientId == clientId, plan.domain == domain else { throw IntegrationAdapterError.wrongPlan }
        return try await apply(plan)
    }

    public static func codex(configuration: CodexAdapterConfiguration) -> Self {
        let adapter = CodexAdapter(configuration: configuration), domain = configuration.domain.rawValue
        // Версию Codex нельзя выводить из пути/наличия config.toml: unknown до CLI discovery.
        let detection = IntegrationDetection(clientId: "codex", version: nil,
            executablePath: configuration.codexExecutableURL?.path, profilePath: configuration.configDirectory.path,
            availability: configuration.codexExecutableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) ? .supported : .unsupported } ?? .unknown)
        @Sendable func convert(_ status: CodexAdapterStatus) -> IntegrationRegistration {
            IntegrationRegistration(clientId: "codex", domain: domain, state: status.connected ? "configured" : status.state,
                detail: status.detail, configured: status.connected)
        }
        return Self(clientId: "codex", domain: domain, detection: detection, capabilities: IntegrationCapabilities(),
            readStatus: { convert(try await adapter.status()) }, preview: { connected in
                let plan = try await adapter.preview(connected: connected)
                return IntegrationRegistrationPlan(clientId: "codex", domain: domain,
                    changes: plan.changes, payload: try JSONEncoder().encode(plan))
            }, apply: { plan in
                convert(try await adapter.apply(JSONDecoder().decode(CodexConnectionPlan.self, from: plan.payload)))
            })
    }

    public static func harness(configuration: HarnessAdapterConfiguration) -> Self {
        let adapter = HarnessAdapter(configuration: configuration), domain = configuration.domain.rawValue
        let detection = IntegrationDetection(clientId: "deepseek-harness", version: configuration.installedVersion,
            executablePath: nil, profilePath: configuration.patchURL.path, availability: .unknown)
        var capabilities = IntegrationCapabilities()
        // Два проверенных desktop контракта; новые версии остаются unknown.
        if HarnessPatch.supports(version: configuration.installedVersion) && configuration.profile == "desktop" {
            capabilities.localMCP = .supported; capabilities.nativeDelegation = .supported
            capabilities.namedRoles = .supported; capabilities.toolFiltering = .supported
        }
        @Sendable func convert(_ status: HarnessAdapterStatus) -> IntegrationRegistration {
            IntegrationRegistration(clientId: "deepseek-harness", domain: domain, state: status.connected ? "configured" : status.state,
                detail: status.detail, configured: status.connected)
        }
        return Self(clientId: "deepseek-harness", domain: domain, detection: detection, capabilities: capabilities,
            readStatus: { convert(try await adapter.status()) }, preview: { connected in
                let plan = try await adapter.preview(connected: connected)
                return IntegrationRegistrationPlan(clientId: "deepseek-harness", domain: domain,
                    changes: plan.changes, payload: try JSONEncoder().encode(plan))
            }, apply: { plan in
                convert(try await adapter.apply(JSONDecoder().decode(HarnessConnectionPlan.self, from: plan.payload)))
            })
    }
}
