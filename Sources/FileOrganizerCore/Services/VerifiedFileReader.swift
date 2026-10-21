import CryptoKit
import Darwin
import Foundation
import EcosystemContracts
import EcosystemRuntimeSupport

/// Версия файла не зависит от UUID строки индекса. Inode/device и обе пары
/// timestamp обнаруживают подмену пути и изменение содержимого между чтениями.
public struct FileVersion: Codable, Equatable, Sendable {
    public let identity: String
    public let byteSize: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    init(_ value: stat) throws {
        guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { throw AresFileFailure.unsafePath }
        identity = "\(value.st_dev):\(value.st_ino)"; byteSize = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
}
/// Один предел для обхода, записи и чтения снимка: разные ограничения приводили
/// бы к успешному сканированию, которое невозможно сохранить или открыть.
/// 100 000 — обязательный набор AC34; правила сохраняют собственную меньшую квоту.
public enum FileAnalysisLimits {
    public static let maximumFiles = 100_000
}

public enum AresFileFailure: String, Error, LocalizedError, Sendable, QueueDomainError {
    public var knownCode: KnownErrorCode {
        switch self {
        case .staleSnapshot, .snapshotRequired: .staleSnapshot
        case .unsafePath: .permissionDenied
        default: .invalidArgument
        }
    }
    case staleSnapshot, snapshotRequired, unsafePath, capacityExceeded, invalidCursor, hashesNotComputed
    public var errorDescription: String? {
        switch self {
        case .staleSnapshot: "Файлы изменились. Обновите список файлов и повторите запрос."
        case .snapshotRequired: "Сначала обновите список файлов этой папки."
        case .unsafePath: "Файл недоступен или путь содержит ссылку."
        case .capacityExceeded: "Папка превышает лимит этого анализа: 100 000 файлов."
        case .invalidCursor: "Страница не соответствует текущему запросу. Начните просмотр заново."
        case .hashesNotComputed: "Сначала выполните вычисление дубликатов."
        }
    }
}

/// RAII закрывает дескрипторы и при throw/cancellation. openat с NOFOLLOW на
/// каждом компоненте запрещает выход через вложенную symlink даже при гонке.
final class FileDescriptor {
    let value: Int32
    init(_ value: Int32) throws { guard value >= 0 else { throw AresFileFailure.unsafePath }; self.value = value }
    deinit { close(value) }
}
public enum VerifiedFileReader {
    static func openFile(root: URL, relative: String, content: Bool) throws -> FileDescriptor {
        let pieces = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.contains("\0"), relative.utf8.count <= 4096,
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw AresFileFailure.unsafePath }
        guard root.path.hasPrefix("/") else { throw AresFileFailure.unsafePath }
        var parent = try FileDescriptor(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        for piece in root.path.split(separator: "/") {
            let next = withExtendedLifetime(parent) { openat(parent.value, String(piece), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            parent = try FileDescriptor(next)
        }
        for piece in pieces.dropLast() {
            let next = withExtendedLifetime(parent) { openat(parent.value, String(piece), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            parent = try FileDescriptor(next)
        }
        // O_NONBLOCK не меняет чтение обычного файла, но не позволяет подмене
        // на FIFO зависнуть в open до проверки fstat и отмены задачи.
        guard let leaf = pieces.last else { throw AresFileFailure.unsafePath }
        return try FileDescriptor(withExtendedLifetime(parent) { openat(parent.value, String(leaf), (content ? O_RDONLY | O_NONBLOCK : O_EVTONLY) | O_NOFOLLOW | O_CLOEXEC) })
    }
    static func version(_ file: FileDescriptor) throws -> FileVersion {
        var info = stat(); guard withExtendedLifetime(file, { fstat(file.value, &info) }) == 0 else { throw AresFileFailure.unsafePath }
        return try FileVersion(info)
    }
    public static func capture(root: URL, relative: String) throws -> FileVersion {
        try version(openFile(root: root, relative: relative, content: false))
    }
    /// PDFKit/Vision получают готовые bytes, а не повторно открывают изменяемый
    /// путь. Это закрывает TOCTOU между metadata-проверкой и системным декодером.
    static func data(root: URL, relative: String, expected: FileVersion, maximumBytes: Int = 10_000_000) throws -> Data {
        guard expected.byteSize <= Int64(maximumBytes), maximumBytes >= 0 else { throw AresFileFailure.staleSnapshot }
        let file = try openFile(root: root, relative: relative, content: true)
        guard try version(file) == expected else { throw AresFileFailure.staleSnapshot }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(file.value, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AresFileFailure.unsafePath }
            if count == 0 { break }
            guard result.count + count <= maximumBytes else { throw AresFileFailure.staleSnapshot }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == expected.byteSize, try version(file) == expected,
              try capture(root: root, relative: relative) == expected else { throw AresFileFailure.staleSnapshot }
        return result
    }
    public static func hash(root: URL, relative: String, expected: FileVersion) throws -> String {
        let file = try openFile(root: root, relative: relative, content: true)
        guard try version(file) == expected else { throw AresFileFailure.staleSnapshot }
        var hash = SHA256(); var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { read(file.value, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw AresFileFailure.unsafePath }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        // Проверяем и открытый inode, и текущее имя: rename во время hashing
        // не должен прикрепить digest старого inode к новой записи пути.
        guard try version(file) == expected, try capture(root: root, relative: relative) == expected else { throw AresFileFailure.staleSnapshot }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
