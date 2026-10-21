import Darwin
import Foundation

public struct LocalLoginStatus: Codable, Sendable {
    public let configured: Bool
    public let disabledBySystem: Bool
    public let registered: Bool
}
/// Управляет только plist своего домена из проверенного локального профиля.
/// Не выполняет команды из JSON и не включает item, отключённый пользователем ОС.
public struct LocalLoginRegistration: Sendable {
    private let profile: URL
    private let domain: String
    private let destination: URL
    public init(profile: URL, domain: String, launchAgentsDirectory: URL? = nil) {
        self.profile = profile; self.domain = domain
        // Нормализуем только домашнюю папку, которую выбрала ОС. Foundation
        // сокращает /private/tmp до /tmp в изолированных home; проверка всей
        // цепочки далее должна видеть фактический каталог, а не системный alias.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pointer = realpath(home.path, nil)
        let canonical = pointer.map { URL(fileURLWithPath: String(cString: $0)) } ?? home
        if let pointer { free(pointer) }
        destination = launchAgentsDirectory ?? canonical.appendingPathComponent("Library/LaunchAgents")
    }
    private func read(_ file: URL, privateOnly: Bool = true) throws -> Data {
        // Читаем проверенный дескриптор, а не имя после отдельного lstat.
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_size <= 1_048_576, !privateOnly || info.st_mode & 0o077 == 0
        else { throw LocalRuntimeFailure.invalidConfiguration }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 1_048_576 else { throw LocalRuntimeFailure.invalidConfiguration }
        return data
    }
    private func validateDirectory(_ directory: URL, missingAllowed: Bool = false, privateOnly: Bool = false) throws {
        var info = stat()
        let status = lstat(directory.path, &info)
        if status != 0 {
            guard missingAllowed && errno == ENOENT else { throw LocalRuntimeFailure.invalidConfiguration }
        } else {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
                  info.st_mode & (privateOnly ? 0o077 : 0o022) == 0
            else { throw LocalRuntimeFailure.invalidConfiguration }
        }
        // Владельцем / и /Users может быть root; проверяем там только отсутствие
        // ссылок. Иначе безопасный конечный каталог мог бы перенаправляться через
        // ссылочный родитель. NSString сохраняет /private/tmp, не сокращая его
        // как standardizedFileURL для существующего пути до системного /tmp.
        var ancestor = (directory.path as NSString).deletingLastPathComponent
        while !ancestor.isEmpty {
            var parentInfo = stat()
            if lstat(ancestor, &parentInfo) == 0 {
                guard parentInfo.st_mode & S_IFMT == S_IFDIR else { throw LocalRuntimeFailure.invalidConfiguration }
            } else if errno != ENOENT { throw LocalRuntimeFailure.invalidConfiguration }
            if ancestor == "/" { break }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }
    private func exists(_ file: URL) throws -> Bool {
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid()
            else { throw LocalRuntimeFailure.invalidConfiguration }
            return true
        }
        guard errno == ENOENT else { throw LocalRuntimeFailure.invalidConfiguration }
        return false
    }
    private func writeAtomic(_ bytes: Data, to file: URL) throws {
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        defer { close(parent) }
        let temporary = ".ecosystem-login-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalRuntimeFailure.operationFailed }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LocalRuntimeFailure.operationFailed }
                offset += count
            }
        }
        // Данные и запись каталога фиксируются до успешного ответа GUI.
        guard fsync(fd) == 0, renameat(parent, temporary, parent, file.lastPathComponent) == 0,
              fsync(parent) == 0 else { throw LocalRuntimeFailure.operationFailed }
    }
    private func inputs() throws -> ([String: Any], String, Data) {
        try validateDirectory(profile, privateOnly: true)
        guard ["ares", "athena"].contains(domain),
              var marker = try JSONSerialization.jsonObject(with: read(profile.appendingPathComponent("profile.json"))) as? [String: Any],
              marker["version"] as? Int == 1, marker["uid"] as? Int == Int(geteuid()),
              let agents = marker["agents"] as? [String: [String: Any]], let item = agents[domain],
              let label = item["label"] as? String,
              label.range(of: "^local\\.ecosystem\\." + domain + "\\." + String(geteuid()) + "\\.[0-9a-f]{32}$", options: .regularExpression) != nil,
              let runtime = item["runtime"] as? String, runtime.hasPrefix(profile.path + "/"),
              !runtime.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              URL(fileURLWithPath: runtime).resolvingSymlinksInPath().path.hasPrefix(profile.resolvingSymlinksInPath().path + "/"),
              let config = item["configuration"] as? String, config == profile.appendingPathComponent(domain + ".json").path else { throw LocalRuntimeFailure.invalidConfiguration }
        let bytes = try read(profile.appendingPathComponent(domain + ".plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              plist["Label"] as? String == label, plist["ProgramArguments"] as? [String] == [runtime, "--config", config] else { throw LocalRuntimeFailure.invalidConfiguration }
        marker["persistent"] = marker["persistent"] ?? [String: String]()
        return (marker, label, bytes)
    }
    private func launchctl(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        let out = Pipe(); process.standardOutput = out; process.standardError = FileHandle.nullDevice
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
    static func systemDisabled(_ text: String, label: String) throws -> Bool {
        // Новые macOS печатают enabled/disabled, прежние — true/false.
        // Неизвестное значение своего item не принимаем за разрешённый запуск.
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "\"" + escaped + "\"\\s*=>\\s*(true|false|enabled|disabled)\\b"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, range: range), let value = Range(match.range(at: 1), in: text) {
            return ["true", "disabled"].contains(String(text[value]))
        }
        guard !text.contains("\"" + label + "\"") else { throw LocalRuntimeFailure.invalidConfiguration }
        return false
    }
    public func status() throws -> LocalLoginStatus {
        let (marker, label, bytes) = try inputs()
        let target = destination.appendingPathComponent(label + ".plist")
        let mapping = marker["persistent"] as? [String: String] ?? [:]
        try validateDirectory(destination, missingAllowed: true)
        let exists = try exists(target)
        if exists { guard try read(target, privateOnly: false) == bytes else { throw LocalRuntimeFailure.invalidConfiguration } }
        let disabled = try launchctl(["print-disabled", "gui/\(geteuid())"])
        guard disabled.0 == 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        return LocalLoginStatus(configured: exists && mapping[domain] == destination.path,
                               disabledBySystem: try Self.systemDisabled(disabled.1, label: label),
                               registered: try launchctl(["print", "gui/\(geteuid())/" + label]).0 == 0)
    }
    public func setEnabled(_ enabled: Bool) throws -> LocalLoginStatus {
        // Два независимых runtime обновляют разные ключи общего маркера.
        // flock исключает потерю выбора другого агента без общей службы-владельца.
        try validateDirectory(profile, privateOnly: true)
        let lock = open(profile.appendingPathComponent(".persistence.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }; defer { close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == geteuid(), lockInfo.st_nlink == 1, lockInfo.st_mode & 0o077 == 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw LocalRuntimeFailure.busy }
        defer { flock(lock, LOCK_UN) }
        return try setEnabledWithPersistenceLockHeld(enabled)
    }
    /// Внутренний вариант нужен cold maintenance: он уже держит тот же flock.
    /// Повторное открытие lock-файла здесь заблокировало бы собственную операцию.
    func setEnabledWithPersistenceLockHeld(_ enabled: Bool) throws -> LocalLoginStatus {
        var (marker, label, bytes) = try inputs()
        let target = destination.appendingPathComponent(label + ".plist")
        // Перед изменением проверяем чужой файл. Системный запрет не снимается.
        let current = try status()
        guard !enabled || !current.disabledBySystem else { throw LocalRuntimeFailure.denied }
        if enabled {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try validateDirectory(destination)
            try writeAtomic(bytes, to: target)
        } else if try exists(target) {
            let parent = open(destination.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
            defer { close(parent) }
            guard unlinkat(parent, target.lastPathComponent, 0) == 0, fsync(parent) == 0 else { throw LocalRuntimeFailure.operationFailed }
        }
        var mapping = marker["persistent"] as? [String: String] ?? [:]
        if enabled { mapping[domain] = destination.path } else { mapping.removeValue(forKey: domain) }
        marker["persistent"] = mapping
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys, .prettyPrinted])
        let file = profile.appendingPathComponent("profile.json")
        try writeAtomic(data, to: file)
        // Действующий runtime не останавливается при снятии автозапуска.
        // Runtime уже зарегистрирован launcher; новый plist нужен следующему входу.
        return try status()
    }
}
