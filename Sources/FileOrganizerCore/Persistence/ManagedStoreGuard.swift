import Foundation
import Darwin
import EcosystemLocalIPC

/// Совместимые legacy GUI/MCP/worker не должны стать вторым writer профильной
/// БД через --database или символьный alias. Runtime получает этот флаг только
/// после захвата OS-lock своей очереди; это защита от случайного смешения режимов.
enum ManagedStoreGuard {
    static func validate(_ file: URL, runtimeOwned: Bool) throws {
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1 else { throw LocalRuntimeFailure.denied }
        }
        let canonical = file.resolvingSymlinksInPath()
        if canonical.lastPathComponent == "tasks-v1.sqlite3", canonical.deletingLastPathComponent().lastPathComponent == "queue" {
            throw LocalRuntimeFailure.denied
        }
        if canonical.lastPathComponent == "domain.sqlite", canonical.deletingLastPathComponent().lastPathComponent == "ares-state", !runtimeOwned {
            throw LocalRuntimeFailure.denied
        }
        if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw LocalRuntimeFailure.denied }
    }
}
