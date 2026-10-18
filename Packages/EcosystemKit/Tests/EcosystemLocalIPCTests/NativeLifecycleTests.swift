import AppKit
import Darwin
import XCTest
@testable import EcosystemLocalIPC

final class NativeLifecycleTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let profile: URL
        let destination: URL
        let labels: [String: String]
        func registration(_ domain: String) -> LocalLoginRegistration {
            LocalLoginRegistration(profile: profile, domain: domain, launchAgentsDirectory: destination)
        }
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func fixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("e7-lifecycle-" + UUID().uuidString)
        let profile = directory.appendingPathComponent("profile"), destination = directory.appendingPathComponent("LaunchAgents")
        for path in [directory, profile, destination] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var agents: [String: [String: Any]] = [:], labels: [String: String] = [:]
        for domain in ["ares", "athena"] {
            let runtime = profile.appendingPathComponent(domain + "-runtime").path
            let config = profile.appendingPathComponent(domain + ".json").path
            let label = "local.ecosystem." + domain + "." + String(geteuid()) + "." + identifier
            labels[domain] = label
            agents[domain] = ["label": label, "runtime": runtime, "configuration": config]
            try write(Data("{}".utf8), to: URL(fileURLWithPath: config))
            try write(Data("fixture-not-executed".utf8), to: URL(fileURLWithPath: runtime))
            let plist: [String: Any] = ["Label": label, "ProgramArguments": [runtime, "--config", config], "RunAtLoad": true]
            try write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: profile.appendingPathComponent(domain + ".plist"))
        }
        try write(JSONSerialization.data(withJSONObject: ["version": 1, "uid": Int(geteuid()), "agents": agents]), to: profile.appendingPathComponent("profile.json"))
        return Fixture(directory: directory, profile: profile, destination: destination, labels: labels)
    }
    private func marker(_ fixture: Fixture) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.profile.appendingPathComponent("profile.json"))) as? [String: Any])
    }
    func testSystemDisableOutputSupportsBothOSFormatsAndRejectsUnknownOwnValue() throws {
        let label = "local.ecosystem.ares.501.0123456789abcdef0123456789abcdef"
        for value in ["true", "disabled"] { XCTAssertTrue(try LocalLoginRegistration.systemDisabled("\"" + label + "\" => " + value, label: label)) }
        for value in ["false", "enabled"] { XCTAssertFalse(try LocalLoginRegistration.systemDisabled("\"" + label + "\" => " + value, label: label)) }
        XCTAssertFalse(try LocalLoginRegistration.systemDisabled("{}", label: label))
        XCTAssertThrowsError(try LocalLoginRegistration.systemDisabled("\"" + label + "\" => unknown", label: label))
    }
    func testIndependentLoginChoicesPreserveOtherAgentAndDatabase() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let sentinel = f.profile.appendingPathComponent("database-sentinel.sqlite")
        try write(Data("keep-local-data".utf8), to: sentinel)
        let ares = f.registration("ares"), athena = f.registration("athena")
        XCTAssertFalse(try ares.status().configured)
        XCTAssertTrue(try ares.setEnabled(true).configured)
        XCTAssertTrue(try athena.setEnabled(true).configured)
        XCTAssertFalse(try ares.setEnabled(false).configured)
        XCTAssertTrue(try athena.status().configured)
        let mapping = try marker(f)["persistent"] as? [String: String]
        XCTAssertNil(mapping?["ares"]); XCTAssertEqual(mapping?["athena"], f.destination.path)
        XCTAssertEqual(try String(contentsOf: sentinel), "keep-local-data")
        XCTAssertFalse(try ares.status().registered)
        XCTAssertFalse(try athena.status().registered)
    }
    func testForeignPlistIsRefusedWithoutChangingMarkerOrFile() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let target = f.destination.appendingPathComponent(try XCTUnwrap(f.labels["ares"]) + ".plist")
        try write(Data("foreign".utf8), to: target)
        let before = try Data(contentsOf: f.profile.appendingPathComponent("profile.json"))
        for enabled in [true, false] { XCTAssertThrowsError(try f.registration("ares").setEnabled(enabled)) }
        XCTAssertEqual(try Data(contentsOf: target), Data("foreign".utf8))
        XCTAssertEqual(try Data(contentsOf: f.profile.appendingPathComponent("profile.json")), before)
    }
    func testDanglingTargetSymlinkIsRefusedInBothDirections() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let target = f.destination.appendingPathComponent(try XCTUnwrap(f.labels["ares"]) + ".plist")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: f.directory.appendingPathComponent("missing"))
        for enabled in [true, false] { XCTAssertThrowsError(try f.registration("ares").setEnabled(enabled)) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), f.directory.appendingPathComponent("missing").path)
    }
    func testSymlinkLockAndLaunchAgentsDirectoryAreRefused() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let lock = f.profile.appendingPathComponent(".persistence.lock")
        let innocent = f.directory.appendingPathComponent("innocent")
        try write(Data("unchanged".utf8), to: innocent)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: innocent)
        XCTAssertThrowsError(try f.registration("ares").setEnabled(true))
        XCTAssertEqual(try String(contentsOf: innocent), "unchanged")
        try FileManager.default.removeItem(at: lock)
        let alias = f.directory.appendingPathComponent("LaunchAgentsAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.destination)
        let redirected = LocalLoginRegistration(profile: f.profile, domain: "ares", launchAgentsDirectory: alias)
        for enabled in [true, false] { XCTAssertThrowsError(try redirected.setEnabled(enabled)) }
        let nestedRedirected = LocalLoginRegistration(profile: f.profile, domain: "ares", launchAgentsDirectory: alias.appendingPathComponent("nested"))
        for enabled in [true, false] { XCTAssertThrowsError(try nestedRedirected.setEnabled(enabled)) }
    }
    func testHeldFlockReturnsBusyWithoutChanges() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let lock = open(f.profile.appendingPathComponent(".persistence.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(lock, 0)
        defer { flock(lock, LOCK_UN); close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let before = try Data(contentsOf: f.profile.appendingPathComponent("profile.json"))
        XCTAssertThrowsError(try f.registration("ares").setEnabled(true)) { error in
            XCTAssertEqual(error as? LocalRuntimeFailure, .busy)
        }
        XCTAssertEqual(try Data(contentsOf: f.profile.appendingPathComponent("profile.json")), before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
    }
    func testRuntimeTraversalOutsidePrivateProfileIsRejected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        var value = try marker(f)
        var agents = try XCTUnwrap(value["agents"] as? [String: [String: Any]])
        agents["ares"]?["runtime"] = f.profile.path + "/../foreign-runtime"
        value["agents"] = agents
        try write(JSONSerialization.data(withJSONObject: value), to: f.profile.appendingPathComponent("profile.json"))
        XCTAssertThrowsError(try f.registration("ares").status())
    }
    func testWakeMountAndSessionSignalsAreCoalescedAndObserverReleased() {
        let center = NotificationCenter(), count = WakeCounter()
        var observer: LocalWakeObserver? = LocalWakeObserver(center: center) { count.increment() }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.post(name: name, object: nil)
        }
        withExtendedLifetime(observer) { XCTAssertEqual(count.value(), 1) }
        observer = nil
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(count.value(), 1)
    }
}

private final class WakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
