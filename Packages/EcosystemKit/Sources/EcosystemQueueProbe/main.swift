import Darwin
import EcosystemContracts
import EcosystemRuntimeSupport
import Foundation

/// Диагностический executable принимает только собственные /private/tmp fixtures.
/// Ни рабочие БД, ни настройки клиентов, ни пользовательские файлы не открываются.
@main
struct EcosystemQueueProbe {
    static func main() async {
        do { try await run() }
        catch QueueFailure.ownerBusy { fputs("QUEUE_OWNER_BUSY\n", stderr); exit(73) }
        catch QueueFailure.resourceBusy { fputs("QUEUE_RESOURCE_BUSY\n", stderr); exit(74) }
        catch let failure as QueueFailure {
            // Enum не содержит путей/параметров: диагностируем тип отказа безопасно.
            fputs("QUEUE_PROBE_FAILED_\(failure)\n", stderr); exit(1)
        }
        catch { fputs("QUEUE_PROBE_FAILED\n", stderr); exit(1) }
    }
    private static func output(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count.isMultiple(of: 2) else { throw QueueFailure.invalidArgument }
        var options: [String: String] = [:]
        let allowed: Set<String> = ["--domain", "--directory", "--mode", "--crash", "--mutating", "--key", "--allow-test-effects"]
        for offset in stride(from: 0, to: args.count, by: 2) {
            guard allowed.contains(args[offset]), options[args[offset]] == nil else { throw QueueFailure.invalidArgument }
            options[args[offset]] = args[offset + 1]
        }
        guard let domain = options["--domain"].flatMap(AgentID.init(rawValue:)),
              let rawDirectory = options["--directory"], let mode = options["--mode"],
              ["run", "inspect", "hold", "admit"].contains(mode) else { throw QueueFailure.invalidArgument }
        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        // Foundation.standardizedFileURL заменяет существующий /private/tmp на
        // /tmp. Сохраняем каноническое Darwin-имя: SQLite NOFOLLOW не принимает
        // промежуточный системный symlink /tmp. Traversal запрещён отдельно.
        guard rawDirectory.hasPrefix("/private/tmp/ecosystem-e3-"),
              !rawDirectory.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              directory.path == rawDirectory else { throw QueueFailure.unsafeStorage }
        let crash = options["--crash"]
        let mutating = options["--mutating"] == "yes"
        guard options["--mutating"] == nil || ["yes", "no"].contains(options["--mutating"]!) else { throw QueueFailure.invalidArgument }
        if crash != nil || mutating {
            guard options["--allow-test-effects"] == "yes" else { throw QueueFailure.invalidArgument }
        }
        if let crash {
            guard QueueFaultPoint(rawValue: crash) != nil || ["after-effect", "after-done", "after-claim"].contains(crash) else {
                throw QueueFailure.invalidArgument
            }
        }
        let queue = try DurableTaskQueue(directory: directory, agentID: domain, fault: { point in
            if point.rawValue == crash { _exit(70) }
        })
        // Swift вправе освободить локальный actor после последнего использования.
        // Owner probe обязан держать его до окончания всего серверного сценария.
        defer { withExtendedLifetime(queue) {} }
        if mode == "hold" {
            try output(["ready": true]); try await Task.sleep(nanoseconds: 20_000_000_000); return
        }
        if mode == "inspect" {
            let values = try await queue.tasks()
            let summaries = try await values.asyncMap { value in
                ["id": value.id.uuidString, "status": value.status.rawValue,
                 "resultStored": value.result != nil, "receipts": try await queue.receipts(value.id).count,
                 "revision": value.revision] as [String: Any]
            }
            try output(["tasks": summaries, "effectExists": FileManager.default.fileExists(atPath: directory.appendingPathComponent("synthetic-output.txt").path)])
            return
        }
        let request = try TaskRequest(requestID: UUID(), agentID: domain,
            capabilityID: mutating ? (domain == .ares ? "rule.run" : "monitor.propose") : (domain == .ares ? "file.scan" : "system.get_metrics"),
            parameters: EmptyParameters(), origin: .user, idempotencyKey: options["--key"] ?? "probe",
            rootID: domain == .ares ? UUID(uuidString: "00000000-0000-0000-0000-000000000001") : nil,
            createdAt: UTCTimestamp("2026-10-15T12:00:00Z"))
        let value = try await queue.accept(QueueSubmission(request: request, resources: ["resource.probe"], mutating: mutating))
        if mode == "admit" { try output(["taskId": value.id.uuidString]); return }
        guard value.status == .queued else {
            try output(["cachedTaskId": value.id.uuidString, "status": value.status.rawValue]); return
        }
        let lease = try await queue.claim(value.id)
        if crash == "after-claim" { _exit(70) }
        if mutating {
            let receipt = try await queue.beginReceipt(lease, actionKey: "synthetic.copy")
            // Синтетический эффект не перезаписывает даже собственный fixture.
            try Data("E3 synthetic effect\n".utf8).write(to: directory.appendingPathComponent("synthetic-output.txt"), options: .withoutOverwriting)
            if crash == "after-effect" { _exit(70) }
            try await queue.completeReceipt(lease, receiptID: receipt.id, evidence: Data("verified synthetic effect".utf8))
            if crash == "after-done" { _exit(70) }
        }
        let finished = try await queue.finish(lease, status: .completed, result: Data("{}".utf8))
        try output(["taskId": finished.id.uuidString, "status": finished.status.rawValue])
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
