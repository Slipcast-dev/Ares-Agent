import EcosystemContracts
import EcosystemRuntimeSupport
import Foundation
import XCTest
@testable import EcosystemLocalIPC

private struct DomainFailure: QueueDomainError { let knownCode: KnownErrorCode }
final class LocalIPCTests: XCTestCase {
    func testDomainFailuresKeepSafeActionableCodes() {
        XCTAssertEqual(LocalRuntimeFailure.safe(DomainFailure(knownCode: .permissionDenied)), .denied)
        XCTAssertEqual(LocalRuntimeFailure.safe(DomainFailure(knownCode: .staleSnapshot)), .staleSnapshot)
        XCTAssertEqual(LocalRuntimeFailure.safe(DomainFailure(knownCode: .invalidArgument)), .invalidRequest)
        XCTAssertEqual(LocalRuntimeFailure.safe(DomainFailure(knownCode: .clientUnavailable)), .requiresGUI)
    }

    func testStrictPayloadRejectsExtraFieldsAndWrongTypes() throws {
        XCTAssertThrowsError(try LocalWire.decode(LocalTaskID.self, Data("{\"id\":\"bad\",\"role\":\"gui\"}".utf8), keys: ["id"]))
        XCTAssertThrowsError(try LocalWire.decode(LocalEmpty.self, Data("{\"path\":\"/private/data\"}".utf8), keys: []))
    }
    func testConfigurationRequiresExactPinAndPrivateFile() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/e3b-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ares.json")
        let hash = String(repeating: "a", count: 40)
        var config: [String: Any] = ["version": 1, "mode": "local-ad-hoc", "domain": "ares", "serverRequirement": "cdhash H\"" + hash + "\"",
            "endpoints": Dictionary(uniqueKeysWithValues: LocalRole.allCases.map { ($0.rawValue,
                ["service": "local.ecosystem.ares.test." + $0.rawValue, "clientRequirement": "cdhash H\"" + hash + "\""]) })]
        func write() throws {
            try JSONSerialization.data(withJSONObject: config).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try write()
        XCTAssertNoThrow(try LocalRuntimeConfiguration.load(file, domain: "ares"))
        XCTAssertThrowsError(try LocalRuntimeConfiguration.load(file, domain: "athena"))
        config["serverRequirement"] = "identifier \"untrusted\""; try write()
        XCTAssertThrowsError(try LocalRuntimeConfiguration.load(file, domain: "ares"))
        config["serverRequirement"] = "cdhash H\"" + hash + "\""; try write()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try LocalRuntimeConfiguration.load(file, domain: "ares"))
    }
    func testSafeErrorsDoNotExposeNSErrorDescription() {
        let error = NSError(domain: "private-path", code: 1, userInfo: [NSLocalizedDescriptionKey: "/private/secret"])
        XCTAssertEqual(LocalRuntimeFailure.safe(error), .operationFailed)
        XCTAssertFalse(LocalRuntimeFailure.safe(error).localizedDescription.contains("secret"))
    }
}
