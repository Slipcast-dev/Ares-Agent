import Foundation
import XCTest
@testable import EcosystemClientAdapters

final class CodexAdapterTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
    private var roots: [URL] = []
    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []; try super.tearDownWithError()
    }
    private func fixture() throws -> URL {
        let root = try physicalTemporaryDirectory().appendingPathComponent("ecosystem-codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        roots.append(root); return root
    }
    private func adapter(_ root: URL, domain: CodexAgentDomain = .ares, helper: String = "/usr/bin/true", cli: Bool = true) -> CodexAdapter {
        CodexAdapter(configuration: .init(domain: domain, configDirectory: root,
            helperURL: URL(fileURLWithPath: helper), codexExecutableURL: cli ? executable : nil))
    }
    private func requireCLI() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Для проверки реального TOML требуется установленный Codex CLI.") }
    }
    private func write(_ text: String, root: URL, path: String = "config.toml") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(text.utf8).write(to: url)
    }
    private func contents(_ root: URL, _ path: String = "config.toml") throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testRealCLIInstallDisconnectPreservesForeignConfigurationExactly() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        let original = "# Пользовательские комментарии\nmodel = \"gpt-5\"\n\n[mcp_servers.\"mac-assistant\"]\ncommand = \"/usr/bin/true\"\nargs = []\n"
        try write(original, root: root)
        let plan = try await client.preview(connected: true)
        XCTAssertFalse(plan.changes.isEmpty)
        let connected = try await client.apply(plan)
        XCTAssertTrue(connected.connected)
        let role = try contents(root, "agents/ares.toml")
        XCTAssertTrue(role.contains("name = \"ares\"")); XCTAssertTrue(role.contains("shell_tool = false"))
        XCTAssertFalse(role.contains("model_provider")); XCTAssertFalse(role.contains("approval_policy"))
        let disconnected = try await client.apply(client.preview(connected: false))
        XCTAssertEqual(disconnected.state, "disconnected")
        XCTAssertEqual(try contents(root), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("agents/ares.toml").path))
    }

    func testInstallIsIdempotentAndBackupsPrivate() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        _ = try await client.apply(client.preview(connected: true))
        let repeated = try await client.preview(connected: true)
        XCTAssertTrue(repeated.changes.isEmpty)
        _ = try await client.apply(repeated)
        let backupRoot = root.appendingPathComponent(".ecosystem-subagents/backups")
        let backups = try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: backups[0].appendingPathComponent("restore.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let serialized = String(decoding: try JSONEncoder().encode(repeated), as: UTF8.self)
        XCTAssertFalse(serialized.contains("developer_instructions")); XCTAssertFalse(serialized.contains("mcp_servers"))
    }

    func testManualEditAfterPreviewRejectsWithoutOverwrite() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        try write("# before\n", root: root)
        let plan = try await client.preview(connected: true)
        try write("# changed manually\n", root: root)
        do { _ = try await client.apply(plan); XCTFail("Устаревший план принят") }
        catch CodexAdapterError.stalePlan {}
        XCTAssertEqual(try contents(root), "# changed manually\n")
    }

    func testForeignRoleAndQuotedServerConflict() async throws {
        let root = try fixture(), client = adapter(root)
        try write("[mcp_servers.'ares']\ncommand = '/usr/bin/true'\n", root: root)
        let status = try await client.status(); XCTAssertEqual(status.state, "conflict")
        do { _ = try await client.preview(connected: true); XCTFail("Чужой сервер перезаписан") }
        catch CodexAdapterError.conflict {}
        try write("# clean\n", root: root)
        try write("name = \"ares\"\ndescription = \"foreign\"\n", root: root, path: "agents/other.toml")
        do { _ = try await client.preview(connected: true); XCTFail("Дубликат роли принят") }
        catch CodexAdapterError.conflict {}
    }

    func testChangedOwnedRoleRefusesDisconnect() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        _ = try await client.apply(client.preview(connected: true))
        try write("name = \"ares\"\n# manually edited\n", root: root, path: "agents/ares.toml")
        let status = try await client.status(); XCTAssertEqual(status.state, "conflict")
        do { _ = try await client.preview(connected: false); XCTFail("Изменённая роль удалена") }
        catch CodexAdapterError.conflict {}
        XCTAssertTrue(try contents(root, "agents/ares.toml").contains("manually edited"))
    }

    func testUnmanagedChangesOutsideBlockSurviveDisconnect() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        _ = try await client.apply(client.preview(connected: true))
        let installed = try contents(root)
        try write(installed + "\n# foreign after install\n", root: root)
        let status = try await client.status(); XCTAssertTrue(status.connected)
        _ = try await client.apply(client.preview(connected: false))
        XCTAssertEqual(try contents(root), "\n# foreign after install\n")
    }

    func testBothAgentsKeepIndependentRolesAndDisconnect() async throws {
        try requireCLI(); let root = try fixture(), ares = adapter(root), athena = adapter(root, domain: .athena)
        _ = try await ares.apply(ares.preview(connected: true))
        _ = try await athena.apply(athena.preview(connected: true))
        let both = try contents(root)
        XCTAssertTrue(both.contains("[mcp_servers.ares]")); XCTAssertTrue(both.contains("[mcp_servers.athena]"))
        _ = try await ares.apply(ares.preview(connected: false))
        let athenaStatus = try await athena.status(); XCTAssertTrue(athenaStatus.connected)
        XCTAssertFalse(try contents(root).contains("[mcp_servers.ares]"))
    }

    func testSymlinkAndHardLinkRejected() async throws {
        let root = try fixture(), foreign = try fixture()
        try write("# private\n", root: foreign)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("config.toml"), withDestinationURL: foreign.appendingPathComponent("config.toml"))
        do { _ = try await adapter(root).status(); XCTFail("Символическая ссылка принята") }
        catch CodexAdapterError.unsafePath {}
        try FileManager.default.removeItem(at: root.appendingPathComponent("config.toml"))
        try FileManager.default.linkItem(at: foreign.appendingPathComponent("config.toml"), to: root.appendingPathComponent("config.toml"))
        do { _ = try await adapter(root).status(); XCTFail("Жёсткая ссылка принята") }
        catch CodexAdapterError.unsafePath {}
    }

    func testMalformedTOMLRejectedByActualCodex() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        let original = "model = [unterminated\n"
        try write(original, root: root)
        do { _ = try await client.preview(connected: true); XCTFail("Некорректный TOML принят") }
        catch CodexAdapterError.cliValidationFailed {}
        XCTAssertEqual(try contents(root), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("agents/ares.toml").path))
    }

    func testMissingCLIPreventsConnectButNotStatus() async throws {
        let root = try fixture(), client = adapter(root, cli: false)
        let status = try await client.status(); XCTAssertEqual(status.state, "disconnected")
        do { _ = try await client.preview(connected: true); XCTFail("Подключение без проверки принято") }
        catch CodexAdapterError.cliUnavailable {}
        let plan = try await client.preview(connected: false); XCTAssertTrue(plan.changes.isEmpty)
    }

    func testPendingJournalFailsClosedWhenFileWasEdited() async throws {
        let root = try fixture(), client = adapter(root, cli: false)
        _ = try await client.status()
        let pending: [String: Any] = ["configBefore": Data("# old\n".utf8).base64EncodedString(),
            "configAfter": Data("# installed\n".utf8).base64EncodedString()]
        try JSONSerialization.data(withJSONObject: pending).write(to: root.appendingPathComponent(".ecosystem-subagents/ares-pending.json"))
        try write("# user changed\n", root: root)
        let status = try await client.status(); XCTAssertEqual(status.state, "recoveryRequired")
        do { _ = try await client.preview(connected: false); XCTFail("Чужая правка затёрта восстановлением") }
        catch CodexAdapterError.recoveryRequired {}
        do { _ = try await client.recoverConnection(); XCTFail("Восстановление затёрло чужую правку") }
        catch CodexAdapterError.recoveryRequired {}
        XCTAssertEqual(try contents(root), "# user changed\n")
    }

    func testPendingJournalRestoresRecognizedPartialWrite() async throws {
        let root = try fixture(), client = adapter(root, cli: false)
        _ = try await client.status()
        let pending: [String: Any] = ["configBefore": Data("# original\n".utf8).base64EncodedString(),
            "configAfter": Data("# partial\n".utf8).base64EncodedString()]
        try JSONSerialization.data(withJSONObject: pending).write(to: root.appendingPathComponent(".ecosystem-subagents/ares-pending.json"))
        try write("# partial\n", root: root)
        do { _ = try await client.preview(connected: false); XCTFail("Просмотр выполнил восстановление без подтверждения") }
        catch CodexAdapterError.recoveryRequired {}
        XCTAssertEqual(try contents(root), "# partial\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".ecosystem-subagents/ares-pending.json").path))
        let restored = try await client.recoverConnection()
        XCTAssertEqual(restored.state, "disconnected")
        XCTAssertEqual(try contents(root), "# original\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".ecosystem-subagents/ares-pending.json").path))
    }
    func testEscapedDuplicateAndMalformedRoleRefuseChange() async throws {
        let root = try fixture(), client = adapter(root, cli: false)
        try write("name = \"\\u0061res\"\n", root: root, path: "agents/foreign.toml")
        do { _ = try await client.preview(connected: true); XCTFail("Дубликат с Unicode escape принят") }
        catch CodexAdapterError.conflict {}
        try write("name = [broken\n", root: root, path: "agents/foreign.toml")
        do { _ = try await client.preview(connected: true); XCTFail("Повреждённая декларация роли принята") }
        catch CodexAdapterError.conflict {}
    }

    func testDifferentHelperCannotReusePreviouslyConfirmedPlan() async throws {
        try requireCLI(); let root = try fixture(), first = adapter(root)
        let plan = try await first.preview(connected: true)
        let changed = adapter(root, helper: "/usr/bin/false")
        do { _ = try await changed.apply(plan); XCTFail("План разрешил подмену команды MCP") }
        catch CodexAdapterError.stalePlan {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config.toml").path))
    }

    func testInlineEscapedForeignServerDetectedByRealCLI() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        let foreign = "mcp_servers = {\"\\u0061res\" = {command = \"/usr/bin/true\", args = []}}\n"
        try write(foreign, root: root)
        let status = try await client.status(); XCTAssertEqual(status.state, "conflict")
        do { _ = try await client.preview(connected: true); XCTFail("Чужой сервер в inline-таблице принят") }
        catch CodexAdapterError.conflict {}
        XCTAssertEqual(try contents(root), foreign)
    }

    func testDuplicateRoleAddedAfterInstallInvalidatesStatusAndDisconnect() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        _ = try await client.apply(client.preview(connected: true))
        let installed = try contents(root)
        try write("name = \"ares\"\ndescription = \"foreign duplicate\"\n", root: root, path: "agents/copy.toml")
        let status = try await client.status()
        XCTAssertFalse(status.connected); XCTAssertEqual(status.state, "conflict")
        do { _ = try await client.preview(connected: false); XCTFail("Отключение при неоднозначной роли разрешено") }
        catch CodexAdapterError.conflict {}
        XCTAssertEqual(try contents(root), installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("agents/ares.toml").path))
    }

    func testPreviewRejectsChangesMadeDuringRealCLIValidation() async throws {
        try requireCLI(); let root = try fixture()
        let gate = root.appendingPathComponent("ready"), release = root.appendingPathComponent("continue")
        let wrapper = root.appendingPathComponent("gated-codex")
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        // Обёртка синхронизирует момент внешней правки, затем передаёт всю
        // проверку настоящему CLI; ответ MCP и TOML-парсер не подменяются.
        let script = "#!/bin/sh\nprintf ready > " + quoted(gate.path)
            + "\nwhile [ ! -f " + quoted(release.path) + " ]; do /bin/sleep 0.01; done\nexec "
            + quoted(executable.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let client = CodexAdapter(configuration: .init(domain: .ares, configDirectory: root,
            helperURL: URL(fileURLWithPath: "/usr/bin/true"), codexExecutableURL: wrapper))
        try write("# initially reviewed\n", root: root)
        let preview = Task { try await client.preview(connected: true) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: gate.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Всегда освобождаем subprocess, даже если синхронизация дала сбой.
        defer { try? Data().write(to: release) }
        guard FileManager.default.fileExists(atPath: gate.path) else {
            preview.cancel(); XCTFail("CLI не дошёл до точки синхронизации"); return
        }
        try write("# edited while validation was running\n", root: root)
        try Data().write(to: release)
        do { _ = try await preview.value; XCTFail("План связался с непроверенной внешней правкой") }
        catch CodexAdapterError.stalePlan {}
        XCTAssertEqual(try contents(root), "# edited while validation was running\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("agents/ares.toml").path))
    }

    func testOwnedServerDuplicateOutsideManagedBlockInvalidatesStatus() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        _ = try await client.apply(client.preview(connected: true))
        let changed = try contents(root) + "\n[mcp_servers.'ares']\ncommand = '/usr/bin/false'\n"
        try write(changed, root: root)
        let status = try await client.status()
        XCTAssertFalse(status.connected); XCTAssertEqual(status.state, "conflict")
        XCTAssertEqual(try contents(root), changed)
    }

    func testOwnedServerInvalidForeignTOMLInvalidatesStatusThroughRealCLI() async throws {
        try requireCLI(); let root = try fixture(), client = adapter(root)
        _ = try await client.apply(client.preview(connected: true))
        let changed = try contents(root) + "\n[unclosed\n"
        try write(changed, root: root)
        let status = try await client.status()
        XCTAssertFalse(status.connected); XCTAssertEqual(status.state, "conflict")
        XCTAssertEqual(try contents(root), changed)
    }

    func testExternalSaveDuringCommitRetainsForeignBytesAndRecoveryJournal() async throws {
        try requireCLI()
        for boundary in ["role", "config", "manifest"] {
            let root = try fixture(), config = root.appendingPathComponent("config.toml")
            let original = "# initial\n", changed = Data("# external editor saved\n".utf8)
            try write(original, root: root)
            // Имитируем независимый редактор строго после fsync журнала или
            // соседнего шага записи. Нет таймеров и вероятностного попадания в окно.
            let client = CodexAdapter(configuration: .init(domain: .ares, configDirectory: root,
                helperURL: URL(fileURLWithPath: "/usr/bin/true"), codexExecutableURL: executable),
                beforeCommitWrite: { step in
                    if step == boundary { try changed.write(to: config) }
                })
            let plan = try await client.preview(connected: true)
            do { _ = try await client.apply(plan); XCTFail("Внешняя правка потеряна на шаге \(boundary)") }
            catch CodexAdapterError.recoveryRequired {}
            XCTAssertEqual(try Data(contentsOf: config), changed)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".ecosystem-subagents/ares-pending.json").path))
            let status = try await client.status()
            XCTAssertEqual(status.state, "recoveryRequired"); XCTAssertFalse(status.connected)
            do { _ = try await client.recoverConnection(); XCTFail("Чужая правка затёрта откатом") }
            catch CodexAdapterError.recoveryRequired {}
            XCTAssertEqual(try Data(contentsOf: config), changed)
        }
    }

}
