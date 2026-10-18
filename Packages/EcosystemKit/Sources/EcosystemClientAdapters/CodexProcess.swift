import Darwin
import Foundation

/// CLI запускается напрямую, без shell, авторизации и обращения к модели.
/// stdout используется только для разбора имён; секреты конфигурации не журналируются.
enum CodexProcess {
    static func validate(executable: URL, directory: URL) async throws -> Set<String> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp", "list", "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = directory.path
        process.environment = environment
        process.currentDirectoryURL = directory
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        let collector = BoundedCollector()
        // Каждый pipe читается независимо: переполнение stderr не блокирует stdout.
        for (handle, capture) in [(output.fileHandleForReading, true), (errors.fileHandleForReading, false)] {
            DispatchQueue.global(qos: .utility).async {
                defer { collector.finishReader() }
                while let data = try? handle.read(upToCount: 4096), !data.isEmpty {
                    collector.append(data, capture: capture)
                }
            }
        }
        defer {
            if process.isRunning {
                process.terminate()
                // В staging нет пишущей операции: при отмене не оставляем дочерний CLI.
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        do { try process.run() } catch { throw CodexAdapterError.cliUnavailable }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning {
            try Task.checkCancellation()
            guard Date() < deadline, !collector.overflow else { throw CodexAdapterError.cliValidationFailed }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let outputDeadline = Date().addingTimeInterval(2)
        while !collector.readersFinished {
            guard Date() < outputDeadline else { throw CodexAdapterError.cliValidationFailed }
            try Task.checkCancellation(); try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard process.terminationStatus == 0, !collector.overflow,
              let servers = try? JSONSerialization.jsonObject(with: collector.output) as? [[String: Any]],
              servers.allSatisfy({ $0["name"] is String }) else { throw CodexAdapterError.cliValidationFailed }
        return Set(servers.compactMap { $0["name"] as? String })
    }
}

private final class BoundedCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var readersDone = 0
    var readersFinished: Bool { lock.lock(); defer { lock.unlock() }; return readersDone == 2 }
    func finishReader() { lock.lock(); defer { lock.unlock() }; readersDone += 1 }
    private var bytes = Data()
    var overflow: Bool { lock.lock(); defer { lock.unlock() }; return count > 1_048_576 }
    var output: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    func append(_ data: Data, capture: Bool) {
        lock.lock(); defer { lock.unlock() }
        count = min(1_048_577, count + data.count)
        if capture, count <= 1_048_576 { bytes.append(data) }
    }
}
