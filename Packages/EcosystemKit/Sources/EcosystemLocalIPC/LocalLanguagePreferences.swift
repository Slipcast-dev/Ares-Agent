import Darwin
import Foundation
import EcosystemLocalization

public struct LocalLanguageStatus: Codable, Sendable, Equatable {
    public let preference: AgentLanguagePreference
    public let effectiveLanguage: AgentLanguage
    public init(preference: AgentLanguagePreference, effectiveLanguage: AgentLanguage) {
        self.preference = preference; self.effectiveLanguage = effectiveLanguage
    }
}
public struct LocalLanguageChange: Codable, Sendable {
    public let preference: AgentLanguagePreference
    public init(preference: AgentLanguagePreference) { self.preference = preference }
}

/// Отдельный sidecar профиля, не часть automation cutoff/receipts или очереди.
/// Только один runtime владеет actor; GUI записывает выбор через подписанный IPC.
public actor LocalLanguagePreferences {
    private struct Document: Codable { var version = 1; let preference: String }
    private static let filename = "language-v1.json"
    private let directory: URL
    private let preferredLanguages: @Sendable () -> [String]
    private var preference: AgentLanguagePreference

    public init(directory: URL, domain: String, preferredLanguages: (@Sendable () -> [String])? = nil) throws {
        guard ["ares", "athena"].contains(domain) else { throw LocalRuntimeFailure.invalidConfiguration }
        self.directory = directory
        self.preferredLanguages = preferredLanguages ?? {
            // Background.app имеет другой bundle ID. Читаем только AppleLanguages
            // основного GUI: отдельный per-app выбор macOS выше глобального.
            // Системные defaults не записываются и не переносятся в профиль.
            Self.systemLanguages(domain: domain, lookup: {
                UserDefaults.standard.persistentDomain(forName: $0)?["AppleLanguages"] as? [String]
            }, fallback: Locale.preferredLanguages)
        }
        let parent = try Self.openDirectory(directory); defer { close(parent) }
        let fd = openat(parent, Self.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw LocalRuntimeFailure.invalidConfiguration }
            // Старый профиль не мигрируется при чтении: отсутствие поля/файла = System.
            preference = .system
            return
        }
        let stream = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, Self.privateFile(info), (1...4096).contains(info.st_size),
              let bytes = try stream.read(upToCount: 4097), bytes.count <= 4096 else {
            throw LocalRuntimeFailure.invalidConfiguration
        }
        let value = try LocalWire.decode(Document.self, bytes, keys: ["version", "preference"])
        guard value.version == 1 else { throw LocalRuntimeFailure.invalidConfiguration }
        preference = AgentLanguagePreference(rawValue: value.preference) ?? .system
    }

    static func systemLanguages(domain: String, lookup: (String) -> [String]?, fallback: [String]) -> [String] {
        let id = domain == "ares" ? "dev.slipcast.fileorganizer" : "com.macassistant.app"
        // Не наследуем per-app override самого Background.app вместо GUI.
        return lookup(id) ?? lookup(UserDefaults.globalDomain) ?? fallback
    }

    public func status() -> LocalLanguageStatus {
        LocalLanguageStatus(preference: preference, effectiveLanguage: preference.resolve(preferredLanguages: preferredLanguages()))
    }
    public func set(_ value: AgentLanguagePreference) throws -> LocalLanguageStatus {
        guard preference != value else { return status() }
        let bytes = try LocalWire.encode(Document(preference: value.rawValue))
        let parent = try Self.openDirectory(directory); defer { close(parent) }
        var old = stat()
        let found = fstatat(parent, Self.filename, &old, AT_SYMLINK_NOFOLLOW)
        guard found == 0 ? Self.privateFile(old) : errno == ENOENT else { throw LocalRuntimeFailure.invalidConfiguration }
        let temporary = ".language-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalRuntimeFailure.operationFailed }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        // Temp создаётся сразу 0600: никакого окна с открытыми permissions перед chmod.
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LocalRuntimeFailure.operationFailed }
                offset += count
            }
        }
        guard fsync(fd) == 0, renameat(parent, temporary, parent, Self.filename) == 0 else {
            throw LocalRuntimeFailure.operationFailed
        }
        // Даже если fsync каталога даст ошибку, rename уже виден. GUI сможет
        // сверить фактическое значение чтением, не повторяя mutation.
        preference = value
        guard fsync(parent) == 0 else { throw LocalRuntimeFailure.operationFailed }
        return status()
    }
    private static func privateFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1 && info.st_mode & 0o077 == 0
    }
    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw LocalRuntimeFailure.invalidConfiguration
        }
        return fd
    }
}

public enum LocalLanguageControl {
    public static func handle(store: LocalLanguagePreferences, role: LocalRole, request: LocalRPCRequest) async throws -> Data {
        // До разбора payload/обращения к профилю: MCP и worker не читают и не
        // меняют UI preference даже при наличии broad domain grants.
        guard role == .gui else { throw LocalRuntimeFailure.denied }
        switch request.operation {
        case "language.get":
            _ = try LocalWire.decode(LocalEmpty.self, request.payload, keys: [])
            return try LocalWire.encode(await store.status())
        case "language.set":
            let change = try LocalWire.decode(LocalLanguageChange.self, request.payload, keys: ["preference"])
            return try LocalWire.encode(await store.set(change.preference))
        default: throw LocalRuntimeFailure.denied
        }
    }
}
