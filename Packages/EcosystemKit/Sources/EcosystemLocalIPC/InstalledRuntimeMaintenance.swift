import CryptoKit
import Darwin
import Foundation
import SQLite3

/// Холодное обслуживание одного standalone-профиля. Оно не выдаёт grants,
/// не переносит TCC/Keychain и никогда не меняет номер SQLite-схемы.
/// Зарегистрированную службу необходимо штатно остановить до обслуживания.
public enum InstalledRuntimeMaintenance {
    public enum Failure: LocalizedError {
        case busy, changedData, damagedBackup, interrupted, incompatible
        public var errorDescription: String? {
            switch self {
            case .busy: return "Служба работает или профиль занят. Остановите именно эту службу перед обслуживанием."
            case .changedData: return "Откат запрещён: после резервного копирования изменились данные, очередь или разрешения. Новая работа сохранена."
            case .damagedBackup: return "Резервная копия не прошла проверку владельца, состава или SHA-256."
            case .interrupted: return "Обслуживание прервано. Выполните проверенное восстановление журнала перед запуском службы."
            case .incompatible: return "Неизвестная или повреждённая схема базы. Исходный профиль сохранён."
            }
        }
    }
    struct Entry: Codable, Equatable {
        let path: String
        let mode: UInt16
        let digest: String?
    }
    struct Manifest: Codable {
        let version: Int
        let domain: String
        let uid: UInt32
        let profile: String
        let entries: [Entry]
        let state: [Entry]
    }
    struct Journal: Codable {
        let version: Int
        let domain: String
        let before: [Entry]
        let after: [Entry]
        let retained: String
    }
    private static let fm = FileManager.default
    // Только эти имена относятся к коду. Остальные файлы, включая новые
    // хранилища будущих версий, считаются данными и защищены от отката.
    private static func managed(_ domain: String) throws -> Set<String> {
        let p = try InstalledRuntimeBootstrap.Product(domain: domain)
        var names = [p.name + "Background.app", "profile.json", domain + ".plist",
                     domain + ".json", domain + "-mcp.command"]
        for client in ["codex", "deepseekHarness"] {
            names += [domain + "-" + client + ".json", domain + "-" + client + "-mcp.command"]
        }
        for client in ["legacy", "codex", "deepseekHarness"] { names.append(p.mcp + "-" + client) }
        if let worker = p.worker { names.append(worker) }
        return Set(names)
    }
    private static func journalURL(_ profile: URL) -> URL {
        profile.deletingLastPathComponent().appendingPathComponent(".maintenance-" + profile.lastPathComponent + ".json")
    }
    static func requireNoInterruptedTransaction(profile: URL) throws {
        var info = stat()
        guard lstat(journalURL(profile).path, &info) != 0, errno == ENOENT else { throw Failure.interrupted }
    }

    /// Копия включает все sidecar SQLite, bookmarks, политики, очереди и код.
    /// Данные не попадают в stdout или общую диагностическую сводку.
    @discardableResult
    public static func backup(domain: String, profile: URL) throws -> URL {
        try exclusive(domain: domain, profile: profile) {
            try requireNoInterruptedTransaction(profile: profile)
            return try snapshot(domain: domain, profile: profile)
        }
    }

    /// Подготовка удаления сохраняет весь профиль и резервную копию. Само .app
    /// удаляется пользователем после выхода из GUI. Занятый runtime не убиваем:
    /// незавершённая операция должна штатно закончиться до cold maintenance.
    /// Снимаем только собственный login item; grants/очередь/настройки остаются.
    @discardableResult
    public static func prepareUninstall(domain: String, profile: URL) throws -> URL {
        try exclusive(domain: domain, profile: profile) {
            try requireNoInterruptedTransaction(profile: profile)
            let checkpoint = try snapshot(domain: domain, profile: profile)
            let before = try state(inventory(profile), domain: domain)
            _ = try LocalLoginRegistration(profile: profile, domain: domain)
                .setEnabledWithPersistenceLockHeld(false)
            guard try state(inventory(profile), domain: domain) == before else { throw Failure.changedData }
            return checkpoint
        }
    }

    /// Подготовка нового поколения не касается state. Метки служб и абсолютные
    /// wrapper-пути сохраняются, поэтому настройки Codex/Harness не переписываются.
    @discardableResult
    public static func upgrade(domain: String, application: URL, profile: URL) throws -> URL {
        try exclusive(domain: domain, profile: profile) {
            try requireNoInterruptedTransaction(profile: profile)
            let checkpoint = try snapshot(domain: domain, profile: profile)
            let before = try inventory(profile)
            let marker = try InstalledRuntimeBootstrap.readObject(profile.appendingPathComponent("profile.json"))
            guard let identifier = marker["identifier"] as? String,
                  identifier.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { throw Failure.damagedBackup }
            let parent = profile.deletingLastPathComponent()
            let stage = parent.appendingPathComponent(".upgrade-" + UUID().uuidString)
            let code = parent.appendingPathComponent(".code-" + UUID().uuidString)
            defer { try? fm.removeItem(at: stage); try? fm.removeItem(at: code) }
            try fm.copyItem(at: profile, to: stage)
            try InstalledRuntimeBootstrap.secureDirectory(code, create: true)
            try InstalledRuntimeBootstrap.stage(domain: domain, application: application, profile: profile, staging: code, identifier: identifier)
            let generated = try InstalledRuntimeBootstrap.readObject(code.appendingPathComponent("profile.json"))
            var newMarker = marker
            newMarker["agents"] = generated["agents"]
            // Автозапуск — отдельный opt-in. Старый launchd plist остаётся
            // байтово тем же, а запись о согласии не исчезает при смене кода.
            newMarker["persistent"] = marker["persistent"] ?? [String: String]()
            try fm.removeItem(at: code.appendingPathComponent("profile.json"))
            try InstalledRuntimeBootstrap.writeJSON(newMarker, code.appendingPathComponent("profile.json"))
            for name in try managed(domain) {
                let destination = stage.appendingPathComponent(name)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: code.appendingPathComponent(name), to: destination)
            }
            let after = try inventory(stage)
            guard try state(before, domain: domain) == state(after, domain: domain),
                  try Data(contentsOf: profile.appendingPathComponent(domain + ".plist")) == Data(contentsOf: stage.appendingPathComponent(domain + ".plist")) else { throw Failure.changedData }
            try verifyDatabases(stage)
            try exchange(domain: domain, profile: profile, stage: stage, before: before, after: after)
            return checkpoint
        }
    }

    /// Консервативный rollback: после любого изменения данных требуется
    /// roll-forward/отдельная миграция. В частности, отзыв grants нельзя отменить
    /// восстановлением старой политики, даже если старая версия умеет читать БД.
    public static func rollback(domain: String, profile: URL, checkpoint: URL) throws {
        try exclusive(domain: domain, profile: profile) {
            try requireNoInterruptedTransaction(profile: profile)
            let manifest = try loadCheckpoint(checkpoint, domain: domain, profile: profile)
            let before = try inventory(profile)
            let currentMarker = try InstalledRuntimeBootstrap.readObject(profile.appendingPathComponent("profile.json"))
            let oldMarker = try InstalledRuntimeBootstrap.readObject(checkpoint.appendingPathComponent("profile/profile.json"))
            guard NSDictionary(dictionary: currentMarker["persistent"] as? [String: String] ?? [:]).isEqual(to: oldMarker["persistent"] as? [String: String] ?? [:]),
                  try state(before, domain: domain) == manifest.state else { throw Failure.changedData }
            _ = try snapshot(domain: domain, profile: profile) // Текущее поколение тоже остаётся восстанавливаемым.
            let stage = profile.deletingLastPathComponent().appendingPathComponent(".rollback-" + UUID().uuidString)
            defer { try? fm.removeItem(at: stage) }
            try fm.copyItem(at: checkpoint.appendingPathComponent("profile"), to: stage)
            try exchange(domain: domain, profile: profile, stage: stage, before: before, after: manifest.entries)
        }
    }

    /// После crash допустим только профиль, полностью совпавший с одним из
    /// двух fsync-поколений. Частичный/изменённый профиль остаётся заблокирован.
    public static func recover(domain: String, profile: URL) throws {
        try exclusive(domain: domain, profile: profile) {
            let file = journalURL(profile)
            let journal: Journal = try decode(file)
            guard journal.version == 1, journal.domain == domain else { throw Failure.interrupted }
            let current = try inventory(profile)
            guard current == journal.before || current == journal.after else { throw Failure.interrupted }
            let retained = URL(fileURLWithPath: journal.retained)
            guard retained.deletingLastPathComponent() == profile.deletingLastPathComponent(),
                  retained.lastPathComponent.hasPrefix(".retained-"),
                  try inventory(retained) == (current == journal.after ? journal.before : journal.after) else { throw Failure.interrupted }
            try fm.removeItem(at: file)
            try syncDirectory(profile.deletingLastPathComponent())
        }
    }

    private static func state(_ entries: [Entry], domain: String) throws -> [Entry] {
        let code = try managed(domain)
        return entries.filter { !code.contains($0.path.split(separator: "/").first.map(String.init) ?? "") }
    }

    /// Общая activation-блокировка защищает GUI prepare/start и обслуживание.
    /// flock очереди удерживается до конца операции; runtime не может стать
    /// вторым владельцем даже при неожиданном внешнем запуске executable.
    static func activation<T>(profile: URL, operation: () throws -> T) throws -> T {
        let parent = profile.deletingLastPathComponent()
        try InstalledRuntimeBootstrap.secureDirectory(parent)
        let descriptor = try lock(parent.appendingPathComponent(".activation.lock"), create: true)
        defer { close(descriptor) }
        return try operation()
    }
    private static func exclusive<T>(domain: String, profile: URL, operation: () throws -> T) throws -> T {
        _ = try InstalledRuntimeBootstrap.Product(domain: domain)
        return try activation(profile: profile) {
            try InstalledRuntimeBootstrap.secureDirectory(profile)
            let marker = try InstalledRuntimeBootstrap.readObject(profile.appendingPathComponent("profile.json"))
            guard marker["standaloneVersion"] as? Int == 1, marker["uid"] as? Int == Int(geteuid()),
                  let agents = marker["agents"] as? [String: [String: Any]], Set(agents.keys) == [domain],
                  agents[domain]?["configuration"] as? String == profile.appendingPathComponent(domain + ".json").path else { throw Failure.damagedBackup }
            let config = try LocalRuntimeConfiguration.load(profile.appendingPathComponent(domain + ".json"), domain: domain)
            try InstalledRuntimeBootstrap.validateSnapshot(InstalledRuntimeBootstrap.Product(domain: domain), profile: profile, configuration: config)
            let persistence = try lock(profile.appendingPathComponent(".persistence.lock"), create: true)
            defer { close(persistence) }
            // Сама проверка статуса валидирует label, plist и persistent target.
            guard try !LocalLoginRegistration(profile: profile, domain: domain).status().registered else { throw Failure.busy }
            let file = profile.appendingPathComponent(domain + "-state/queue/runtime-owner.lock")
            if fm.fileExists(atPath: profile.appendingPathComponent(domain + "-state/queue/tasks-v1.sqlite3").path), !fm.fileExists(atPath: file.path) { throw Failure.busy }
            let owner: Int32? = fm.fileExists(atPath: file.path) ? try lock(file) : nil
            defer { if let owner { close(owner) } }
            // Проверяем весь профиль до чтения SQLite и до создания копии.
            _ = try inventory(profile)
            return try operation()
        }
    }
    private static func lock(_ file: URL, create: Bool = false) throws -> Int32 {
        let fd = open(file.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
        guard fd >= 0 else { throw Failure.busy }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw Failure.busy }
        return fd
    }
    private static func snapshot(domain: String, profile: URL) throws -> URL {
        let entries = try inventory(profile)
        let bytes = entries.reduce(Int64(0)) { total, entry in
            total + ((try? fm.attributesOfItem(atPath: profile.appendingPathComponent(entry.path).path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
        let free = (try fm.attributesOfFileSystem(forPath: profile.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard free > bytes * 4 + 16 * 1024 * 1024 else { throw Failure.busy }
        let backups = profile.deletingLastPathComponent().appendingPathComponent("Backups")
        try InstalledRuntimeBootstrap.secureDirectory(backups, create: true)
        let output = backups.appendingPathComponent(UUID().uuidString.lowercased())
        try InstalledRuntimeBootstrap.secureDirectory(output, create: true)
        // Неполная копия не имеет manifest.json и никогда не принимается restore.
        let copy = output.appendingPathComponent("profile")
        try fm.copyItem(at: profile, to: copy)
        guard try inventory(copy) == entries, try inventory(profile) == entries else { throw Failure.changedData }
        try verifyDatabases(copy)
        try syncTree(copy)
        try encode(Manifest(version: 1, domain: domain, uid: geteuid(), profile: profile.path,
                            entries: entries, state: state(entries, domain: domain)), to: output.appendingPathComponent("manifest.json"))
        try syncDirectory(output); try syncDirectory(backups)
        return output
    }
    private static func loadCheckpoint(_ checkpoint: URL, domain: String, profile: URL) throws -> Manifest {
        try InstalledRuntimeBootstrap.secureDirectory(checkpoint)
        let manifest: Manifest = try decode(checkpoint.appendingPathComponent("manifest.json"))
        guard manifest.version == 1, manifest.domain == domain, manifest.uid == geteuid(), manifest.profile == profile.path,
              try inventory(checkpoint.appendingPathComponent("profile")) == manifest.entries,
              try state(manifest.entries, domain: domain) == manifest.state else { throw Failure.damagedBackup }
        try verifyDatabases(checkpoint.appendingPathComponent("profile"))
        return manifest
    }
    static func exchange(domain: String, profile: URL, stage: URL, before: [Entry], after: [Entry], fault: ((Bool) throws -> Void)? = nil) throws {
        guard try inventory(profile) == before, try inventory(stage) == after else { throw Failure.changedData }
        // Старый и новый inode owner-lock удерживаются одновременно: rename
        // каталога не должен открыть окно второго владельца новой очереди.
        let queueLock = stage.appendingPathComponent(domain + "-state/queue/runtime-owner.lock")
        let fd: Int32? = fm.fileExists(atPath: queueLock.path) ? try lock(queueLock) : nil
        defer { if let fd { close(fd) } }
        try syncTree(stage)
        let retained = profile.deletingLastPathComponent().appendingPathComponent(".retained-" + UUID().uuidString)
        try fm.moveItem(at: stage, to: retained)
        try encode(Journal(version: 1, domain: domain, before: before, after: after, retained: retained.path), to: journalURL(profile))
        try syncDirectory(profile.deletingLastPathComponent())
        try fault?(false)
        // APFS атомарно меняет два имени. Любая ошибка/crash сохраняет журнал;
        // GUI/launcher не запускают службу до recover с полным сравнением hash.
        guard renameatx_np(AT_FDCWD, profile.path, AT_FDCWD, retained.path, UInt32(RENAME_SWAP)) == 0 else { throw Failure.interrupted }
        try fault?(true)
        try syncDirectory(profile.deletingLastPathComponent())
        guard try inventory(profile) == after, try inventory(retained) == before else { throw Failure.interrupted }
        try fm.removeItem(at: journalURL(profile))
        try syncDirectory(profile.deletingLastPathComponent())
    }

    /// Inventory учитывает пустые каталоги и режимы доступа. Символические и
    /// жёсткие ссылки, special files и group-writable элементы не копируются.
    static func inventory(_ root: URL) throws -> [Entry] {
        try InstalledRuntimeBootstrap.secureDirectory(root)
        var enumerationFailed = false
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw Failure.damagedBackup }
        var entries: [Entry] = []
        for case let file as URL in enumerator {
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw Failure.damagedBackup }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            switch info.st_mode & S_IFMT {
            case S_IFDIR: entries.append(Entry(path: relative, mode: UInt16(info.st_mode & 0o777), digest: nil))
            case S_IFREG:
                guard info.st_nlink == 1 else { throw Failure.damagedBackup }
                let stream = try FileHandle(forReadingFrom: file); defer { try? stream.close() }
                var hash = SHA256()
                while let bytes = try stream.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
                entries.append(Entry(path: relative, mode: UInt16(info.st_mode & 0o777), digest: hash.finalize().map { String(format: "%02x", $0) }.joined()))
            default: throw Failure.damagedBackup
            }
        }
        guard !enumerationFailed else { throw Failure.damagedBackup }
        return entries.sorted { $0.path < $1.path }
    }
    private static func verifyDatabases(_ root: URL) throws {
        // Проверка идёт на дополнительной копии: SQLite mode=ro может менять
        // SHM; immutable=1 проигнорировал бы committed WAL и потому не подходит.
        let check = root.deletingLastPathComponent().appendingPathComponent(".sqlite-check-" + UUID().uuidString)
        try fm.copyItem(at: root, to: check)
        defer { try? fm.removeItem(at: check) }
        for entry in try inventory(check) where entry.digest != nil && ["sqlite", "sqlite3"].contains(URL(fileURLWithPath: entry.path).pathExtension) {
            let file = check.appendingPathComponent(entry.path)
            var handle: OpaquePointer?
            let result = sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil)
            guard result == SQLITE_OK, let db = handle else { if let handle { sqlite3_close(handle) }; throw Failure.incompatible }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.incompatible }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0), String(cString: text) == "ok",
                  sqlite3_step(statement) == SQLITE_DONE else { throw Failure.incompatible }
            if entry.path.hasSuffix("queue/tasks-v1.sqlite3") {
                var schema: OpaquePointer?
                guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &schema, nil) == SQLITE_OK, let schema else { throw Failure.incompatible }
                defer { sqlite3_finalize(schema) }
                guard sqlite3_step(schema) == SQLITE_ROW, [1, 2].contains(sqlite3_column_int(schema, 0)) else { throw Failure.incompatible }
                if sqlite3_column_int(schema, 0) == 2 {
                    var latch: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "SELECT id,stopped FROM queue_control", -1, &latch, nil) == SQLITE_OK, let latch else { throw Failure.incompatible }
                    defer { sqlite3_finalize(latch) }
                    guard sqlite3_step(latch) == SQLITE_ROW, sqlite3_column_int(latch, 0) == 1,
                          [0, 1].contains(sqlite3_column_int(latch, 1)), sqlite3_step(latch) == SQLITE_DONE else { throw Failure.incompatible }
                }
            }
        }
    }
    private static func encode<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes = try encoder.encode(value)
        guard bytes.count <= 1_048_576 else { throw Failure.damagedBackup }
        try InstalledRuntimeBootstrap.write(bytes, file)
    }
    private static func decode<T: Decodable>(_ file: URL) throws -> T {
        _ = try InstalledRuntimeBootstrap.readObject(file)
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
    }
    private static func syncTree(_ root: URL) throws {
        for entry in try inventory(root) where entry.digest != nil {
            let fd = open(root.appendingPathComponent(entry.path).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.damagedBackup }; defer { close(fd) }
            guard fsync(fd) == 0 else { throw Failure.damagedBackup }
        }
        for entry in try inventory(root).reversed() where entry.digest == nil { try syncDirectory(root.appendingPathComponent(entry.path)) }
        try syncDirectory(root)
    }
    private static func syncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.damagedBackup }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw Failure.damagedBackup }
    }
}
