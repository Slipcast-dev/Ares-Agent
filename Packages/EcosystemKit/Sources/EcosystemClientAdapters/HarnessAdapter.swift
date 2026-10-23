import CryptoKit
import Darwin
import Foundation
import EcosystemLocalization

/// Общая транзакция для одного desktop patch и двух независимых приложений.
/// YAML посторонних entries никогда не сериализуется заново; manifest хранит
/// только наши hashes и исходное представление пустого списка для обратимости.
public actor HarnessAdapter {
    private let configuration: HarnessAdapterConfiguration
    private let manager = FileManager.default
    private let beforeCommitWrite: (@Sendable (String) throws -> Void)?
    private var config: URL { configuration.patchURL }
    private var root: URL { config.deletingLastPathComponent() }
    private var state: URL { root.appendingPathComponent(".ecosystem-harness", isDirectory: true) }
    private var manifest: URL { state.appendingPathComponent("ownership.json") }
    private var journal: URL { state.appendingPathComponent("pending.json") }
    private var name: String { configuration.domain.rawValue }
    private var supported: Bool { HarnessPatch.supports(version: configuration.installedVersion) && configuration.profile == "desktop" }

    public init(configuration: HarnessAdapterConfiguration) {
        self.configuration = configuration; beforeCommitWrite = nil
    }
    /// Точка синхронизации тестов позволяет доказать отказ при внешней правке
    /// между fsync журнала и rename, не подменяя файловую систему.
    init(configuration: HarnessAdapterConfiguration, beforeCommitWrite: @escaping @Sendable (String) throws -> Void) {
        self.configuration = configuration; self.beforeCommitWrite = beforeCommitWrite
    }

    public func preview(connected: Bool) async throws -> HarnessConnectionPlan {
        let lock = try await acquireLock(); defer { release(lock) }
        guard try read(journal) == nil else { throw HarnessAdapterError.recoveryRequired }
        if connected { try requireSupported() }
        let before = try fingerprint(), snapshot = try inspect()
        let prepared = try prepare(connected: connected, snapshot: snapshot)
        guard before == (try fingerprint()) else { throw HarnessAdapterError.stalePlan }
        // Двуязычный текст относится только к новому DTO: fingerprint вычислен
        // из прежних bytes конфигурации, сохранённые планы не переписываются.
        return HarnessConnectionPlan(clientId: "deepseekHarness", domain: name,
            profile: configuration.profile, version: configuration.installedVersion, connected: connected,
            fingerprint: before, changes: prepared.changed ? [connected
                ? RuntimeLocalization.bilingual("Подключить роль %@, её отдельный MCP и provider/persona в профиле Harness.", name)
                : RuntimeLocalization.bilingual("Удалить только принадлежащие экосистеме MCP, provider и роль %@.", name)] : [],
            warnings: [RuntimeLocalization.bilingual("Модель наследуется от родительского контекста Harness; провайдер роли определяет штатное делегирование."),
                RuntimeLocalization.bilingual("Подключение не выдаёт разрешения runtime. Фильтр инструментов не является системной песочницей."),
                RuntimeLocalization.bilingual("Уже открытый чат может сохранять прежнюю конфигурацию. Реальная загрузка и делегирование проверяются отдельно.")],
            backupDirectory: prepared.changed ? state.appendingPathComponent("backups").path : nil)
    }

    public func apply(_ plan: HarnessConnectionPlan) async throws -> HarnessAdapterStatus {
        let lock = try await acquireLock(); defer { release(lock) }
        guard plan.clientId == "deepseekHarness", plan.domain == name,
              plan.profile == configuration.profile, plan.version == configuration.installedVersion,
              plan.fingerprint == (try fingerprint()) else { throw HarnessAdapterError.stalePlan }
        guard try read(journal) == nil else { throw HarnessAdapterError.recoveryRequired }
        if plan.connected { try requireSupported() }
        let snapshot = try inspect(), prepared = try prepare(connected: plan.connected, snapshot: snapshot)
        guard prepared.changed else { return try currentStatus() }
        let transaction = Journal(configBefore: snapshot.patch, registryBefore: snapshot.registry,
            configAfter: prepared.patch, registryAfter: prepared.registry)
        let data = try JSONEncoder().encode(transaction)
        guard data.count <= 4_194_304 else { throw HarnessAdapterError.invalidConfiguration }
        let backup = state.appendingPathComponent("backups/\(name)-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(backup)
        try atomicWrite(data, to: backup.appendingPathComponent("restore.json"))
        try atomicWrite(data, to: journal)
        do {
            try beforeCommitWrite?("patch")
            try requireFiles(patch: transaction.configBefore, registry: transaction.registryBefore)
            try replace(transaction.configAfter, at: config)
            try beforeCommitWrite?("registry")
            try requireFiles(patch: transaction.configAfter, registry: transaction.registryBefore)
            try replace(transaction.registryAfter, at: manifest)
            try requireFiles(patch: transaction.configAfter, registry: transaction.registryAfter)
            try removeDurably(journal)
            return try currentStatus()
        } catch {
            // Любой неизвестный текущий byte-снимок запрещает автоматический откат.
            // Журнал остаётся для отдельного явного восстановления пользователем.
            try recoverPending()
            throw error
        }
    }

    public func status() async throws -> HarnessAdapterStatus {
        let lock = try await acquireLock(); defer { release(lock) }
        return try currentStatus()
    }

    /// Preview/status не выполняют rollback. Этот метод вызывается только из
    /// отдельного действия восстановления; все текущие файлы должны совпадать
    /// с одной из двух известных версий журнала.
    public func recoverConnection() async throws -> HarnessAdapterStatus {
        let lock = try await acquireLock(); defer { release(lock) }
        try recoverPending(); return try currentStatus()
    }

    private struct Registry: Codable {
        var owners: [String: String] = [:]
        var emptyStart: Int?
        var emptyEnd: Int?
        var emptyPrefixDigest: String?
        var originalAbsent = false
    }
    private struct Snapshot { let patch: Data?; let registry: Data?; let decoded: Registry }
    private struct Prepared { let patch: Data?; let registry: Data?; let changed: Bool }
    private struct Journal: Codable {
        let configBefore: Data?; let registryBefore: Data?
        let configAfter: Data?; let registryAfter: Data?
    }
    private func inspect() throws -> Snapshot {
        let patch = try read(config), data = try read(manifest)
        let registry: Registry
        if let data {
            guard let value = try? JSONDecoder().decode(Registry.self, from: data),
                  Set(value.owners.keys).isSubset(of: ["ares", "athena"]), !value.owners.isEmpty else { throw HarnessAdapterError.conflict }
            registry = value
        } else { registry = Registry() }
        return Snapshot(patch: patch, registry: data, decoded: registry)
    }
    private func checkedText(_ snapshot: Snapshot) throws -> String {
        guard let text = String(data: snapshot.patch ?? Data(), encoding: .utf8) else { throw HarnessAdapterError.invalidConfiguration }
        _ = try HarnessPatch.inspect(snapshot.patch ?? Data())
        for domain in ["ares", "athena"] {
            let range = try blockRange(text, domain: domain)
            if let expected = snapshot.decoded.owners[domain] {
                guard let range, digest(Data(text[range].utf8)) == expected else { throw HarnessAdapterError.conflict }
            } else if range != nil { throw HarnessAdapterError.conflict }
        }
        return text
    }
    private func blockRange(_ text: String, domain: String) throws -> Range<String.Index>? {
        let start = HarnessPatch.begin(domain), finish = HarnessPatch.end(domain)
        let starts = text.components(separatedBy: start).count - 1, ends = text.components(separatedBy: finish).count - 1
        guard starts == ends, starts <= 1 else { throw HarnessAdapterError.conflict }
        guard starts == 1 else { return nil }
        guard let first = text.range(of: start), let last = text.range(of: finish), first.upperBound <= last.lowerBound else { throw HarnessAdapterError.conflict }
        return first.lowerBound..<last.upperBound
    }
    private func prepare(connected: Bool, snapshot: Snapshot) throws -> Prepared {
        var text = try checkedText(snapshot), registry = snapshot.decoded
        let range = try blockRange(text, domain: name)
        let desired = HarnessPatch.block(configuration: configuration)
        // Полный hash нашего блока не защищает от чужой одноимённой записи
        // снаружи. Проверяем её до idempotent fast-path и при status отдельно.
        var outside = text
        if let range { outside.removeSubrange(range) }
        guard !HarnessPatch.conflicts(try HarnessPatch.inspect(Data(outside.utf8)), domain: configuration.domain) else {
            throw HarnessAdapterError.conflict
        }
        if connected, let range, String(text[range]) == desired {
            // Не переносим уже существующий блок через блок другого приложения.
            return Prepared(patch: snapshot.patch, registry: snapshot.registry, changed: false)
        }
        if let range { text.removeSubrange(range) }
        guard !HarnessPatch.conflicts(try HarnessPatch.inspect(Data(text.utf8)), domain: configuration.domain) else { throw HarnessAdapterError.conflict }
        registry.owners.removeValue(forKey: name)
        if connected {
            guard manager.isExecutableFile(atPath: configuration.helperURL.path) else { throw HarnessAdapterError.invalidConfiguration }
            if registry.owners.isEmpty, snapshot.decoded.owners.isEmpty {
                let base = Data(text.utf8), normalized = try HarnessPatch.normalizeEmpty(base)
                if normalized != base {
                    let original = Array(base), stripped = Array(normalized)
                    var first = 0
                    while first < stripped.count, original[first] == stripped[first] { first += 1 }
                    guard first < original.count, original[first] == 91 else { throw HarnessAdapterError.invalidConfiguration }
                    var last = first
                    while last < stripped.count, original[last + 1] == stripped[last] { last += 1 }
                    guard original[last + 1] == 93 else { throw HarnessAdapterError.invalidConfiguration }
                    registry.emptyStart = first; registry.emptyEnd = last
                    registry.emptyPrefixDigest = digest(normalized.prefix(last))
                    text = String(decoding: normalized, as: UTF8.self)
                }
                registry.originalAbsent = snapshot.patch == nil
            }
            text += desired; registry.owners[name] = digest(Data(desired.utf8))
        } else if registry.owners.isEmpty {
            if let first = registry.emptyStart, let last = registry.emptyEnd,
               let expectedPrefix = registry.emptyPrefixDigest {
                var base = Data(text.utf8)
                guard first >= 0, first <= last, last <= base.count else { throw HarnessAdapterError.conflict }
                // Два смещения и hash заменяют копию всего чужого YAML в
                // registry; даже patch около 1 MiB помещается в журнал 4 MiB.
                if (try HarnessPatch.inspect(base)).empty, digest(base.prefix(last)) == expectedPrefix {
                    base.insert(93, at: last); base.insert(91, at: first)
                    text = String(decoding: base, as: UTF8.self)
                }
            }
        }
        let data = Data(text.utf8)
        _ = try HarnessPatch.inspect(data)
        let patch: Data? = !connected && registry.owners.isEmpty && registry.originalAbsent && data.isEmpty ? nil : data
        let encoded: Data? = registry.owners.isEmpty ? nil : try JSONEncoder().encode(registry)
        return Prepared(patch: patch, registry: encoded, changed: patch != snapshot.patch || encoded != snapshot.registry)
    }
    private func currentStatus() throws -> HarnessAdapterStatus {
        if try read(journal) != nil { return makeStatus(false, "recoveryRequired", RuntimeLocalization.bilingual("Незавершённая операция; preview не изменяет файлы.")) }
        guard supported else { return makeStatus(false, "unsupported", RuntimeLocalization.bilingual("Версия Harness не соответствует проверенному контракту %@.", HarnessPatch.contractID)) }
        do {
            let snapshot = try inspect(), text = try checkedText(snapshot)
            if snapshot.decoded.owners[name] != nil {
                var outside = text
                if let range = try blockRange(text, domain: name) { outside.removeSubrange(range) }
                guard !HarnessPatch.conflicts(try HarnessPatch.inspect(Data(outside.utf8)), domain: configuration.domain) else {
                    throw HarnessAdapterError.conflict
                }
                // Владение hash подтверждает только происхождение bytes. После
                // обновления Harness прежний блок может быть синтаксически верен,
                // но содержать удалённый контракт persona/toolFilter. Status не
                // мигрирует его молча: GUI предложит штатный preview подключения.
                guard let range = try blockRange(text, domain: name),
                      String(text[range]) == HarnessPatch.block(configuration: configuration) else {
                    return makeStatus(false, "updateRequired", RuntimeLocalization.bilingual("Настройки Harness требуют обновления для установленной версии. Нажмите «Подключить», проверьте план и подтвердите обновление."))
                }
                return makeStatus(true, "connected", RuntimeLocalization.bilingual("Роль, provider и MCP настроены в профиле; загрузка текущим чатом и делегирование проверяются отдельно."))
            }
            if HarnessPatch.conflicts(try HarnessPatch.inspect(Data(text.utf8)), domain: configuration.domain) { return makeStatus(false, "conflict", RuntimeLocalization.bilingual("Чужая запись занимает имя MCP или субагента.")) }
            return makeStatus(false, "disconnected", RuntimeLocalization.bilingual("Роль не подключена в выбранном профиле Harness."))
        } catch HarnessAdapterError.conflict { return makeStatus(false, "conflict", RuntimeLocalization.bilingual("Управляемый блок изменён или имя занято. Чужие настройки не перезаписаны.")) }
    }
    private func makeStatus(_ connected: Bool, _ state: String, _ detail: String) -> HarnessAdapterStatus {
        HarnessAdapterStatus(clientId: "deepseekHarness", domain: name, profile: configuration.profile,
            version: configuration.installedVersion, connected: connected, state: state, detail: detail,
            localMCP: supported, nativeDelegation: supported, delegationVerified: false)
    }
    private func requireSupported() throws { guard supported else { throw HarnessAdapterError.unsupportedVersion } }
    private func fingerprint() throws -> String {
        var data = Data((name + "\0" + config.path + "\0" + configuration.helperURL.path + "\0" + configuration.profile + "\0" + configuration.installedVersion).utf8)
        for url in [config, manifest, journal] {
            data.append(0)
            if let bytes = try read(url) { data.append(1); data.append(Data(digest(bytes).utf8)) } else { data.append(0) }
        }
        return digest(data)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func requireFiles(patch: Data?, registry: Data?) throws {
        guard try read(config) == patch, try read(manifest) == registry else { throw HarnessAdapterError.stalePlan }
    }
    private func recoverPending() throws {
        guard let data = try read(journal) else { return }
        guard let transaction = try? JSONDecoder().decode(Journal.self, from: data) else { throw HarnessAdapterError.recoveryRequired }
        let patch = try read(config), registry = try read(manifest)
        guard [transaction.configBefore, transaction.configAfter].contains(patch),
              [transaction.registryBefore, transaction.registryAfter].contains(registry) else { throw HarnessAdapterError.recoveryRequired }
        do {
            try requireFiles(patch: patch, registry: registry)
            try replace(transaction.configBefore, at: config)
            try requireFiles(patch: transaction.configBefore, registry: registry)
            try replace(transaction.registryBefore, at: manifest)
            try requireFiles(patch: transaction.configBefore, registry: transaction.registryBefore)
            try removeDurably(journal)
        } catch HarnessAdapterError.stalePlan { throw HarnessAdapterError.recoveryRequired }
    }
    private func acquireLock() async throws -> Int32 {
        guard config.isFileURL, config.path.hasPrefix("/"), configuration.helperURL.isFileURL,
              config.pathComponents.allSatisfy({ $0 != "." && $0 != ".." }),
              configuration.profile.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { throw HarnessAdapterError.invalidConfiguration }
        try createPrivateDirectory(root); try createPrivateDirectory(state)
        let path = state.appendingPathComponent("connection.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw HarnessAdapterError.unsafePath }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & S_IFMT) == S_IFREG else { close(descriptor); throw HarnessAdapterError.unsafePath }
        let deadline = Date().addingTimeInterval(20)
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK, Date() < deadline else { throw HarnessAdapterError.ioFailure }
                try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch { close(descriptor); throw error }
        return descriptor
    }
    private func release(_ descriptor: Int32) { flock(descriptor, LOCK_UN); close(descriptor) }

    private func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { throw HarnessAdapterError.unsafePath }
        // Проверяются компоненты, а не только конечный каталог: symlink в родителе
        // иначе позволил бы сохранить конфигурацию за пределами выбранного профиля.
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            var parentInfo = stat()
            guard lstat(parent.path, &parentInfo) == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else { throw HarnessAdapterError.unsafePath }
            parent.deleteLastPathComponent()
        }
    }
    private func createPrivateDirectory(_ url: URL) throws {
        if !manager.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if !manager.fileExists(atPath: parent.path) { try createPrivateDirectory(parent) }
            else {
                var info = stat()
                guard lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw HarnessAdapterError.unsafePath }
                if info.st_uid != getuid() || (info.st_mode & 0o022) != 0 {
                    guard info.st_uid == 0, (info.st_mode & S_ISVTX) != 0 else { throw HarnessAdapterError.unsafePath }
                } else { try validateDirectory(parent) }
            }
            // Два GUI могут одновременно создавать служебный каталог до
            // открытия общего flock. EEXIST допустим только после lstat ниже.
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw HarnessAdapterError.ioFailure }
        }
        try validateDirectory(url)
    }
    private func read(_ url: URL) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }; throw HarnessAdapterError.ioFailure
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & 0o022) == 0 else { throw HarnessAdapterError.unsafePath }
        try validateDirectory(url.deletingLastPathComponent())
        let maximum = url == journal ? 4_194_304 : 1_048_576
        guard info.st_size <= maximum else { throw HarnessAdapterError.unsafePath }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw HarnessAdapterError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else { throw HarnessAdapterError.unsafePath }
        guard let data = try handle.read(upToCount: maximum + 1), data.count <= maximum else { throw HarnessAdapterError.unsafePath }
        return data
    }
    private func atomicWrite(_ data: Data, to url: URL) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        _ = try read(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".ecosystem-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw HarnessAdapterError.ioFailure }
        defer { close(descriptor); try? manager.removeItem(at: temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let amount = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw HarnessAdapterError.ioFailure }; offset += amount
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw HarnessAdapterError.ioFailure }
        // fsync каталога сохраняет rename при аварийном завершении между шагами журнала.
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }
    private func replace(_ data: Data?, at url: URL) throws {
        if let data { try atomicWrite(data, to: url) }
        else if try read(url) != nil { try removeDurably(url) }
    }
    private func removeDurably(_ url: URL) throws {
        _ = try read(url)
        try manager.removeItem(at: url)
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw HarnessAdapterError.ioFailure }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw HarnessAdapterError.ioFailure }
    }
}
