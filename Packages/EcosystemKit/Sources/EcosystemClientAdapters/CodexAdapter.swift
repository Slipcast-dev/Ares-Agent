import CryptoKit
import Darwin
import Foundation

/// Адаптер управляет только собственным блоком TOML и одним файлом роли.
/// Файловый lock общий для двух приложений; actor защищает состояние внутри процесса.
public actor CodexAdapter {
    private let configuration: CodexAdapterConfiguration
    private let manager = FileManager.default
    private let beforeCommitWrite: (@Sendable (String) throws -> Void)?
    private var root: URL { configuration.configDirectory }
    private var state: URL { root.appendingPathComponent(".ecosystem-subagents", isDirectory: true) }
    private var config: URL { root.appendingPathComponent("config.toml") }
    private var role: URL { root.appendingPathComponent("agents/\(name).toml") }
    private var manifest: URL { state.appendingPathComponent("\(name).json") }
    private var journal: URL { state.appendingPathComponent("\(name)-pending.json") }
    private var name: String { configuration.domain.rawValue }
    private var begin: String { "\n# BEGIN ECOSYSTEM SUBAGENT \(name)\n" }
    private var end: String { "# END ECOSYSTEM SUBAGENT \(name)\n" }

    public init(configuration: CodexAdapterConfiguration) {
        self.configuration = configuration; self.beforeCommitWrite = nil
    }

    /// Детерминированная точка отказа нужна испытаниям конкурентного редактора:
    /// проверка не зависит от скорости fsync и планировщика на конкретном Mac.
    init(configuration: CodexAdapterConfiguration,
         beforeCommitWrite: @escaping @Sendable (String) throws -> Void) {
        self.configuration = configuration; self.beforeCommitWrite = beforeCommitWrite
    }

    public func preview(connected: Bool) async throws -> CodexConnectionPlan {
        let lock = try await acquireLock(); defer { release(lock) }
        // Даже распознанный частичный commit не восстанавливаем при просмотре:
        // изменение пользовательских файлов требует отдельного явного действия.
        guard try read(journal) == nil else { throw CodexAdapterError.recoveryRequired }
        let initialFingerprint = try fingerprint()
        let snapshot = try inspect()
        let prepared = try prepare(connected: connected, snapshot: snapshot)
        if connected {
            if snapshot.owned == nil {
                let existingNames = try await validateCLI(snapshot.config, requireOwnServer: false)
                guard !existingNames.contains(name) else { throw CodexAdapterError.conflict }
            }
            _ = try await validateCLI(prepared.config)
        }
        // Пользовательский редактор не участвует в lock: план должен описывать
        // именно проверенный снимок, а не правку, появившуюся во время CLI-проверки.
        guard initialFingerprint == (try fingerprint()) else { throw CodexAdapterError.stalePlan }
        return CodexConnectionPlan(domain: name, connected: connected,
            fingerprint: initialFingerprint, changes: prepared.changed ? [connected
                ? "Подключить роль \(name) и её MCP-сервер в выбранном профиле Codex."
                : "Удалить принадлежащие экосистеме роль \(name) и блок MCP."] : [],
            warnings: ["Доступ к операциям выдаётся отдельно в приложении агента.",
                "После подключения начните новый сеанс Codex, чтобы перечитать роли."],
            backupDirectory: prepared.changed ? state.appendingPathComponent("backups").path : nil)
    }

    public func apply(_ plan: CodexConnectionPlan) async throws -> CodexAdapterStatus {
        let lock = try await acquireLock(); defer { release(lock) }
        guard plan.domain == name, plan.fingerprint == (try fingerprint()) else { throw CodexAdapterError.stalePlan }
        guard !manager.fileExists(atPath: journal.path) else { throw CodexAdapterError.recoveryRequired }
        let snapshot = try inspect()
        let prepared = try prepare(connected: plan.connected, snapshot: snapshot)
        guard prepared.changed else { return try currentStatus() }
        if plan.connected { _ = try await validateCLI(prepared.config) }
        // CLI-проверка содержит await: заново проверяем снимок даже при удерживаемом lock,
        // поскольку пользовательский редактор не обязан пользоваться нашим lock-файлом.
        guard plan.fingerprint == (try fingerprint()) else { throw CodexAdapterError.stalePlan }
        let newRole = plan.connected ? Data(roleText.utf8) : nil
        let newManifest = plan.connected ? try JSONEncoder().encode(Ownership(
            roleDigest: digest(newRole!), blockDigest: digest(Data(block.utf8)))) : nil
        // Не превращаем позднюю внешнюю правку в разрешённый before-снимок:
        // после await принимаются только байты исходной проверенной конфигурации.
        let configBefore = try read(config)
        guard (configBefore ?? Data()) == snapshot.config else { throw CodexAdapterError.stalePlan }
        let transaction = Journal(configBefore: configBefore, roleBefore: snapshot.role,
            manifestBefore: snapshot.manifest, configAfter: prepared.config,
            roleAfter: newRole, manifestAfter: newManifest)
        let backup = state.appendingPathComponent("backups/\(name)-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(backup)
        try atomicWrite(try JSONEncoder().encode(transaction), to: backup.appendingPathComponent("restore.json"))
        try atomicWrite(try JSONEncoder().encode(transaction), to: journal)
        do {
            // Роль появляется раньше MCP: незавершённое подключение не объявляет готовый сервер.
            try beforeCommitWrite?("role")
            try requireFiles(config: transaction.configBefore, role: transaction.roleBefore,
                             manifest: transaction.manifestBefore)
            try replace(newRole, at: role)
            // Backup и журнал требуют fsync: редактор мог сохранить профиль за
            // это время. Сверяем исходные байты непосредственно перед заменой.
            try beforeCommitWrite?("config")
            try requireFiles(config: transaction.configBefore, role: newRole,
                             manifest: transaction.manifestBefore)
            try atomicWrite(prepared.config, to: config)
            try beforeCommitWrite?("manifest")
            try requireFiles(config: prepared.config, role: newRole,
                             manifest: transaction.manifestBefore)
            try replace(newManifest, at: manifest)
            try requireFiles(config: prepared.config, role: newRole, manifest: newManifest)
            try manager.removeItem(at: journal)
            return try currentStatus()
        } catch {
            // Восстановление сверяет каждый текущий файл с двумя известными версиями.
            // При внешнем изменении журнал сохраняется и перезапись запрещается.
            try recoverPending()
            throw error
        }
    }

    public func status() async throws -> CodexAdapterStatus {
        let lock = try await acquireLock(); defer { release(lock) }
        let status = try currentStatus()
        if status.state == "connected" {
            let before = try fingerprint()
            do { _ = try await validateCLI(try read(config) ?? Data()) }
            catch CodexAdapterError.cliValidationFailed {
                return CodexAdapterStatus(domain: name, connected: false, state: "conflict",
                    detail: "Codex отклонил конфигурацию подключённого агента; файлы не изменены.")
            }
            guard before == (try fingerprint()) else { throw CodexAdapterError.stalePlan }
        }
        if status.state == "disconnected", configuration.codexExecutableURL != nil {
            let names = try await validateCLI(try read(config) ?? Data(), requireOwnServer: false)
            if names.contains(name) {
                return CodexAdapterStatus(domain: name, connected: false, state: "conflict", detail: "Codex сообщает о чужом MCP-сервере с тем же именем.")
            }
        }
        return status
    }

    /// Вызывается только после отдельного подтверждения восстановления.
    /// Чужая правка сохраняет журнал и блокирует автоматический откат.
    public func recoverConnection() async throws -> CodexAdapterStatus {
        let lock = try await acquireLock(); defer { release(lock) }
        try recoverPending()
        return try currentStatus()
    }

    private struct Ownership: Codable { let roleDigest: String; let blockDigest: String }
    private struct Snapshot { let config: Data; let role: Data?; let manifest: Data?; let owned: Ownership? }
    private struct Prepared { let config: Data; let changed: Bool }
    private struct Journal: Codable {
        let configBefore: Data?; let roleBefore: Data?; let manifestBefore: Data?
        let configAfter: Data; let roleAfter: Data?; let manifestAfter: Data?
    }

    private func inspect() throws -> Snapshot {
        let configData = try read(config) ?? Data()
        guard String(data: configData, encoding: .utf8) != nil else { throw CodexAdapterError.invalidConfiguration }
        let roleData = try read(role), manifestData = try read(manifest)
        let ownership: Ownership?
        if let manifestData {
            do { ownership = try JSONDecoder().decode(Ownership.self, from: manifestData) }
            catch { throw CodexAdapterError.conflict }
        } else { ownership = nil }
        return Snapshot(config: configData, role: roleData, manifest: manifestData, owned: ownership)
    }

    private func currentStatus() throws -> CodexAdapterStatus {
        if manager.fileExists(atPath: journal.path) {
            return CodexAdapterStatus(domain: name, connected: false, state: "recoveryRequired", detail: "Операция не завершена; требуется сверка журнала.")
        }
        let snapshot = try inspect()
        do {
            let owned = try ownedBlock(snapshot)
            let duplicate = try hasDuplicateRole()
            if owned != nil {
                var remaining = String(decoding: snapshot.config, as: UTF8.self)
                remaining.removeSubrange(owned!)
                guard !duplicate, !hasServer(remaining) else { throw CodexAdapterError.conflict }
                return CodexAdapterStatus(domain: name, connected: true, state: "connected", detail: "Роль и MCP-блок принадлежат экосистеме и не изменены.")
            }
            if snapshot.role != nil || hasServer(String(decoding: snapshot.config, as: UTF8.self)) || duplicate {
                return CodexAdapterStatus(domain: name, connected: false, state: "conflict", detail: "Имя роли или MCP-сервера уже занято.")
            }
            return CodexAdapterStatus(domain: name, connected: false, state: "disconnected", detail: "Агент не подключён в выбранном профиле.")
        } catch CodexAdapterError.conflict {
            return CodexAdapterStatus(domain: name, connected: false, state: "conflict", detail: "Управляемые файлы изменены вручную; автоматическая перезапись запрещена.")
        }
    }

    private func prepare(connected: Bool, snapshot: Snapshot) throws -> Prepared {
        let existing = try ownedBlock(snapshot)
        var text = String(decoding: snapshot.config, as: UTF8.self)
        if let existing { text.removeSubrange(existing) }
        let duplicate = try hasDuplicateRole()
        guard !hasServer(text), !duplicate else { throw CodexAdapterError.conflict }
        if snapshot.owned == nil, snapshot.role != nil { throw CodexAdapterError.conflict }
        if connected {
            let expected = Data((text + block).utf8)
            guard expected.count <= 1_048_576 else { throw CodexAdapterError.invalidConfiguration }
            return Prepared(config: expected, changed: expected != snapshot.config || snapshot.role != Data(roleText.utf8))
        }
        return Prepared(config: Data(text.utf8), changed: existing != nil)
    }

    /// Вырезается точный принадлежащий нам диапазон, включая добавленный разделитель.
    /// Остальные байты config.toml остаются неизменными даже после отключения.
    private func ownedBlock(_ snapshot: Snapshot) throws -> Range<String.Index>? {
        let text = String(decoding: snapshot.config, as: UTF8.self)
        let starts = text.ranges(of: begin), ends = text.ranges(of: end)
        guard let ownership = snapshot.owned else {
            guard starts.isEmpty, ends.isEmpty else { throw CodexAdapterError.conflict }; return nil
        }
        guard starts.count == 1, ends.count == 1, starts[0].upperBound <= ends[0].lowerBound,
              let roleData = snapshot.role, digest(roleData) == ownership.roleDigest else { throw CodexAdapterError.conflict }
        let range = starts[0].lowerBound..<ends[0].upperBound
        guard digest(Data(text[range].utf8)) == ownership.blockDigest else { throw CodexAdapterError.conflict }
        return range
    }

    private func hasServer(_ text: String) -> Bool {
        // Заголовки с одинарными/двойными кавычками и inline-таблицы также резервируют имя.
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = ["(?m)^\\s*\\[\\[?\\s*(?:mcp_servers|\"mcp_servers\"|'mcp_servers')\\s*\\.\\s*(?:\(escaped)|\"\(escaped)\"|'\(escaped)')\\s*(?:\\.|\\])",
                        "(?m)^\\s*(?:mcp_servers\\s*\\.\\s*)?(?:\(escaped)|\"\(escaped)\"|'\(escaped)')\\s*="]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private func hasDuplicateRole() throws -> Bool {
        let directory = root.appendingPathComponent("agents", isDirectory: true)
        guard manager.fileExists(atPath: directory.path) else { return false }
        try validateDirectory(directory)
        let urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard urls.count <= 256 else { throw CodexAdapterError.invalidConfiguration }
        for url in urls where url.pathExtension == "toml" && url.lastPathComponent != role.lastPathComponent {
            guard let data = try read(url), let text = String(data: data, encoding: .utf8) else { continue }
            if try declaredRoleName(text) == name { return true }
        }
        return false
    }

    /// Для имени роли принимается однострочная TOML-строка. Неоднозначная или
    /// повреждённая декларация блокирует изменение вместо угадывания имени.
    private func declaredRoleName(_ text: String) throws -> String {
        let expression = try NSRegularExpression(pattern: "(?m)^\\s*(?:name|\"name\"|'name')\\s*=\\s*([^\\r\\n]+)")
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range(at: 1), in: text) else { throw CodexAdapterError.conflict }
        let value = String(text[range]).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("'") {
            let tail = value.dropFirst()
            guard let end = tail.firstIndex(of: "'") else { throw CodexAdapterError.conflict }
            let suffix = tail[tail.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard suffix.isEmpty || suffix.hasPrefix("#") else { throw CodexAdapterError.conflict }
            return String(tail[..<end])
        }
        guard value.hasPrefix("\"") else { throw CodexAdapterError.conflict }
        var escaped = false
        for index in value.indices.dropFirst() {
            let character = value[index]
            if !escaped, character == "\"" {
                let suffix = value[value.index(after: index)...].trimmingCharacters(in: .whitespaces)
                guard suffix.isEmpty || suffix.hasPrefix("#"),
                      let decoded = try? JSONSerialization.jsonObject(with: Data(value[...index].utf8), options: .fragmentsAllowed) as? String else { throw CodexAdapterError.conflict }
                return decoded
            }
            if character == "\\", !escaped { escaped = true } else { escaped = false }
        }
        throw CodexAdapterError.conflict
    }

    private func fingerprint() throws -> String {
        var chunks = Data((name + "\n" + root.path + "\n" + configuration.helperURL.path + "\n" + (configuration.codexExecutableURL?.path ?? "")).utf8)
        for url in [config, role, manifest, journal] {
            chunks.append(Data(url.lastPathComponent.utf8)); chunks.append(0)
            if let data = try read(url) { chunks.append(1); chunks.append(Data(digest(data).utf8)) } else { chunks.append(0) }
        }
        let directory = root.appendingPathComponent("agents")
        if manager.fileExists(atPath: directory.path) {
            try validateDirectory(directory)
            let urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard urls.count <= 256 else { throw CodexAdapterError.invalidConfiguration }
            for url in urls where url.pathExtension == "toml" {
                chunks.append(Data(url.lastPathComponent.utf8)); chunks.append(0)
                chunks.append(Data(digest(try read(url) ?? Data()).utf8))
            }
        }
        return digest(chunks)
    }

    private func validateCLI(_ data: Data, requireOwnServer: Bool = true) async throws -> Set<String> {
        guard let executable = configuration.codexExecutableURL,
              manager.isExecutableFile(atPath: executable.path),
              (!requireOwnServer || manager.isExecutableFile(atPath: configuration.helperURL.path)),
              configuration.helperURL.path.hasPrefix("/") else { throw CodexAdapterError.cliUnavailable }
        let staging = try physicalTemporaryDirectory().appendingPathComponent("ecosystem-codex-validate-\(UUID().uuidString)", isDirectory: true)
        try createPrivateDirectory(staging)
        defer { try? manager.removeItem(at: staging) }
        try atomicWrite(data, to: staging.appendingPathComponent("config.toml"))
        try createPrivateDirectory(staging.appendingPathComponent("agents", isDirectory: true))
        try atomicWrite(Data(roleText.utf8), to: staging.appendingPathComponent("agents/\(name).toml"))
        let names = try await CodexProcess.validate(executable: executable, directory: staging)
        guard !requireOwnServer || names.contains(name) else { throw CodexAdapterError.cliValidationFailed }
        return names
    }

    private var block: String {
        begin + "[mcp_servers.\(name)]\ncommand = \(quote(configuration.helperURL.path))\nargs = []\nstartup_timeout_sec = 20\ntool_timeout_sec = 310\n" + end
    }
    private var roleText: String {
        let speciality = configuration.domain == .ares
            ? "Ты Арес — отдельный агент организации файлов. Работай только через MCP-сервер ares. Изучай возможности, состояние и разрешённые корни; сканируй, формируй предварительный просмотр правил и выполняй только явно согласованные файловые операции. Не запрашивай содержимое файлов без выданного доступа; не подменяй отсутствующие данные догадками."
            : "Ты Афина — отдельный агент диагностики Mac. Работай только через MCP-сервер athena. Проверяй возможности, состояние системы и результаты разрешённых диагностических задач. Отделяй наблюдаемые факты от предположений, сообщай ограничения выборки. Не выполняй произвольные системные команды и изменения настроек."
        let workflow = "Сначала вызывай agent.get_capabilities и agent.get_status своего MCP-сервера. Используй только его инструменты: наличие инструмента не означает наличия разрешения. При отказе попроси пользователя выдать доступ в отдельном приложении агента. Для длительных операций сохраняй taskId, проверяй task.get и task.get_result, учитывай следующий курсор списка. Отмена ожидания не отменяет задачу: используй task.cancel только по намерению пользователя. Не сообщай об успехе до подтверждённого результата; явно показывай ошибки, частичный результат и истечение срока. Не вызывай другой MCP-сервер, shell, приложения, сеть, другие роли или изменение конфигурации. Передавай родительскому агенту краткий проверяемый результат, taskId и ограничения; не выдавай разрешения самостоятельно."
        return "name = \(quote(name))\ndescription = \(quote(configuration.domain == .ares ? "Организация файлов через отдельный агент Арес" : "Диагностика Mac через отдельный агент Афина"))\ndeveloper_instructions = \(quote(speciality + " " + workflow))\n\n[features]\nshell_tool = false\napps = false\nplugins = false\n"
    }
    private func quote(_ text: String) -> String {
        // JSON-строка совместима с базовой строкой TOML для используемых символов пути.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try! encoder.encode(text)
        return String(decoding: data, as: UTF8.self)
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func acquireLock() async throws -> Int32 {
        guard root.isFileURL, root.path.hasPrefix("/"), configuration.helperURL.isFileURL else { throw CodexAdapterError.invalidConfiguration }
        try createPrivateDirectory(root); try createPrivateDirectory(state)
        let path = state.appendingPathComponent("connection.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CodexAdapterError.unsafePath }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & S_IFMT) == S_IFREG else { close(descriptor); throw CodexAdapterError.unsafePath }
        let deadline = Date().addingTimeInterval(20)
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK, Date() < deadline else { throw CodexAdapterError.ioFailure }
                try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000)
            }
        } catch { close(descriptor); throw error }
        return descriptor
    }
    private func release(_ descriptor: Int32) { flock(descriptor, LOCK_UN); close(descriptor) }

    private func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { throw CodexAdapterError.unsafePath }
        // Проверяются компоненты, а не только конечный каталог: symlink в родителе
        // иначе позволил бы сохранить конфигурацию за пределами выбранного профиля.
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" {
            var parentInfo = stat()
            guard lstat(parent.path, &parentInfo) == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else { throw CodexAdapterError.unsafePath }
            parent.deleteLastPathComponent()
        }
    }
    private func createPrivateDirectory(_ url: URL) throws {
        if !manager.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if !manager.fileExists(atPath: parent.path) { try createPrivateDirectory(parent) }
            else {
                var info = stat()
                guard lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw CodexAdapterError.unsafePath }
                if info.st_uid != getuid() || (info.st_mode & 0o022) != 0 {
                    guard info.st_uid == 0, (info.st_mode & S_ISVTX) != 0 else { throw CodexAdapterError.unsafePath }
                } else { try validateDirectory(parent) }
            }
            try manager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try validateDirectory(url)
    }
    private func read(_ url: URL) throws -> Data? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }; throw CodexAdapterError.ioFailure
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              (info.st_mode & 0o022) == 0 else { throw CodexAdapterError.unsafePath }
        try validateDirectory(url.deletingLastPathComponent())
        let maximum = url == journal ? 4_194_304 : 1_048_576
        guard info.st_size <= maximum else { throw CodexAdapterError.unsafePath }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CodexAdapterError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else { throw CodexAdapterError.unsafePath }
        guard let data = try handle.read(upToCount: maximum + 1), data.count <= maximum else { throw CodexAdapterError.unsafePath }
        return data
    }
    private func atomicWrite(_ data: Data, to url: URL) throws {
        try createPrivateDirectory(url.deletingLastPathComponent())
        _ = try read(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".ecosystem-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CodexAdapterError.ioFailure }
        defer { close(descriptor); try? manager.removeItem(at: temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let amount = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw CodexAdapterError.ioFailure }; offset += amount
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw CodexAdapterError.ioFailure }
        // fsync каталога сохраняет rename при аварийном завершении между шагами журнала.
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }
    private func replace(_ data: Data?, at url: URL) throws {
        if let data { try atomicWrite(data, to: url) }
        else if try read(url) != nil { try manager.removeItem(at: url) }
    }
    /// Сверяем все связанные файлы перед каждым шагом commit. Это уменьшает
    /// окно внешней правки; редакторы, не использующие наш flock, нельзя сделать
    /// участниками общей транзакции, поэтому при расхождении сохраняем журнал.
    private func requireFiles(config expectedConfig: Data?, role expectedRole: Data?,
                              manifest expectedManifest: Data?) throws {
        guard try read(config) == expectedConfig, try read(role) == expectedRole,
              try read(manifest) == expectedManifest else { throw CodexAdapterError.stalePlan }
    }

    private func recoverPending() throws {
        guard let data = try read(journal) else { return }
        guard let transaction = try? JSONDecoder().decode(Journal.self, from: data) else { throw CodexAdapterError.recoveryRequired }
        let actualConfig = try read(config), actualRole = try read(role), actualManifest = try read(manifest)
        guard [transaction.configBefore, transaction.configAfter].contains(actualConfig),
              [transaction.roleBefore, transaction.roleAfter].contains(actualRole),
              [transaction.manifestBefore, transaction.manifestAfter].contains(actualManifest) else { throw CodexAdapterError.recoveryRequired }
        // Перед каждым обратным шагом проверяем именно прочитанный снимок:
        // внешний редактор не обязан удерживать connection.lock.
        do {
            try requireFiles(config: actualConfig, role: actualRole, manifest: actualManifest)
            try replace(transaction.roleBefore, at: role)
            try requireFiles(config: actualConfig, role: transaction.roleBefore, manifest: actualManifest)
            try replace(transaction.configBefore, at: config)
            try requireFiles(config: transaction.configBefore, role: transaction.roleBefore, manifest: actualManifest)
            try replace(transaction.manifestBefore, at: manifest)
            try requireFiles(config: transaction.configBefore, role: transaction.roleBefore,
                             manifest: transaction.manifestBefore)
            try manager.removeItem(at: journal)
        } catch CodexAdapterError.stalePlan { throw CodexAdapterError.recoveryRequired }
    }
}

private extension String {
    func ranges(of value: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = [], start = startIndex
        while start < endIndex, let range = range(of: value, range: start..<endIndex) {
            result.append(range); start = range.upperBound
        }
        return result
    }
}

/// Foundation может возвращать /var даже после resolvingSymlinksInPath(); POSIX
/// realpath сохраняет физический /private/var для проверки каждого компонента.
func physicalTemporaryDirectory() throws -> URL {
    guard let pointer = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CodexAdapterError.ioFailure }
    defer { free(pointer) }
    return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
}
