import EcosystemContracts
import Foundation
import XCTest
@testable import EcosystemClientAdapters

/// Негативные сценарии подтверждают отсутствие неявного подключения и расширения прав.
final class IntegrationRegistryTests: XCTestCase {
    func testUnknownCapabilitiesDoNotAuthorizeDelegation() async throws {
        let adapter = HermesReadinessAdapter()
        let capabilities = await adapter.inspectCapabilities()
        XCTAssertEqual(capabilities.localMCP, .unknown)
        XCTAssertFalse(capabilities.nativeDelegation.isSupported)
        let status = try await adapter.inspectRegistration()
        XCTAssertEqual(status.state, "planned")
        XCTAssertFalse(status.configured)
        XCTAssertFalse(status.handshakeVerified)
        let encoded = try JSONEncoder().encode(capabilities)
        XCTAssertEqual(try JSONDecoder().decode(IntegrationCapabilities.self, from: encoded), capabilities)
    }
    func testHarnessRegistryRecognizesOnlyVerifiedDesktopContracts() async throws {
        let root = temporaryRoot()
        for version in ["0.2.0-rc.2", "0.2.1-rc.2", "0.2.2-rc.1"] {
            let adapter = InstalledClientIntegrationAdapter.harness(configuration: .init(
                domain: .ares, patchURL: root.appendingPathComponent("cordis.patch.yml"),
                helperURL: URL(fileURLWithPath: "/usr/bin/true"), installedVersion: version))
            let capabilities = await adapter.inspectCapabilities()
            let expected = version == "0.2.2-rc.1" ? IntegrationSupport.unknown : IntegrationSupport.supported
            XCTAssertEqual(capabilities.nativeDelegation, expected)
            XCTAssertEqual(capabilities.localMCP, expected)
        }
        // Discovery не должен создавать профиль или неявно подключать клиента.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testRegistryAcceptsThirdPartyWithoutDomainEnumChanges() async throws {
        let registry = ClientAdapterRegistry(domain: "ares")
        try await registry.register(HermesReadinessAdapter())
        try await registry.register(ThirdPartyFixture(domain: "ares"))
        let ids = await registry.identifiers()
        XCTAssertEqual(ids, ["hermes", "third-party-fixture"])
        let adapter = try await registry.adapter(clientId: "third-party-fixture")
        let status = try await adapter.diagnose()
        XCTAssertFalse(status.handshakeVerified)
        let supported = await adapter.inspectDelegationSupport()
        XCTAssertEqual(supported, .unsupported)
    }
    func testUnknownOrUnavailableDelegationFailsClosed() async throws {
        let registry = ClientAdapterRegistry(domain: "ares")
        try await registry.register(HermesReadinessAdapter())
        try await registry.register(ThirdPartyFixture(domain: "ares"))
        for id in ["hermes", "third-party-fixture"] {
            do { _ = try await registry.adapter(clientId: id, requireNativeDelegation: true); XCTFail("unsafe delegation") }
            catch { XCTAssertEqual(error as? IntegrationAdapterError, .delegationUnavailable) }
        }
    }
    func testCodexBridgeRoundTripPreservesUserModel() async throws {
        let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Для проверки нужен Codex CLI.") }
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        let original = Data("# preserved model\nmodel = \"user-selected-model\"\n".utf8)
        try original.write(to: config)
        let adapter = InstalledClientIntegrationAdapter.codex(configuration: .init(domain: .athena,
            configDirectory: root, helperURL: URL(fileURLWithPath: "/usr/bin/true"), codexExecutableURL: executable))
        let plan = try await adapter.previewRegistration(connected: true)
        let status = try await adapter.applyRegistration(plan)
        XCTAssertTrue(status.configured)
        XCTAssertFalse(status.delegationVerified)
        _ = try await adapter.removeOwnedRegistration()
        XCTAssertEqual(try Data(contentsOf: config), original)
    }
    func testRegistryRejectsDuplicateAndWrongDomain() async throws {
        let registry = ClientAdapterRegistry(domain: "ares")
        try await registry.register(HermesReadinessAdapter())
        do { try await registry.register(HermesReadinessAdapter()); XCTFail("duplicate") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .duplicateAdapter) }
        do { try await registry.register(HermesReadinessAdapter(domain: "athena")); XCTFail("domain") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .invalidIdentifier) }
        do { _ = try await registry.adapter(clientId: "absent"); XCTFail("unknown") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .unknownAdapter) }
    }
    func testInvalidThirdPartyIdentifierRejected() async throws {
        let registry = ClientAdapterRegistry(domain: "ares")
        do { try await registry.register(ThirdPartyFixture(clientId: "../bad", domain: "ares")); XCTFail("invalid") }
        catch { /* Контракт ClientContext определяет допустимые символы. */ }
    }
    func testMissingProgramDoesNotCreateProfile() async throws {
        let root = temporaryRoot()
        let adapter = HermesReadinessAdapter(executableURL: root.appendingPathComponent("missing"), profileURL: root)
        let detection = await adapter.detect()
        XCTAssertEqual(detection.availability, .unsupported)
        do { _ = try await adapter.previewRegistration(connected: true); XCTFail("missing") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .programMissing) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testExistingExecutableDoesNotApproveUnknownVersionOrExecute() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("hermes")
        // Если discovery ошибочно запустит программу, появится marker.
        try Data("#!/bin/sh\ntouch '\(root.path)/executed'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let adapter = HermesReadinessAdapter(executableURL: executable,
            profileURL: root.appendingPathComponent("profile"), detectedVersion: "999.0")
        let detection = await adapter.detect()
        XCTAssertEqual(detection.version, "999.0")
        XCTAssertEqual(detection.availability, .supported)
        do { _ = try await adapter.previewRegistration(connected: true); XCTFail("version") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .unsupportedVersion) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("profile").path))
    }
    func testHermesCannotApplyDisconnectOrClaimHandshake() async throws {
        let adapter = HermesReadinessAdapter()
        let plan = IntegrationRegistrationPlan(clientId: "hermes", domain: "ares", changes: [], payload: Data())
        do { _ = try await adapter.applyRegistration(plan); XCTFail("apply") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .registrationUnavailable) }
        do { _ = try await adapter.removeOwnedRegistration(); XCTFail("disconnect") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .programMissing) }
        do { _ = try await adapter.validateConnection(); XCTFail("handshake") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .connectionUnverified) }
    }
    func testNeutralRolesHaveNoModelOverrideAndRemainSeparated() async throws {
        for domain in ["ares", "athena", "coordinator"] {
            let roles = try await HermesReadinessAdapter(domain: domain).exportRoles()
            XCTAssertEqual(roles.count, 1)
            let role = try XCTUnwrap(roles.first)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: role.manifest) as? [String: Any])
            XCTAssertEqual(object["roleId"] as? String, domain)
            XCTAssertTrue(object["modelOverride"] is NSNull)
            XCTAssertEqual(object["enabledByDefault"] as? Bool, false)
            XCTAssertEqual(object["allowedAgentIds"] as? [String], domain == "coordinator" ? ["ares", "athena"] : [domain])
            XCTAssertFalse(role.instructions.isEmpty)
        }
    }
    func testHarnessBridgeRoundTripPreservesForeignSettings() async throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let patch = root.appendingPathComponent("cordis.patch.yml")
        let original = Data("# user model remains untouched\n- insert: []\n".utf8)
        try original.write(to: patch)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: patch.path)
        let bridge = InstalledClientIntegrationAdapter.harness(configuration: .init(domain: .ares,
            patchURL: patch, helperURL: URL(fileURLWithPath: "/usr/bin/true"), installedVersion: HarnessPatch.supportedVersion))
        let registry = ClientAdapterRegistry(domain: "ares")
        try await registry.register(bridge)
        let adapter = try await registry.adapter(clientId: "deepseek-harness")
        let plan = try await adapter.previewRegistration(connected: true)
        XCTAssertEqual(try Data(contentsOf: patch), original)
        let status = try await adapter.applyRegistration(plan)
        XCTAssertEqual(status.state, "configured")
        XCTAssertFalse(status.handshakeVerified)
        do { _ = try await adapter.validateConnection(); XCTFail("false handshake") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .connectionUnverified) }
        _ = try await adapter.removeOwnedRegistration()
        XCTAssertEqual(try Data(contentsOf: patch), original)
    }
    func testForeignPlanAndUnsupportedHarnessDowngrade() async throws {
        let bridge = InstalledClientIntegrationAdapter.harness(configuration: .init(domain: .athena,
            patchURL: temporaryRoot().appendingPathComponent("patch.yml"), helperURL: URL(fileURLWithPath: "/usr/bin/true"), installedVersion: "999"))
        let support = await bridge.inspectDelegationSupport()
        XCTAssertEqual(support, .unknown)
        let plan = IntegrationRegistrationPlan(clientId: "codex", domain: "athena", changes: [], payload: Data())
        do { _ = try await bridge.applyRegistration(plan); XCTFail("foreign") }
        catch { XCTAssertEqual(error as? IntegrationAdapterError, .wrongPlan) }
        let codex = InstalledClientIntegrationAdapter.codex(configuration: .init(domain: .ares,
            configDirectory: temporaryRoot(), helperURL: URL(fileURLWithPath: "/usr/bin/true")))
        let discovery = await codex.detect()
        XCTAssertNil(discovery.version)
        XCTAssertEqual(discovery.availability, .unknown)
    }
    func testExistingClientContextsAndNewIdentifierRoundTrip() throws {
        for identifier in ["codex", "deepseek-harness", "hermes", "vendor-next"] {
            let context = try ClientContext(clientID: identifier)
            XCTAssertEqual(try JSONDecoder().decode(ClientContext.self, from: JSONEncoder().encode(context)).clientID, identifier)
        }
    }
    func testExportMappingIsDraftAndPreservesPathWithSpaces() async throws {
        for domain in ["ares", "athena"] {
            let adapter = HermesReadinessAdapter(domain: domain)
            let data = try adapter.exportMCPDraft(helperURL: URL(fileURLWithPath: "/tmp/Агенты E11/" + domain + "-mcp.command"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["mcp_servers"])
            let servers = try XCTUnwrap(object["mcp_servers"] as? [String: [String: Any]])
            XCTAssertEqual(Set(servers.keys), [domain])
            XCTAssertEqual(servers[domain]?["command"] as? String, "/tmp/Агенты E11/" + domain + "-mcp.command")
            XCTAssertEqual(servers[domain]?["args"] as? [String], [])
            XCTAssertNil(servers[domain]?["env"])
            let status = try await adapter.inspectRegistration()
            XCTAssertFalse(status.configured)
        }
    }
    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("ecosystem-e11-\(UUID().uuidString)")
    }
}

/// Тестовый внешний адаптер явно лишён регистрации и native delegation.
private struct ThirdPartyFixture: ClientIntegrationAdapter {
    let clientId: String
    let domain: String
    init(clientId: String = "third-party-fixture", domain: String) { self.clientId = clientId; self.domain = domain }
    func detect() async -> IntegrationDetection {
        .init(clientId: clientId, version: "fixture-1", executablePath: nil, profilePath: nil, availability: .supported)
    }
    func inspectCapabilities() async -> IntegrationCapabilities {
        var value = IntegrationCapabilities(); value.nativeDelegation = .unsupported; return value
    }
    func inspectRegistration() async throws -> IntegrationRegistration {
        .init(clientId: clientId, domain: domain, state: "fixture", detail: "Не является Hermes.")
    }
    func previewRegistration(connected: Bool) async throws -> IntegrationRegistrationPlan {
        throw IntegrationAdapterError.registrationUnavailable
    }
    func applyRegistration(_ plan: IntegrationRegistrationPlan) async throws -> IntegrationRegistration {
        throw IntegrationAdapterError.registrationUnavailable
    }
}
