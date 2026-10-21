import Darwin
import EcosystemContracts
import Foundation
import XCTest
@testable import EcosystemRuntimeSupport

/// SQLITE_FULL от настоящего ограниченного тома дополняет max_page_count тест:
/// проверяет WAL/rollback и продолжение работы после освобождения места.
final class QueuePhysicalFullTests: XCTestCase {
    private func hdi(_ args: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "QueueOwnedVolume", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]) }
    }
    private func submission(_ key: String, large: Bool = false) throws -> QueueSubmission {
        let request = try TaskRequest(requestID: UUID(), agentID: .athena, capabilityID: "system.get_info",
            parameters: ["fixture": large ? String(repeating: "q", count: 128 * 1024) : "small"], origin: .user,
            idempotencyKey: key, createdAt: UTCTimestamp("2026-10-19T12:00:00Z"))
        return try QueueSubmission(request: request, resources: ["fixture." + key], mutating: false)
    }
    func testPhysicalENOSPCRollsBackAdmissionAndPreservesCommittedTaskAfterFreeingSpace() async throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/ecosystem-queue-full-" + UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: base) }
        let mount = base.appendingPathComponent("volume"), image = base.appendingPathComponent("limited.sparseimage")
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        try hdi(["create", "-size", "128m", "-type", "SPARSE", "-fs", "HFS+", "-volname", "E13QueueFull", image.path])
        try hdi(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? hdi(["detach", "-force", mount.path]) }
        var host = stat(), volume = stat()
        guard lstat(base.path, &host) == 0, lstat(mount.path, &volume) == 0, host.st_dev != volume.st_dev else { return XCTFail("Not a separate mounted filesystem") }
        let queue = try DurableTaskQueue(directory: mount.appendingPathComponent("queue"), agentID: .athena)
        let first = try await queue.accept(submission("committed"))
        let filler = mount.appendingPathComponent("filler.bin")
        let fd = open(filler.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return XCTFail("Cannot create fixture filler") }
        let block = [UInt8](repeating: 0x46, count: 1024 * 1024)
        var full = false
        for _ in 0..<130 {
            let count = block.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if count < 0 { XCTAssertEqual(errno, ENOSPC); full = errno == ENOSPC; break }
        }
        close(fd); XCTAssertTrue(full)
        // SQLite может законно использовать уже выделенные extents WAL даже
        // после ENOSPC у filler. Наращиваем новые транзакции до фактического
        // SQLITE_FULL, сохраняя отдельно все подтверждённые commit.
        var committed: [(String, UUID)] = [("committed", first.id)]
        var failedKey: String?
        for index in 0..<128 {
            let key = "full-" + String(index)
            do {
                let task = try await queue.accept(submission(key, large: true))
                committed.append((key, task.id))
            } catch {
                XCTAssertEqual(error as? QueueFailure, .storageFull)
                failedKey = key; break
            }
        }
        guard let failedKey else { return XCTFail("No SQLite failure within bounded WAL growth") }
        try fm.removeItem(at: filler)
        let saved = try await queue.tasks(limit: 500)
        XCTAssertEqual(Set(saved.map(\.id)), Set(committed.map { $0.1 }))
        for (key, id) in committed {
            let duplicate = try await queue.accept(submission(key, large: key != "committed"))
            XCTAssertEqual(duplicate.id, id)
        }
        let next = try await queue.accept(submission(failedKey, large: true))
        XCTAssertFalse(committed.contains { $0.1 == next.id })
        let after = try await queue.tasks(limit: 500); XCTAssertEqual(after.count, committed.count + 1)
        // Очередь удерживает fd до окончания проверок; force detach допустим
        // лишь для этого собственного временного образа, никогда для user disks.
        withExtendedLifetime(queue) {}
    }
}
