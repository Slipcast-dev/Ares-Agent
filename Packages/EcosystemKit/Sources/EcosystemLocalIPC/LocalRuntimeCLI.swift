import Foundation
import Darwin
import EcosystemRuntimeSupport

/// Узкий диагностический клиент. По умолчанию launcher НЕ включает runtime
/// executable в allowlist GUI/MCP/worker; smoke делает это только в test profile.
public enum LocalRuntimeCLI {
    public static func clientIfRequested(domain: String) throws -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "--client" else { return false }
        guard args.count == 5, args[1] == "--config", args[3] == "--role",
              let role = LocalRole(rawValue: args[4]) else { throw LocalRuntimeFailure.invalidConfiguration }
        let config = try LocalRuntimeConfiguration.load(URL(fileURLWithPath: args[2]), domain: domain)
        var input = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: min(65_536, LocalWire.maximumRequestBytes + 1 - input.count)), !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= LocalWire.maximumRequestBytes else { throw LocalRuntimeFailure.invalidRequest }
        }
        guard !input.isEmpty else { throw LocalRuntimeFailure.invalidRequest }
        let store = CLIResult()
        Task.detached {
            do { store.finish(.success(try await LocalRPCClient(configuration: config, role: role).exchange(input))) }
            catch { store.finish(.failure(error)) }
        }
        guard store.semaphore.wait(timeout: .now() + 8) == .success else { throw LocalRuntimeFailure.unavailable }
        FileHandle.standardOutput.write(try store.read().get() + Data([10]))
        return true
    }
    /// Fault injection доступен только из env тестового launcher и только для
    /// собственного синтетического /private/tmp профиля. MCP не имеет такого поля.
    public static func faultForSyntheticProfile(_ file: URL) throws -> (@Sendable (QueueFaultPoint) throws -> Void)? {
        guard let raw = ProcessInfo.processInfo.environment["ECOSYSTEM_LOCAL_TEST_CRASH"] else { return nil }
        let marker = file.deletingLastPathComponent().appendingPathComponent("profile.json")
        var info = stat()
        guard file.path.hasPrefix("/private/tmp/ecosystem-e3b-"),
              lstat(marker.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size <= 1_048_576, let point = QueueFaultPoint(rawValue: raw),
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any],
              value["testProfile"] as? Bool == true else { throw LocalRuntimeFailure.invalidConfiguration }
        return { actual in if actual == point { _exit(70) } }
    }
    public static func configurationFile(arguments args: [String] = Array(CommandLine.arguments.dropFirst())) throws -> URL {
        guard args.count == 2, args[0] == "--config", args[1].hasPrefix("/") else { throw LocalRuntimeFailure.invalidConfiguration }
        let file = URL(fileURLWithPath: args[1])
        // LaunchAgents запускает runtime напрямую, минуя GUI bootstrap. После
        // crash незавершённой замены этот вход также обязан отказать до recover.
        try InstalledRuntimeMaintenance.requireNoInterruptedTransaction(profile: file.deletingLastPathComponent())
        return file
    }
}
private final class CLIResult: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Data, Error> = .failure(LocalRuntimeFailure.unavailable)
    func finish(_ value: Result<Data, Error>) { lock.lock(); result = value; lock.unlock(); semaphore.signal() }
    func read() -> Result<Data, Error> { lock.lock(); defer { lock.unlock() }; return result }
}

/// Только SIGTERM собственного runtime (launchctl bootout). Сначала просим
/// кооперативную остановку; watchdog ограничивает syscall, который не отменяется.
public enum LocalRuntimeTermination {
    public static func install(shutdown: @escaping @Sendable () async -> Void) -> DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler {
            Task.detached { try? await Task.sleep(nanoseconds: 4_000_000_000); _exit(0) }
            Task { await shutdown(); _exit(0) }
        }
        source.resume()
        return source
    }
}
