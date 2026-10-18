import Foundation
import XCTest
import EcosystemClientAdapters
@testable import FileOrganizerCore

final class AgentRegistrationTests: XCTestCase {
    func testHarnessOwnedRoleRoundtripKeepsForeignYamlAndModel() async throws {
        let home = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ecosystem-e10-ares-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let patch = home.appendingPathComponent("cordis.patch.yml")
        let original = "# Сохранить байты\n- insert:\n    - id: existing\n      name: foreign-provider\n      config: {model: 'user-model', value: !!js process.env.DO_NOT_EVALUATE}\n"
        try original.write(to: patch, atomically: true, encoding: .utf8)
        let service = AgentRegistrationService(helper: URL(fileURLWithPath: "/usr/bin/true"),
            codexCLI: nil, codexHome: home, harnessPatch: patch, harnessInstalledVersion: "0.2.0-rc.2")
        let plan = try await service.previewHarnessConnection(connected: true)
        XCTAssertEqual(try String(contentsOf: patch), original)
        _ = try await service.applyHarnessConnection(plan)
        let status = try await service.status(.harness)
        XCTAssertTrue(status.connected)
        XCTAssertTrue(try String(contentsOf: patch).contains("delegate_ares"))
        try await service.setConnected(true, agent: .harness)
        try await service.setConnected(false, agent: .harness)
        XCTAssertEqual(try String(contentsOf: patch), original)
    }

    func testHarnessRejectsForeignRoleAndChangedPreview() async throws {
        let home = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ecosystem-e10-ares-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let patch = home.appendingPathComponent("cordis.patch.yml")
        try "[]\n".write(to: patch, atomically: true, encoding: .utf8)
        let service = AgentRegistrationService(helper: URL(fileURLWithPath: "/usr/bin/true"),
            codexCLI: nil, codexHome: home, harnessPatch: patch, harnessInstalledVersion: "0.2.0-rc.2")
        let plan = try await service.previewHarnessConnection(connected: true)
        let foreign = "- insert: [{id: ecosystem-ares-delegate, name: foreign-plugin}]\n"
        try foreign.write(to: patch, atomically: true, encoding: .utf8)
        do { _ = try await service.applyHarnessConnection(plan); XCTFail("Устаревший план принят") } catch { }
        do { try await service.setConnected(false, agent: .harness); XCTFail("Чужая роль удалена") } catch { }
        XCTAssertEqual(try String(contentsOf: patch), foreign)
    }

    func testCodexCLIRealRegistrationInIsolatedHome() async throws {
        let cli = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { throw XCTSkip("Codex CLI не установлен") }
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.toml")
        try Data("model = \"test-model\"\n".utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let service = AgentRegistrationService(helper: URL(fileURLWithPath: "/usr/bin/true"), codexCLI: cli, codexHome: directory, harnessPatch: directory.appendingPathComponent("unused.yml"))
        try await service.setConnected(true, agent: .codex)
        let active = try await service.status(.codex)
        XCTAssertTrue(active.connected)
        XCTAssertTrue(try String(contentsOf: config).contains("[mcp_servers.ares]"))
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("agents/ares.toml")).contains("name = \"ares\""))
        try await service.setConnected(false, agent: .codex)
        let inactive = try await service.status(.codex)
        XCTAssertFalse(inactive.connected)
        XCTAssertTrue(try String(contentsOf: config).contains("test-model"))
        // Чужая запись с тем же именем не удаляется и не перезаписывается.
        let foreign = "model = \"test-model\"\n[mcp_servers.ares]\ncommand = \"/usr/bin/false\"\n"
        try Data(foreign.utf8).write(to: config)
        do { try await service.setConnected(false, agent: .codex); XCTFail("Нельзя отключать чужой сервер") } catch {}
        XCTAssertEqual(try String(contentsOf: config), foreign)
    }

    /// Между показом подтверждения и нажатием кнопки пользователь может
    /// изменить профиль. Адаптер обязан сохранить такую правку целиком.
    func testCodexPreviewRejectsConcurrentConfigurationChange() async throws {
        let cli = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw XCTSkip("Codex CLI не установлен")
        }
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.toml")
        let original = "model = \"first\"\n[mcp_servers.foreign]\ncommand = \"/usr/bin/false\"\n"
        try Data(original.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let service = AgentRegistrationService(helper: URL(fileURLWithPath: "/usr/bin/true"),
            codexCLI: cli, codexHome: directory, harnessPatch: directory.appendingPathComponent("unused.yml"))
        let plan = try await service.previewCodexConnection(connected: true)
        XCTAssertEqual(try String(contentsOf: config), original)
        let changed = original.replacingOccurrences(of: "first", with: "second")
        try Data(changed.utf8).write(to: config)
        do {
            _ = try await service.applyCodexConnection(plan)
            XCTFail("Устаревшее подтверждение не должно записывать профиль")
        } catch let error as CodexAdapterError {
            guard case .stalePlan = error else { return XCTFail("Ожидался stalePlan") }
        }
        XCTAssertEqual(try String(contentsOf: config), changed)
        let fresh = try await service.previewCodexConnection(connected: true)
        _ = try await service.applyCodexConnection(fresh)
        try await service.setConnected(false, agent: .codex)
        XCTAssertEqual(try String(contentsOf: config), changed)
    }

    func testProfileModelSurvivesRepositoryReloadAndEndpointRejectsSecrets() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")
        let store = AppContainer(databaseURL: url); try store.preparePersistentStore()
        let profile = try AIProviderProfile(name: "Test", kind: .deepSeek, endpoint: URL(string: "https://api.deepseek.com")!, modelName: "test-model")
        try await store.fileRepository.save(profile: profile)
        let reloaded = AppContainer(databaseURL: url)
        let profiles = try await reloaded.fileRepository.fetchProviderProfiles()
        XCTAssertEqual(profiles.first?.modelName, "test-model")
        XCTAssertThrowsError(try AIEndpointValidator.validate(endpoint: URL(string: "https://user:password@example.com")!, kind: .compatible))
        XCTAssertThrowsError(try AIEndpointValidator.validate(endpoint: URL(string: "https://example.com?api_key=secret")!, kind: .compatible))
        XCTAssertThrowsError(try AIEndpointValidator.validate(endpoint: URL(string: "https://")!, kind: .openAI))
    }
}
