import Darwin
import Foundation

/// flock принадлежит процессу-владельцу на весь срок жизни очереди. Файл остаётся
/// после crash, но kernel снимает lock; PID-файл без lock этого не обеспечивает.
final class RuntimeOwnershipLease: @unchecked Sendable {
    private let descriptor: Int32
    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw QueueFailure.unsafeStorage }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw QueueFailure.unsafeStorage
        }
        let fd = open(directory.appendingPathComponent("runtime-owner.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw QueueFailure.unsafeStorage }
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(fd); throw QueueFailure.unsafeStorage
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw QueueFailure.ownerBusy }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
