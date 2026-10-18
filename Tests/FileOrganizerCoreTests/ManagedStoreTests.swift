import Foundation
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import FileOrganizerCore

final class ManagedStoreTests: XCTestCase {
    func testLegacyWritersAndSymlinkAliasCannotOpenManagedDatabase() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/e3c-store-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let state = base.appendingPathComponent("ares-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let file = state.appendingPathComponent("domain.sqlite")
        XCTAssertThrowsError(try SQLiteMigrator(databaseURL: file).migrate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try SQLiteMigrator(databaseURL: file, runtimeOwned: true).migrate()
        do { _ = try await SQLiteFileRepository(databaseURL: file).fetchRoots(); XCTFail("Legacy repository must reject") }
        catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
        let alias = base.appendingPathComponent("legacy.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        XCTAssertThrowsError(try SQLiteMigrator(databaseURL: alias).migrate())
        let hardlink = base.appendingPathComponent("hardlink.sqlite")
        try FileManager.default.linkItem(at: file, to: hardlink)
        XCTAssertThrowsError(try SQLiteMigrator(databaseURL: hardlink).migrate())
        try FileManager.default.removeItem(at: hardlink)
        let roots = try await SQLiteFileRepository(databaseURL: file, runtimeOwned: true).fetchRoots()
        XCTAssertTrue(roots.isEmpty)
    }
    func testImportedRootNeedsFreshSelectionAndKeepsIDAndRulesDisabled() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/e3c-renew-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source"), other = base.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let container = AppContainer(databaseURL: base.appendingPathComponent("test.sqlite"), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = AuthorizedRoot(displayName: "Перенесённый каталог", relativePathHint: source.path)
        try await container.fileRepository.save(root: root, bookmarkData: Data())
        do { _ = try await container.authorizedRootAccess.resolveURL(for: root); XCTFail("Empty bookmark must not grant") } catch {}
        do { _ = try await container.authorizedRootAccess.renewRoot(root.id, from: other); XCTFail("Wrong folder must not renew") } catch {}
        let renewed = try await container.authorizedRootAccess.renewRoot(root.id, from: source)
        XCTAssertEqual(renewed.id, root.id)
        let resolved = try await container.authorizedRootAccess.resolveURL(for: root)
        XCTAssertEqual(resolved.path, source.path)
        let data = try await container.fileRepository.bookmarkData(forRootID: root.id)
        XCTAssertFalse(try XCTUnwrap(data).isEmpty)
    }
    func testLegacyMigrationFixturesUseNativeSchemasAndRealModelDecoding() async throws {
        let base = URL(fileURLWithPath: "/private/tmp/e3c-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let v1 = base.appendingPathComponent("legacy-v1.sqlite")
        try SQLiteMigrator(databaseURL: v1, migrations: Array(DatabaseMigrations.all.prefix(1))).migrate()
        let v8 = base.appendingPathComponent("legacy-v8.sqlite")
        let container = AppContainer(databaseURL: v8, migrations: SQLiteMigrator(databaseURL: v8, migrations: Array(DatabaseMigrations.all.prefix(8))), allowLocalClient: false)
        try container.preparePersistentStore()
        let root = AuthorizedRoot(displayName: "Сохранённый индекс", relativePathHint: "/private/tmp/e3c-unselected-folder")
        try await container.fileRepository.save(root: root, bookmarkData: Data("synthetic-old-bookmark".utf8))
        var rule = AutomationRule(); rule.enabled = true; rule.rootID = root.id
        rule.actions = [RuleAction(kind: .log)]
        try await container.fileRepository.saveRuleObject(rule, id: rule.id.uuidString, table: .rules)
        let v9 = base.appendingPathComponent("legacy-v9.sqlite")
        try FileManager.default.copyItem(at: v8, to: v9)
        try SQLiteMigrator(databaseURL: v9, migrations: Array(DatabaseMigrations.all.prefix(9))).migrate()
        if let path = ProcessInfo.processInfo.environment["ECOSYSTEM_ARES_MIGRATION_FIXTURE_DIRECTORY"] {
            let target = URL(fileURLWithPath: path)
            guard target.path.hasPrefix("/private/tmp/ecosystem-e3c-") else { throw LocalRuntimeFailure.denied }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for file in [v1, v8, v9] {
                let destination = target.appendingPathComponent(file.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: file, to: destination)
            }
        }
        XCTAssertEqual(try container.migrations.appliedVersion(), 8)
    }
}
