import Darwin
import Foundation
import XCTest
@testable import FileOrganizerCore

/// Реальные ошибки ядра, не mock errno и не заполнение системного диска.
/// Единственный образ ограничен 128 MiB; cleanup адресует только собственный том.
final class StorageFailureTests: XCTestCase {
    private let fm = FileManager.default
    private func command(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "OwnedVolumeFixture", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
    }
    func testRealENOSPCAfterPreflightLeavesNoPublishedCopyAndCanRetryExplicitly() throws {
        let base = URL(fileURLWithPath: "/private/tmp/ecosystem-storage-unit-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        let image = base.appendingPathComponent("limited.sparseimage")
        let mount = base.appendingPathComponent("volume")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        try command(["create", "-size", "128m", "-type", "SPARSE", "-fs", "HFS+", "-volname", "E13OwnedFull", image.path])
        try command(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? command(["detach", mount.path]) }
        // Нельзя случайно писать filler на системную ФС при ошибке attach.
        var host = stat(), volume = stat()
        XCTAssertEqual(lstat(base.path, &host), 0); XCTAssertEqual(lstat(mount.path, &volume), 0)
        guard host.st_dev != volume.st_dev else { return XCTFail("Fixture is not a mounted volume") }
        let source = base.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        let original = Data(repeating: 0x6b, count: 1024 * 1024)
        try original.write(to: source.appendingPathComponent("original.bin"))
        let version = try VerifiedFileReader.capture(root: source, relative: "original.bin")
        let filler = mount.appendingPathComponent("filler.bin")
        var observedFull = false
        XCTAssertThrowsError(try SecureRuleIO.copy(root: source, relative: "original.bin", version: version,
            destinationRoot: mount, name: "copy.bin", beforeTransfer: {
                let fd = open(filler.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw RuleExecutionError.verificationFailed }; defer { close(fd) }
                let bytes = [UInt8](repeating: 0x39, count: 1024 * 1024)
                // Верхняя граница не даёт ошибке fixture заполнить основной диск.
                for _ in 0..<130 {
                    let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    if count < 0 {
                        guard errno == ENOSPC else { throw RuleExecutionError.verificationFailed }
                        observedFull = true; break
                    }
                }
                XCTAssertTrue(observedFull)
            }))
        XCTAssertTrue(observedFull)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("original.bin")), original)
        XCTAssertFalse(fm.fileExists(atPath: mount.appendingPathComponent("Ares Results/copy.bin").path))
        try fm.removeItem(at: filler)
        let leftovers = try fm.contentsOfDirectory(atPath: mount.appendingPathComponent("Ares Results").path)
        XCTAssertEqual(leftovers, [])
        try SecureRuleIO.copy(root: source, relative: "original.bin", version: version, destinationRoot: mount, name: "copy.bin")
        XCTAssertEqual(try Data(contentsOf: mount.appendingPathComponent("Ares Results/copy.bin")), original)
    }
    func testForcedDetachBeforePublishDoesNotWriteToReplacementVolumePath() throws {
        let base = URL(fileURLWithPath: "/private/tmp/ecosystem-detach-unit-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        let mount = base.appendingPathComponent("volume"), image = base.appendingPathComponent("limited.sparseimage")
        let source = base.appendingPathComponent("source")
        for directory in [mount, source] { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
        try command(["create", "-size", "128m", "-type", "SPARSE", "-fs", "HFS+", "-volname", "E13DetachCopy", image.path])
        try command(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        var mounted = true
        defer { if mounted { try? command(["detach", "-force", mount.path]) } }
        var host = stat(), volume = stat()
        guard lstat(base.path, &host) == 0, lstat(mount.path, &volume) == 0, host.st_dev != volume.st_dev else { return XCTFail("Not an owned volume") }
        let original = Data(repeating: 0x71, count: 1024 * 1024)
        try original.write(to: source.appendingPathComponent("a.bin"))
        let version = try VerifiedFileReader.capture(root: source, relative: "a.bin")
        let resultFolder = mount.appendingPathComponent("Ares Results")
        XCTAssertThrowsError(try SecureRuleIO.copy(root: source, relative: "a.bin", version: version,
            destinationRoot: mount, name: "copy.bin", beforePublish: {
                // Принудительно снимаем только свой образ при живых fd. Это
                // моделирует исчезновение устройства на границе fsync/rename.
                try self.command(["detach", "-force", mount.path]); mounted = false
                try self.fm.createDirectory(at: resultFolder, withIntermediateDirectories: true)
            }))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: resultFolder.path), [])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("a.bin")), original)
        try fm.removeItem(at: resultFolder)
        try command(["attach", "-nobrowse", "-mountpoint", mount.path, image.path]); mounted = true
        XCTAssertFalse(fm.fileExists(atPath: resultFolder.appendingPathComponent("copy.bin").path))
        // После возврата тома не выполняем прежнее действие автоматически.
        // Новый явный вызов создаёт отдельный проверенный результат.
        try SecureRuleIO.copy(root: source, relative: "a.bin", version: version, destinationRoot: mount, name: "explicit.bin")
        XCTAssertEqual(try Data(contentsOf: resultFolder.appendingPathComponent("explicit.bin")), original)
    }
    func testPOSIXRevocationBeforePublishCannotPublishOrAlterOriginal() throws {
        let base = URL(fileURLWithPath: "/private/tmp/ecosystem-permission-unit-" + UUID().uuidString)
        let source = base.appendingPathComponent("source"), target = base.appendingPathComponent("target")
        for directory in [source, target] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { chmod(target.path, 0o700); try? fm.removeItem(at: base) }
        try Data("preserved".utf8).write(to: source.appendingPathComponent("a.txt"))
        let version = try VerifiedFileReader.capture(root: source, relative: "a.txt")
        XCTAssertThrowsError(try SecureRuleIO.copy(root: source, relative: "a.txt", version: version,
            destinationRoot: target, name: "copy.txt", beforePublish: { XCTAssertEqual(chmod(target.path, 0), 0) }))
        XCTAssertEqual(chmod(target.path, 0o700), 0)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("a.txt")), Data("preserved".utf8))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("Ares Results/copy.txt").path))
        // Это POSIX EACCES. Он не подменяет ручной отзыв TCC в настройках macOS.
    }
}
