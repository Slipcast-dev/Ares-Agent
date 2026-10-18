import Darwin
import Foundation

/// Изменяющие операции изолированы от наблюдения. Принимаются только URL,
/// восстановленные координатором из bookmarks; shell-интерпретатор отсутствует.
public actor RuleFileActions {
    public init() {}

    public func updateTag(_ tag: String, at url: URL, remove: Bool) throws {
        guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RuleExecutionError.invalidConfiguration }
        var tags = try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        if remove { tags.removeAll { $0 == tag } } else if !tags.contains(tag) { tags.append(tag) }
        // NSURL поддерживает запись tagNames на macOS 14; setter Swift
        // URLResourceValues.tagNames появился только в macOS 26.
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    public func copy(source: URL, destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RuleExecutionError.destinationExists }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".organizer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        // Сравнение содержимого защищает от незавершённого копирования; исходник
        // остаётся на месте. Проверка стабильности выполняется координатором.
        guard FileManager.default.contentsEqual(atPath: source.path, andPath: temporary.path) else { throw RuleExecutionError.verificationFailed }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public func archive(source: URL, destination: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw RuleExecutionError.destinationExists }
        let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".organizer-" + UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Для одиночного файла keepParent добавляет имя родительского каталога
        // в ZIP; без него архив содержит ожидаемый файл на верхнем уровне.
        try await runTool("/usr/bin/ditto", ["-c", "-k", source.path, temporary.path])
        try await runTool("/usr/bin/unzip", ["-t", temporary.path])
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw RuleExecutionError.verificationFailed }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    /// Пакетный ZIP собирается во временном каталоге. Копии проверяются до
    /// архивирования; коллизии имён получают числовой префикс внутри архива.
    public func archive(sources: [URL], destination: URL) async throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("organizer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            var target = staging.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) { target = staging.appendingPathComponent("\(index + 1)-" + source.lastPathComponent) }
            try copy(source: source, destination: target)
        }
        try await archive(source: staging, destination: destination)
    }

    /// Фиксированные системные программы получают аргументы массивом, без shell.
    /// Вывод отправляется в nullDevice: содержимое архива не попадает в журнал.
    private func runTool(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(300)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw RuleExecutionError.timeout }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard process.terminationStatus == 0 else { throw RuleExecutionError.verificationFailed }
        } catch {
            if process.isRunning {
                // Не возвращаем callback, пока дочерний процесс физически жив.
                process.terminate()
                let end = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < end { usleep(20_000) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
    }
}

public enum RuleExecutionError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration, destinationExists, verificationFailed, timeout, busy, accessRevoked, unsafePath, contentConsentRequired, notificationsDisabled
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Проверьте настройки правила и папку назначения."
        case .destinationExists: "Назначение уже существует; перезапись запрещена."
        case .verificationFailed: "Проверка результата не прошла. Исходник сохранён."
        case .timeout: "Операция превысила время ожидания."
        case .busy: "Уже выполняется другое правило."
        case .accessRevoked: "Доступ к папке отозван или диск отключён."
        case .unsafePath: "Путь выходит за пределы разрешённой папки или содержит ссылку."
        case .contentConsentRequired: "Включите локальное чтение содержимого в редакторе правила."
        case .notificationsDisabled: "Сначала разрешите уведомления кнопкой в разделе «Правила»."
        }
    }
}

extension RuleFileActions {
    /// ZIP получает только проверенные копии в собственном приватном staging.
    /// После unzip сверяем каждый член с source SHA, затем публикуем ZIP через
    /// тот же descriptor copy на целевом томе. Исходные файлы не удаляются.
    func archiveVerified(root: URL, files: [RuleFileSnapshot], destinationRoot: URL, name: String) async throws {
        let base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ares-zip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let input = base.appendingPathComponent("input"), extracted = base.appendingPathComponent("check")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        var bytes: Int64 = 0
        for file in files { let (sum, overflow) = bytes.addingReportingOverflow(file.byteSize); guard !overflow else { throw RulePolicyError.quota }; bytes = sum }
        try SecureRuleIO.space(SecureRuleIO.directory(base), bytes: bytes, factor: 4)
        try SecureRuleIO.space(SecureRuleIO.directory(destinationRoot), bytes: bytes, factor: 2)
        var names: [String] = []
        for (index, file) in files.enumerated() {
            guard let version = file.version, !file.isDirectory else { throw RuleExecutionError.invalidConfiguration }
            let leaf = "\(index + 1)-" + SecureRuleIO.shortName((file.relativePath as NSString).lastPathComponent)
            try SecureRuleIO.copy(root: root, relative: file.relativePath, version: version, destinationRoot: input, folder: "", name: leaf)
            names.append(leaf)
        }
        let zip = base.appendingPathComponent("result.zip")
        try await runTool("/usr/bin/ditto", ["-c", "-k", input.path, zip.path])
        try await runTool("/usr/bin/unzip", ["-t", zip.path])
        try await runTool("/usr/bin/unzip", ["-qq", zip.path, "-d", extracted.path])
        for (file, leaf) in Swift.zip(files, names) {
            guard let expected = file.version else { throw RulePolicyError.stale }
            let original = try VerifiedFileReader.hash(root: root, relative: file.relativePath, expected: expected)
            let resultVersion = try VerifiedFileReader.capture(root: extracted, relative: leaf)
            guard try VerifiedFileReader.hash(root: extracted, relative: leaf, expected: resultVersion) == original else { throw RuleExecutionError.verificationFailed }
        }
        let version = try VerifiedFileReader.capture(root: base, relative: "result.zip")
        try SecureRuleIO.copy(root: base, relative: "result.zip", version: version, destinationRoot: destinationRoot, name: name)
    }
}
