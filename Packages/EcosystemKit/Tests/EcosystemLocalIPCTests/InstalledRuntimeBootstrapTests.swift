import Darwin
import Foundation
import XCTest
@testable import EcosystemLocalIPC

final class InstalledRuntimeBootstrapTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ecosystem-installed-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func application(_ domain: String = "ares") throws -> URL {
        let product = try InstalledRuntimeBootstrap.Product(domain: domain)
        let app = root.appendingPathComponent(product.name + ".app")
        let mac = app.appendingPathComponent("Contents/MacOS")
        let runtime = app.appendingPathComponent("Contents/Library/LoginItems/" + product.name + "Background.app/Contents/MacOS")
        for directory in [mac, runtime] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // Настоящий Mach-O и codesign проверяют реальную границу идентичностей;
        // заглушка системного API скрыла бы одинаковые pins двух MCP-клиентов.
        for (directory, name) in [(mac, product.gui), (mac, product.mcp), (runtime, product.runtime)] + (product.worker.map { [(mac, $0)] } ?? []) {
            let target = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: target)
        }
        return app
    }
    private var profile: URL { root.appendingPathComponent("private/Runtime") }

    /// Проверяем расположение ресурсов именно для внешних MCP executable.
    func testProvisionCopiesStandaloneLocalizationResources() throws {
        let app = try application("athena")
        let name = "EcosystemKit_EcosystemLocalization.bundle"
        let resource = app.appendingPathComponent("Contents/Resources/" + name)
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        try Data("localized-content".utf8).write(to: resource.appendingPathComponent("fixture.txt"))
        try InstalledRuntimeBootstrap.prepare(domain: "athena", application: app, profile: profile)
        XCTAssertEqual(try String(contentsOf: profile.appendingPathComponent(name + "/fixture.txt"), encoding: .utf8), "localized-content")
    }

    func testProvisionSeparatesClientsAndDoesNotGrantDataAccess() throws {
        let app = try application()
        let file = try InstalledRuntimeBootstrap.prepare(domain: "ares", application: app, profile: profile)
        let config = try LocalRuntimeConfiguration.load(file, domain: "ares")
        XCTAssertNotEqual(config.endpoints["mcp.codex"]?.clientRequirement, config.endpoints["mcp.deepseekHarness"]?.clientRequirement)
        XCTAssertNotEqual(config.endpoints["gui"]?.clientRequirement, config.endpoints["mcp.codex"]?.clientRequirement)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.appendingPathComponent("ares-state").path))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(try InstalledRuntimeBootstrap.prepare(domain: "ares", application: app, profile: profile), file)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testAthenaProfileContainsOnlyAthenaAndNoSourcePaths() throws {
        let file = try InstalledRuntimeBootstrap.prepare(domain: "athena", application: application("athena"), profile: profile)
        let config = try LocalRuntimeConfiguration.load(file, domain: "athena")
        XCTAssertEqual(config.domain, "athena")
        let wrapper = try String(contentsOf: profile.appendingPathComponent("athena-codex-mcp.command"))
        XCTAssertTrue(wrapper.contains("MacAssistantMCP-codex"))
        XCTAssertFalse(wrapper.contains(".build"))
        XCTAssertThrowsError(try LocalRuntimeConfiguration.load(file, domain: "ares"))
    }
    func testForeignProfileIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sentinel = profile.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try InstalledRuntimeBootstrap.prepare(domain: "ares", application: application(), profile: profile))
        XCTAssertEqual(try String(contentsOf: sentinel), "keep")
    }
    func testSymlinkParentIsRejectedBeforeCreatingFiles() throws {
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("private"), withDestinationURL: target)
        XCTAssertThrowsError(try InstalledRuntimeBootstrap.prepare(domain: "ares", application: application(), profile: profile))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }
    func testChangedGUIFailsClosedAndPreservesState() throws {
        let app = try application()
        _ = try InstalledRuntimeBootstrap.prepare(domain: "ares", application: app, profile: profile)
        let file = profile.appendingPathComponent("ares.json")
        let before = try Data(contentsOf: file)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--identifier", "changed.gui", app.appendingPathComponent("Contents/MacOS/FileOrganizer").path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try InstalledRuntimeBootstrap.prepare(domain: "ares", application: app, profile: profile))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testTamperedRuntimeIsRejectedOnRepeat() throws {
        let app = try application()
        _ = try InstalledRuntimeBootstrap.prepare(domain: "ares", application: app, profile: profile)
        let runtime = profile.appendingPathComponent("AresBackground.app/Contents/MacOS/AresRuntime")
        let handle = try FileHandle(forWritingTo: runtime)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertThrowsError(try InstalledRuntimeBootstrap.prepare(domain: "ares", application: app, profile: profile))
    }
    func testUnknownDomainDoesNotCreateProfile() throws {
        XCTAssertThrowsError(try InstalledRuntimeBootstrap.prepare(domain: "other", application: root, profile: profile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
    }
}
