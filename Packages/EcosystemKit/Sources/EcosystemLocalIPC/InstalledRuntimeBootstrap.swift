import Darwin
import Foundation
import Security

/// Установленное приложение создаёт собственный профиль без Python/SwiftPM.
/// Рабочий ENV-профиль разработки имеет приоритет: его данные не перемещаются.
public enum InstalledRuntimeBootstrap {
    public struct Product: Sendable {
        public let domain: String
        public let name: String
        public let gui: String
        public let mcp: String
        public let runtime: String
        public let worker: String?
        public init(domain: String) throws {
            guard ["ares", "athena"].contains(domain) else { throw Failure.invalidProfile }
            self.domain = domain
            name = domain == "ares" ? "Ares" : "Athena"
            gui = domain == "ares" ? "FileOrganizer" : "MacAssistant"
            mcp = gui + "MCP"
            runtime = name + "Runtime"
            worker = domain == "ares" ? "FileOrganizerRulesWorker" : nil
        }
    }
    public enum Failure: LocalizedError {
        case invalidProfile, changedApplication, systemDisabled, commandFailed
        public var errorDescription: String? {
            switch self {
            case .invalidProfile: return "Локальный профиль повреждён или имеет небезопасные права. Данные сохранены; восстановите профиль из резервной копии."
            case .changedApplication: return "Приложение отличается от версии, создавшей профиль. Автоматическая замена службы заблокирована: требуется резервная копия и миграция профиля."
            case .systemDisabled: return "macOS отключила службу. Разрешите её в системных настройках фоновых объектов и повторно откройте приложение."
            case .commandFailed: return "Не удалось запустить локальную службу. Повторно откройте приложение и проверьте системные разрешения."
            }
        }
    }

    /// Вызывать до контейнеров: все GUI-сервисы должны сразу выбрать IPC,
    /// а при ошибке нельзя незаметно открыть прежнюю БД напрямую.
    public static func configureEnvironment(domain: String) throws {
        let key = domain.uppercased() + "_LOCAL_RUNTIME_CONFIG"
        if ProcessInfo.processInfo.environment[key] != nil { return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let product = try Product(domain: domain)
        // Foundation сокращает /private/tmp до /tmp даже без реальной ссылки.
        // POSIX realpath даёт однозначный путь ОС, включая изолированный test home.
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let resolved = realpath(home.path, nil) else { throw Failure.invalidProfile }
        let canonicalHome = URL(fileURLWithPath: String(cString: resolved)); free(resolved)
        let support = canonicalHome
            .appendingPathComponent("Library/Application Support/" + product.name + "Agent")
        let profile = support.appendingPathComponent("Runtime")
        let file = try prepare(domain: domain, application: Bundle.main.bundleURL, profile: profile)
        guard setenv(key, file.path, 1) == 0 else { throw Failure.commandFailed }
        try start(domain: domain, profile: profile)
    }

    /// Отдельный параметр profile нужен для изолированной проверки настоящих
    /// подписанных продуктов; в GUI путь задаётся только Application Support.
    @discardableResult
    public static func prepare(domain: String, application: URL, profile: URL) throws -> URL {
        let product = try Product(domain: domain)
        let fm = FileManager.default
        let parent = profile.deletingLastPathComponent()
        try secureDirectory(parent, create: true)
        // Два окна/процесса не могут одновременно сформировать поколения кода.
        let fd = open(parent.appendingPathComponent(".activation.lock").path,
                      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.invalidProfile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.invalidProfile }
        defer { flock(fd, LOCK_UN) }
        let contents = application.appendingPathComponent("Contents")
        let gui = contents.appendingPathComponent("MacOS/" + product.gui)
        let guiPin = try requirement(gui)
        let file = profile.appendingPathComponent(domain + ".json")
        try InstalledRuntimeMaintenance.requireNoInterruptedTransaction(profile: profile)
        if fm.fileExists(atPath: profile.path) {
            try secureDirectory(profile)
            let marker = try readObject(profile.appendingPathComponent("profile.json"))
            guard marker["standaloneVersion"] as? Int == 1,
                  marker["uid"] as? Int == Int(geteuid()),
                  let agents = marker["agents"] as? [String: [String: Any]],
                  Set(agents.keys) == [domain], let agent = agents[domain],
                  agent["configuration"] as? String == file.path else { throw Failure.invalidProfile }
            let config = try LocalRuntimeConfiguration.load(file, domain: domain)
            guard config.endpoints["gui"]?.clientRequirement == guiPin else { throw Failure.changedApplication }
            try validateSnapshot(product, profile: profile, configuration: config)
            return file
        }
        // Все абсолютные ссылки указывают на конечную папку. До атомарного
        // rename частичный профиль не виден ни GUI, ни launchd, ни клиентам.
        let staging = parent.appendingPathComponent(".activation-" + UUID().uuidString)
        try secureDirectory(staging, create: true)
        defer { try? fm.removeItem(at: staging) }
        try stage(domain: domain, application: application, profile: profile, staging: staging,
                  identifier: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        try fm.moveItem(at: staging, to: profile)
        return file
    }

    /// MCP запускается вне .app: SwiftPM ищет общие bundle рядом с executable.
    /// Закрытый список исключает перенос GUI-ресурсов и произвольных файлов.
    /// Старые приложения до локализации могут не содержать этих bundle.
    static let standaloneResourceBundles = [
        "EcosystemKit_EcosystemContracts.bundle",
        "EcosystemKit_EcosystemLocalization.bundle",
    ]

    /// Maintenance строит новое поколение с прежними абсолютными путями и
    /// MachServices. Конфигурации клиентов не требуют повторной записи.
    static func stage(domain: String, application: URL, profile: URL, staging: URL, identifier: String) throws {
        let product = try Product(domain: domain)
        let fm = FileManager.default
        let contents = application.appendingPathComponent("Contents")
        let guiPin = try requirement(contents.appendingPathComponent("MacOS/" + product.gui))
        let file = profile.appendingPathComponent(domain + ".json")
        let label = "local.ecosystem." + domain + "." + String(geteuid()) + "." + identifier
        let runtimeRelative = product.name + "Background.app"
        try fm.copyItem(at: contents.appendingPathComponent("Library/LoginItems/" + runtimeRelative),
                        to: staging.appendingPathComponent(runtimeRelative))
        for name in standaloneResourceBundles {
            let source = contents.appendingPathComponent("Resources/" + name)
            if fm.fileExists(atPath: source.path) {
                try fm.copyItem(at: source, to: staging.appendingPathComponent(name))
            }
        }
        let runtime = profile.appendingPathComponent(runtimeRelative + "/Contents/MacOS/" + product.runtime)
        let runtimePin = try requirement(staging.appendingPathComponent(runtimeRelative + "/Contents/MacOS/" + product.runtime))
        var pins = ["gui": guiPin, "worker": guiPin]
        var clients: [String: [String: String]] = [:]
        // Код клиента подписывается различными identifiers. Один MCP-бинарник
        // с подменённым ENV не должен проходить в endpoint другого клиента.
        for client in ["legacy", "codex", "deepseekHarness"] {
            let binaryName = product.mcp + "-" + client
            let target = staging.appendingPathComponent(binaryName)
            try fm.copyItem(at: contents.appendingPathComponent("MacOS/" + product.mcp), to: target)
            guard try command("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier",
                "local.ecosystem." + domain + ".mcp." + client, target.path]).0 == 0 else { throw Failure.commandFailed }
            let key = client == "legacy" ? "mcp" : "mcp." + client
            pins[key] = try requirement(target)
            let configurationName = client == "legacy" ? domain + ".json" : domain + "-" + client + ".json"
            let wrapperName = client == "legacy" ? domain + "-mcp.command" : domain + "-" + client + "-mcp.command"
            let configPath = profile.appendingPathComponent(configurationName).path
            let binaryPath = profile.appendingPathComponent(binaryName).path
            let wrapper = "#!/bin/sh\nexport " + domain.uppercased() + "_LOCAL_RUNTIME_CONFIG=" + quote(configPath) + "\nexec " + quote(binaryPath) + "\n"
            try write(Data(wrapper.utf8), staging.appendingPathComponent(wrapperName), mode: 0o700)
            if client != "legacy" {
                clients[client] = ["configuration": configPath, "mcp": binaryPath,
                                   "wrapper": profile.appendingPathComponent(wrapperName).path]
            }
        }
        if let worker = product.worker {
            try fm.copyItem(at: contents.appendingPathComponent("MacOS/" + worker), to: staging.appendingPathComponent(worker))
            pins["worker"] = try requirement(staging.appendingPathComponent(worker))
        }
        let endpoints = pins.mapValues { ["clientRequirement": $0] }.map { key, value in
            (key, value.merging(["service": label + "." + key]) { _, new in new })
        }
        let configuration: [String: Any] = ["version": 1, "mode": "local-ad-hoc", "domain": domain,
            "serverRequirement": runtimePin, "endpoints": Dictionary(uniqueKeysWithValues: endpoints)]
        try writeJSON(configuration, staging.appendingPathComponent(domain + ".json"))
        for client in clients.keys {
            var selected = configuration; selected["selectedMCPClient"] = client
            try writeJSON(selected, staging.appendingPathComponent(domain + "-" + client + ".json"))
        }
        let services = Dictionary(uniqueKeysWithValues: pins.keys.map { (label + "." + $0, true) })
        let plist: [String: Any] = ["Label": label, "ProgramArguments": [runtime.path, "--config", file.path],
            "MachServices": services, "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 30,
            "StandardOutPath": profile.appendingPathComponent(domain + "-runtime.stdout").path,
            "StandardErrorPath": profile.appendingPathComponent(domain + "-runtime.stderr").path]
        try write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                  staging.appendingPathComponent(domain + ".plist"))
        let agent: [String: Any] = ["label": label, "configuration": file.path, "runtime": runtime.path,
            "runtimeBundle": profile.appendingPathComponent(runtimeRelative).path, "bundle": application.path,
            "mcp": profile.appendingPathComponent(product.mcp + "-legacy").path, "clients": clients]
        try writeJSON(["version": 1, "standaloneVersion": 1, "uid": Int(geteuid()), "identifier": identifier,
            "mode": "local-ad-hoc", "agents": [domain: agent], "persistent": [String: String]()],
            staging.appendingPathComponent("profile.json"))
        let stagedConfig = try LocalRuntimeConfiguration.load(staging.appendingPathComponent(domain + ".json"), domain: domain)
        try validateSnapshot(product, profile: staging, configuration: stagedConfig)
    }

    public static func start(domain: String, profile: URL) throws {
        try InstalledRuntimeMaintenance.activation(profile: profile) {
        try InstalledRuntimeMaintenance.requireNoInterruptedTransaction(profile: profile)
        let product = try Product(domain: domain)
        let config = try LocalRuntimeConfiguration.load(profile.appendingPathComponent(domain + ".json"), domain: domain)
        try validateSnapshot(product, profile: profile, configuration: config)
        let login = LocalLoginRegistration(profile: profile, domain: domain)
        let status = try login.status()
        guard !status.disabledBySystem else { throw Failure.systemDisabled }
        if status.registered { return }
        guard try command("/bin/launchctl", ["bootstrap", "gui/\(geteuid())", profile.appendingPathComponent(domain + ".plist").path]).0 == 0 else {
            // Конкурентное открытие второго окна допустимо только если job
            // действительно зарегистрирован и по-прежнему принадлежит профилю.
            guard try login.status().registered else { throw Failure.commandFailed }
            return
        }
        }
    }

    static func validateSnapshot(_ product: Product, profile: URL, configuration: LocalRuntimeConfiguration) throws {
        try secureDirectory(profile)
        let runtime = profile.appendingPathComponent(product.name + "Background.app/Contents/MacOS/" + product.runtime)
        let executables = [runtime] + ["legacy", "codex", "deepseekHarness"].map {
            profile.appendingPathComponent(product.mcp + "-" + $0)
        } + (product.worker.map { [profile.appendingPathComponent($0)] } ?? [])
        for executable in executables {
            // Подмена каталогов снимка ссылками не превращается в разрешённый
            // внешний код, даже если его CDHash когда-то был доверенным.
            guard let resolved = realpath(executable.path, nil) else { throw Failure.invalidProfile }
            let canonical = String(cString: resolved); free(resolved)
            guard canonical == executable.path else { throw Failure.invalidProfile }
            var info = stat()
            guard lstat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(), info.st_nlink == 1 else { throw Failure.invalidProfile }
        }
        guard try requirement(runtime) == configuration.serverRequirement else { throw Failure.invalidProfile }
        for client in ["legacy", "codex", "deepseekHarness"] {
            let key = client == "legacy" ? "mcp" : "mcp." + client
            guard try requirement(profile.appendingPathComponent(product.mcp + "-" + client)) == configuration.endpoints[key]?.clientRequirement else { throw Failure.invalidProfile }
        }
        if let worker = product.worker {
            guard try requirement(profile.appendingPathComponent(worker)) == configuration.endpoints["worker"]?.clientRequirement else { throw Failure.invalidProfile }
        }
    }

    /// SecStaticCode проверяет подпись файла перед извлечением CDHash: наличие
    /// строки в выводе codesign само по себе не доказывает целостность кода.
    public static func requirement(_ url: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { throw Failure.invalidProfile }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else { throw Failure.invalidProfile }
        return "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
    }

    static func secureDirectory(_ url: URL, create: Bool = false) throws {
        // Сначала проверяем существующих родителей, чтобы createDirectory не
        // записал профиль через символическую ссылку до последующей проверки.
        var cursor = url.path
        while cursor != "/" {
            var info = stat()
            if lstat(cursor, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() || info.st_uid == 0,
                      info.st_mode & 0o022 == 0 || cursor == "/private/tmp" else { throw Failure.invalidProfile }
            } else if errno != ENOENT { throw Failure.invalidProfile }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        if create { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw Failure.invalidProfile }
    }
    static func write(_ data: Data, _ file: URL, mode: mode_t = 0o600) throws {
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Failure.invalidProfile }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.commandFailed }; offset += count
            }
        }
        guard fsync(fd) == 0 else { throw Failure.commandFailed }
    }
    static func writeJSON(_ object: [String: Any], _ file: URL) throws {
        try write(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]), file)
    }
    static func readObject(_ file: URL) throws -> [String: Any] {
        // Конфигурация проверяет владельца/режим; маркер также не должен быть
        // ссылкой или чужим файлом, даже при совпадении содержимого JSON.
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else { throw Failure.invalidProfile }
        return object
    }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func command(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        // Системные команды короткие; watchdog не даёт зависшему launchctl
        // навсегда заблокировать открытие интерфейса приложения.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); watchdog.cancel()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
