import Foundation
import XCTest
import Yams
@testable import EcosystemClientAdapters

final class HarnessAdapterTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []; try super.tearDownWithError()
    }
    private func fixture(_ source: String? = "# foreign\n- insert:\n    - id: existing\n      name: user-plugin\n      config: {value: !!js process.env.EXAMPLE}\n") throws -> URL {
        let root = try physicalTemporaryDirectory().appendingPathComponent("ecosystem-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        roots.append(root)
        if let source { try Data(source.utf8).write(to: root.appendingPathComponent("cordis.patch.yml")) }
        return root
    }
    private func configuration(_ root: URL, _ domain: HarnessAgentDomain = .ares, version: String = HarnessPatch.supportedVersion) -> HarnessAdapterConfiguration {
        .init(domain: domain, patchURL: root.appendingPathComponent("cordis.patch.yml"), helperURL: URL(fileURLWithPath: "/usr/bin/true"), installedVersion: version)
    }
    private func adapter(_ root: URL, _ domain: HarnessAgentDomain = .ares) -> HarnessAdapter {
        HarnessAdapter(configuration: configuration(root, domain))
    }
    private func bytes(_ root: URL) throws -> Data { try Data(contentsOf: root.appendingPathComponent("cordis.patch.yml")) }

    func testRolesAndExactForeignBytesRoundTripWithoutEvaluatingJS() async throws {
        let root = try fixture(), original = try bytes(root), client = adapter(root)
        let plan = try await client.preview(connected: true)
        XCTAssertEqual(try bytes(root), original)
        let installed = try await client.apply(plan); XCTAssertTrue(installed.connected)
        XCTAssertFalse(installed.delegationVerified)
        let source = String(decoding: try bytes(root), as: UTF8.self)
        XCTAssertTrue(source.hasPrefix(String(decoding: original, as: UTF8.self)))
        let document = try XCTUnwrap(Yams.compose(yaml: source)?.sequence)
        let entry = try XCTUnwrap(document.last?["insert"]?.sequence)
        XCTAssertEqual(entry.count, 3)
        XCTAssertEqual(entry[1]["config"]?["providerName"]?.string, "ecosystem_ares")
        XCTAssertEqual(entry[2]["config"]?["provider"]?.string, "ecosystem_ares")
        XCTAssertEqual(entry[2]["config"]?["toolFilter"]?["allow"]?.sequence?.count, 32)
        XCTAssertTrue(entry[2]["config"]?["persona"]?.string?.contains("eventID и processingToken вместе") == true)
        _ = try await client.apply(client.preview(connected: false))
        XCTAssertEqual(try bytes(root), original)
    }

    func testEmptyListRestoresExactlyForBothDisconnectOrders() async throws {
        for order: [HarnessAgentDomain] in [[.ares, .athena], [.athena, .ares]] {
            let root = try fixture("# comment [] must stay\n [ ] # tail\n"), original = try bytes(root)
            let ares = adapter(root), athena = adapter(root, .athena)
            _ = try await ares.apply(ares.preview(connected: true))
            _ = try await athena.apply(athena.preview(connected: true))
            XCTAssertTrue(String(decoding: try bytes(root), as: UTF8.self).contains("# comment [] must stay"))
            for domain in order {
                let selected = adapter(root, domain)
                _ = try await selected.apply(selected.preview(connected: false))
            }
            XCTAssertEqual(try bytes(root), original)
        }
    }

    func testAbsentPatchRestoredAfterBothAgentsDisconnect() async throws {
        let root = try fixture(nil), ares = adapter(root), athena = adapter(root, .athena)
        _ = try await ares.apply(ares.preview(connected: true))
        _ = try await athena.apply(athena.preview(connected: true))
        _ = try await ares.apply(ares.preview(connected: false))
        _ = try await athena.apply(athena.preview(connected: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cordis.patch.yml").path))
    }

    func testIdempotencyDoesNotMoveOwnedBlockOrAddBackups() async throws {
        let root = try fixture(), ares = adapter(root), athena = adapter(root, .athena)
        _ = try await ares.apply(ares.preview(connected: true))
        _ = try await athena.apply(athena.preview(connected: true))
        let before = try bytes(root), plan = try await ares.preview(connected: true)
        XCTAssertTrue(plan.changes.isEmpty)
        _ = try await ares.apply(plan); XCTAssertEqual(try bytes(root), before)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".ecosystem-harness/backups").path)
        XCTAssertEqual(backups.count, 2)
    }

    func testMalformedYAMLAndAmbiguousIdentityNeverWritten() async throws {
        for source in ["- insert: wrong\n", "- insert: [broken\n", "- insert: []\n---\n- insert: []\n", "- insert:\n  - id: a\n    id: b\n", "- insert: &plugins []\n", "- insert:\n  - id: !!js process.env.NAME\n"] {
            let root = try fixture(source), client = adapter(root)
            do { _ = try await client.preview(connected: true); XCTFail("Повреждённый/неоднозначный YAML принят") } catch {}
            XCTAssertEqual(try bytes(root), Data(source.utf8))
        }
    }

    func testRepeatedForeignIdentitiesInIndependentScopesRemainByteExact() async throws {
        let source = """
        # Different scoped plugins may legitimately reuse their local IDs.
        - insert:
            - id: user-presets
              name: user-plugin
              config:
                presets:
                  - id: first
                    plugins:
                      - id: repeated
                        config: {serverName: foreign}
                  - id: second
                    plugins:
                      - id: repeated
                        config: {serverName: foreign}
        """
        let root = try fixture(source), client = adapter(root)
        let original = try bytes(root)
        _ = try await client.apply(client.preview(connected: true))
        _ = try await client.apply(client.preview(connected: false))
        XCTAssertEqual(try bytes(root), original)
    }

    func testQuotedAndFlowForeignConflictsAndLegacyServerPreserved() async throws {
        for source in ["- insert: [{id: 'ecosystem-ares-mcp'}]\n", "- insert: [{id: user, config: {serverName: 'ares'}}]\n", "- insert: [{id: user, config: {providerName: ecosystem_ares}}]\n", "- insert: [{id: user, config: {toolName: delegate_ares}}]\n"] {
            let root = try fixture(source), client = adapter(root)
            let status = try await client.status(); XCTAssertEqual(status.state, "conflict")
            do { _ = try await client.preview(connected: true); XCTFail("Чужое имя перезаписано") } catch HarnessAdapterError.conflict {}
            XCTAssertEqual(try bytes(root), Data(source.utf8))
        }
        let root = try fixture("- insert: [{id: mcp-mac-assistant, config: {serverName: mac-assistant}}]\n")
        let original = try bytes(root), athena = adapter(root, .athena)
        _ = try await athena.apply(athena.preview(connected: true))
        _ = try await athena.apply(athena.preview(connected: false))
        XCTAssertEqual(try bytes(root), original)
    }

    func testStalePlanAndUnsupportedVersionRefuseWithoutWriting() async throws {
        let root = try fixture(), client = adapter(root), plan = try await client.preview(connected: true)
        let changed = Data("# manual change\n[]\n".utf8)
        try changed.write(to: root.appendingPathComponent("cordis.patch.yml"))
        do { _ = try await client.apply(plan); XCTFail("Устаревший план принят") } catch HarnessAdapterError.stalePlan {}
        let unsupported = HarnessAdapter(configuration: configuration(root, version: "future-unverified"))
        let status = try await unsupported.status(); XCTAssertEqual(status.state, "unsupported")
        do { _ = try await unsupported.preview(connected: true); XCTFail("Непроверенная версия принята") } catch HarnessAdapterError.unsupportedVersion {}
        XCTAssertEqual(try bytes(root), changed)
    }

    func testForeignDuplicateOutsideOwnedBlockInvalidatesStatusAndIdempotentApply() async throws {
        for extra in ["- insert: [{id: external, config: {serverName: ares}}]\n",
                      "- insert: [{id: ecosystem-ares-delegate, name: external}]\n"] {
            let root = try fixture(), client = adapter(root)
            _ = try await client.apply(client.preview(connected: true))
            var changed = try bytes(root)
            changed.append(Data(extra.utf8))
            try changed.write(to: root.appendingPathComponent("cordis.patch.yml"))
            let status = try await client.status()
            XCTAssertFalse(status.connected)
            XCTAssertEqual(status.state, "conflict")
            do { _ = try await client.preview(connected: true); XCTFail("Дубликат снаружи принят") }
            catch HarnessAdapterError.conflict { }
            do { _ = try await client.preview(connected: false); XCTFail("Конфликт удалён без разбора") }
            catch HarnessAdapterError.conflict { }
            XCTAssertEqual(try bytes(root), changed)
        }
    }

    func testOwnedTamperingAndDuplicateAfterInstallConflict() async throws {
        let root = try fixture(), client = adapter(root)
        _ = try await client.apply(client.preview(connected: true))
        var text = String(decoding: try bytes(root), as: UTF8.self)
        text += "\n- insert: [{id: foreign, config: {serverName: ares}}]\n"
        try Data(text.utf8).write(to: root.appendingPathComponent("cordis.patch.yml"))
        let status = try await client.status(); XCTAssertEqual(status.state, "conflict")
        do { _ = try await client.preview(connected: false); XCTFail("Конфликтующий patch удалён") } catch {}
        XCTAssertEqual(try bytes(root), Data(text.utf8))
    }

    func testBackupPrivateAndPlanHasNoRawYAML() async throws {
        let root = try fixture(), client = adapter(root), plan = try await client.preview(connected: true)
        _ = try await client.apply(plan)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".ecosystem-harness/backups"), includingPropertiesForKeys: nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: backups[0].appendingPathComponent("restore.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let encoded = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        XCTAssertFalse(encoded.contains("EXAMPLE")); XCTAssertFalse(encoded.contains("process.env"))
    }

    func testPreviewDoesNotRecoverPendingTransactionAndExplicitRecoveryRestores() async throws {
        let root = try fixture("# old\n[]\n"), client = adapter(root)
        _ = try await client.status()
        let old = try bytes(root), partial = Data("# partial\n[]\n".utf8)
        let pending: [String: Any] = ["configBefore": old.base64EncodedString(), "configAfter": partial.base64EncodedString()]
        try JSONSerialization.data(withJSONObject: pending).write(to: root.appendingPathComponent(".ecosystem-harness/pending.json"))
        try partial.write(to: root.appendingPathComponent("cordis.patch.yml"))
        do { _ = try await client.preview(connected: true); XCTFail("Просмотр выполнил восстановление") } catch HarnessAdapterError.recoveryRequired {}
        XCTAssertEqual(try bytes(root), partial)
        _ = try await client.recoverConnection(); XCTAssertEqual(try bytes(root), old)
    }

    func testLateForeignWritePreservesJournalAndRefusesRollback() async throws {
        let root = try fixture(), changed = Data("# independently edited\n[]\n".utf8)
        let client = HarnessAdapter(configuration: configuration(root), beforeCommitWrite: { phase in
            if phase == "patch" { try changed.write(to: root.appendingPathComponent("cordis.patch.yml")) }
        })
        let plan = try await client.preview(connected: true)
        do { _ = try await client.apply(plan); XCTFail("Поздняя внешняя правка перезаписана") } catch HarnessAdapterError.recoveryRequired {}
        XCTAssertEqual(try bytes(root), changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".ecosystem-harness/pending.json").path))
        do { _ = try await client.recoverConnection(); XCTFail("Чужая правка затёрта откатом") } catch HarnessAdapterError.recoveryRequired {}
    }

    func testConcurrentPreviewsSerializeAndSecondApplyMustRefresh() async throws {
        let root = try fixture(), ares = adapter(root), athena = adapter(root, .athena)
        async let first = ares.preview(connected: true)
        async let second = athena.preview(connected: true)
        let (one, two) = try await (first, second)
        _ = try await ares.apply(one)
        do { _ = try await athena.apply(two); XCTFail("Потерялась правка другого приложения") } catch HarnessAdapterError.stalePlan {}
        _ = try await athena.apply(athena.preview(connected: true))
        let status = try await ares.status(); XCTAssertTrue(status.connected)
    }

    func testSDKNamesAndAllowlistCountsMatchPinnedContract() throws {
        XCTAssertEqual(HarnessPatch.publicToolName(server: "ares", rawName: "agent.get_status"), "mcp__ares__agent_get_status_415c8fb11ed9")
        XCTAssertEqual(HarnessPatch.publicToolName(server: "ares", rawName: "file.scan"), "mcp__ares__file_scan_b475c8641cf2")
        // Результат независимо вычислен установленным Electron/JS SDK:
        // emoji содержит две surrogate code units, затем точка даёт третью _.
        XCTAssertEqual(HarnessPatch.publicToolName(server: "ares", rawName: "x😀.y"), "mcp__ares__x___y_1e45e1a6c327")
        XCTAssertEqual(HarnessPatch.rawTools(for: .ares).count, 32)
        XCTAssertEqual(HarnessPatch.rawTools(for: .athena).count, 30)
    }

    func testSymlinkHardlinkAndWorldWritableProfileRefuse() async throws {
        let root = try fixture(nil), foreign = try fixture()
        let patch = root.appendingPathComponent("cordis.patch.yml")
        try FileManager.default.createSymbolicLink(at: patch, withDestinationURL: foreign.appendingPathComponent("cordis.patch.yml"))
        do { _ = try await adapter(root).status(); XCTFail("Symlink принят") } catch HarnessAdapterError.unsafePath {}
        try FileManager.default.removeItem(at: patch)
        try FileManager.default.linkItem(at: foreign.appendingPathComponent("cordis.patch.yml"), to: patch)
        do { _ = try await adapter(root).status(); XCTFail("Hardlink принят") } catch HarnessAdapterError.unsafePath {}
    }
    func testUnverifiedProfileAndWorldWritableDirectoryAreRejected() async throws {
        let root = try fixture()
        let unsupported = HarnessAdapter(configuration: .init(domain: .ares,
            patchURL: root.appendingPathComponent("cordis.patch.yml"),
            helperURL: URL(fileURLWithPath: "/usr/bin/true"), installedVersion: HarnessPatch.supportedVersion,
            profile: "unverified-profile"))
        let status = try await unsupported.status()
        XCTAssertFalse(status.nativeDelegation); XCTAssertEqual(status.state, "unsupported")
        do { _ = try await unsupported.preview(connected: true); XCTFail("Непроверенный профиль принят") }
        catch HarnessAdapterError.unsupportedVersion {}
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path)
        do { _ = try await adapter(root).status(); XCTFail("Общедоступный каталог принят") }
        catch HarnessAdapterError.unsafePath {}
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

}
