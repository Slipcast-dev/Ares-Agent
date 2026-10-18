import CryptoKit
import Darwin
import Foundation

/// Дескрипторы удерживают выбранные inode. Временный результат создаётся на
/// целевом томе, а renameatx_np(RENAME_EXCL) атомарно запрещает перезапись.
struct SecureRuleIO: Sendable {
    static let reserve: UInt64 = 64 * 1024 * 1024
    static func directory(_ root: URL, relative: String = "", create: Bool = false) throws -> FileDescriptor {
        var fd = try FileDescriptor(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        let components = root.path.split(separator: "/").map(String.init)
        guard root.path.hasPrefix("/") else { throw RuleExecutionError.unsafePath }
        let extra = relative.isEmpty ? [] : relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard extra.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else { throw RuleExecutionError.unsafePath }
        for (index, name) in (components + extra).enumerated() {
            if create && index >= components.count {
                guard mkdirat(fd.value, name, 0o700) == 0 || errno == EEXIST else { throw RuleExecutionError.unsafePath }
            }
            let next = withExtendedLifetime(fd) { openat(fd.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            fd = try FileDescriptor(next)
        }
        return fd
    }
    static func identity(_ fd: FileDescriptor) throws -> String {
        var value = stat(); guard withExtendedLifetime(fd, { fstat(fd.value, &value) }) == 0 else { throw RuleExecutionError.unsafePath }
        return "\(value.st_dev):\(value.st_ino)"
    }
    static func space(_ fd: FileDescriptor, bytes: Int64, factor: UInt64 = 1) throws {
        var info = statvfs(); guard withExtendedLifetime(fd, { fstatvfs(fd.value, &info) }) == 0, bytes >= 0 else { throw RulePolicyError.space }
        let (available, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_frsize))
        let (needed, excess) = UInt64(bytes).multipliedReportingOverflow(by: factor)
        let (reserved, full) = needed.addingReportingOverflow(reserve)
        guard !overflow, !excess, !full, available >= reserved else { throw RulePolicyError.space }
    }
    private static func writeAll(_ data: UnsafeRawBufferPointer, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let count = Darwin.write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RuleExecutionError.verificationFailed }; offset += count
        }
    }
    private static func transfer(_ source: FileDescriptor, to output: FileDescriptor) throws -> String {
        var digest = SHA256(); var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(source.value, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RuleExecutionError.verificationFailed }
            if count == 0 { break }
            try buffer.withUnsafeBytes { try writeAll(UnsafeRawBufferPointer(rebasing: $0.prefix(count)), to: output.value) }
            digest.update(data: Data(buffer.prefix(count)))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    /// Открытый source сверяется повторно вместе с актуальным именем. Даже
    /// одинаковые bytes после замены inode не считаются прежней версией плана.
    static func copy(root: URL, relative: String, version: FileVersion, destinationRoot: URL,
                     folder: String = "Ares Results", name: String, beforePublish: (() throws -> Void)? = nil) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != "..", name.utf8.count <= 255 else { throw RuleExecutionError.unsafePath }
        let source = try VerifiedFileReader.openFile(root: root, relative: relative, content: true)
        guard try VerifiedFileReader.version(source) == version else { throw RulePolicyError.stale }
        let parent = try directory(destinationRoot, relative: folder, create: true)
        let parentID = try identity(parent)
        try space(parent, bytes: version.byteSize)
        let temporary = ".ares-" + UUID().uuidString
        let output = try FileDescriptor(openat(parent.value, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        defer { unlinkat(parent.value, temporary, 0) }
        let hash = try transfer(source, to: output)
        guard fsync(output.value) == 0, lseek(output.value, 0, SEEK_SET) == 0 else { throw RuleExecutionError.verificationFailed }
        try beforePublish?()
        // Независимое повторное чтение именно записанного inode проверяет copy.
        let sink = try FileDescriptor(open("/dev/null", O_WRONLY | O_CLOEXEC))
        guard try transfer(output, to: sink) == hash,
              try VerifiedFileReader.version(source) == version,
              try VerifiedFileReader.capture(root: root, relative: relative) == version else { throw RulePolicyError.stale }
        try Task.checkCancellation()
        guard try identity(directory(destinationRoot, relative: folder)) == parentID else { throw RuleExecutionError.unsafePath }
        guard renameatx_np(parent.value, temporary, parent.value, name, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw RuleExecutionError.destinationExists }; throw RuleExecutionError.verificationFailed
        }
        guard fsync(parent.value) == 0, try identity(directory(destinationRoot, relative: folder)) == parentID else { throw RuleExecutionError.verificationFailed }
    }
    static func singleLink(root: URL, relative: String, version: FileVersion) throws {
        let fd = try VerifiedFileReader.openFile(root: root, relative: relative, content: false)
        guard try VerifiedFileReader.version(fd) == version else { throw RulePolicyError.stale }
        var info = stat()
        guard fstat(fd.value, &info) == 0 else { throw RuleExecutionError.unsafePath }
        // Изменение xattr затрагивает весь inode, включая hardlink за границей
        // выбранной папки. Для такого файла разрешаем чтение/копию, но не теги.
        guard info.st_nlink == 1 else { throw RulePolicyError.permission }
    }
    static func tag(root: URL, relative: String, version: FileVersion, value: String, remove: Bool) throws {
        let fd = try VerifiedFileReader.openFile(root: root, relative: relative, content: true)
        guard try VerifiedFileReader.version(fd) == version else { throw RulePolicyError.stale }
        try singleLink(root: root, relative: relative, version: version)
        let key = "com.apple.metadata:_kMDItemUserTags"
        let count = fgetxattr(fd.value, key, nil, 0, 0, 0)
        guard count <= 65_536 else { throw RuleExecutionError.invalidConfiguration }
        var tags: [String] = []
        if count > 0 {
            var data = Data(count: count)
            let actual = data.withUnsafeMutableBytes { fgetxattr(fd.value, key, $0.baseAddress, $0.count, 0, 0) }
            guard actual == count, let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { throw RuleExecutionError.verificationFailed }
            tags = decoded
        } else if count < 0 && errno != ENOATTR { throw RuleExecutionError.verificationFailed }
        // Finder сохраняет цвет после newline. Не теряем цвет чужих тегов.
        let originalTags = tags
        if remove { tags.removeAll { $0.components(separatedBy: "\n")[0] == value } }
        else if !tags.contains(where: { $0.components(separatedBy: "\n")[0] == value }) { tags.append(value) }
        if tags == originalTags {
            guard try VerifiedFileReader.capture(root: root, relative: relative) == version else { throw RulePolicyError.stale }
            return // Не меняем ctime при уже достигнутом состоянии тега.
        }
        let encoded = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        try Task.checkCancellation()
        guard try VerifiedFileReader.capture(root: root, relative: relative) == version else { throw RulePolicyError.stale }
        let result = encoded.withUnsafeBytes { fsetxattr(fd.value, key, $0.baseAddress, $0.count, 0, 0) }
        guard result == 0, try identity(fd) == VerifiedFileReader.capture(root: root, relative: relative).identity else { throw RuleExecutionError.verificationFailed }
    }
    static func shortName(_ value: String) -> String {
        var value = value
        while value.utf8.count > 180 { value.removeLast() }
        return value
    }
}
