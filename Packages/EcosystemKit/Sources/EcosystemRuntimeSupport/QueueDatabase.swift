@preconcurrency import SQLite3
import Darwin
import Foundation

enum SQLValue {
    case text(String), integer(Int64), real(Double), blob(Data), null
}

/// Синхронный SQLite-слой используется только внутри DurableTaskQueue actor.
/// RAII закрывает handle; ошибки наружу не содержат SQL, путей или raw stderr.
final class QueueDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(directory: URL) throws {
        let url = directory.appendingPathComponent("tasks-v1.sqlite3")
        // SQLite открывает sidecar файлы сам. Не принимаем существующий symlink
        // ни для БД, ни для WAL/SHM; управляемый каталог закрыт режимом 0700.
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            var info = stat()
            if lstat(path, &info) == 0 && (info.st_mode & S_IFMT != S_IFREG || info.st_uid != geteuid() || info.st_nlink != 1) {
                throw QueueFailure.unsafeStorage
            }
        }
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw QueueFailure.unsafeStorage }
        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0, fileInfo.st_uid == geteuid(),
              fileInfo.st_mode & S_IFMT == S_IFREG, fileInfo.st_nlink == 1,
              fileInfo.st_mode & 0o077 == 0 else { close(fd); throw QueueFailure.unsafeStorage }
        close(fd)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let db else { if let db { sqlite3_close(db) }; throw QueueFailure.storageFailure }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        // Не меняем journal mode неизвестной БД. application_id отличает
        // собственное хранилище от случайно переданного пользовательского файла.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if size > 0 {
            guard try query("PRAGMA application_id").first?.integer("application_id") == 0x45435131,
                  try query("PRAGMA user_version").first?.integer("user_version") == 1 else {
                throw QueueFailure.incompatibleStorage
            }
        } else {
            try query("PRAGMA application_id=1162039601")
            try query("PRAGMA user_version=1")
        }
        try query("PRAGMA journal_mode=WAL")
        try query("PRAGMA synchronous=FULL")
        try query("PRAGMA foreign_keys=ON")
    }
    deinit { sqlite3_close(handle) }

    @discardableResult
    func query(_ sql: String, _ arguments: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw QueueFailure.storageFailure
        }
        defer { sqlite3_finalize(prepared) }
        guard sqlite3_bind_parameter_count(prepared) == arguments.count else { throw QueueFailure.storageFailure }
        for (offset, argument) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch argument {
            case .text(let value):
                guard value.utf8.count <= Int32.max else { throw QueueFailure.invalidArgument }
                // Явная длина сохраняет embedded NUL в idempotency key.
                result = value.withCString { sqlite3_bind_text(prepared, index, $0, Int32(value.utf8.count), transient) }
            case .integer(let value): result = sqlite3_bind_int64(prepared, index, value)
            case .real(let value):
                guard value.isFinite else { throw QueueFailure.invalidArgument }
                result = sqlite3_bind_double(prepared, index, value)
            case .blob(let value):
                if value.isEmpty { result = sqlite3_bind_zeroblob(prepared, index, 0) }
                else { result = value.withUnsafeBytes { sqlite3_bind_blob(prepared, index, $0.baseAddress, Int32($0.count), transient) } }
            case .null: result = sqlite3_bind_null(prepared, index)
            }
            guard result == SQLITE_OK else { throw QueueFailure.storageFailure }
        }
        var rows: [[String: SQLValue]] = []
        while true {
            let step = sqlite3_step(prepared)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw step == SQLITE_FULL ? QueueFailure.storageFull : QueueFailure.storageFailure }
            var row: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(prepared) {
                let key = String(cString: sqlite3_column_name(prepared, index))
                switch sqlite3_column_type(prepared, index) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(prepared, index))
                case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(prepared, index))
                case SQLITE_TEXT:
                    guard let pointer = sqlite3_column_text(prepared, index) else { throw QueueFailure.corruptStorage }
                    let count = Int(sqlite3_column_bytes(prepared, index))
                    guard let text = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8) else {
                        throw QueueFailure.corruptStorage
                    }
                    row[key] = .text(text)
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(prepared, index))
                    if size == 0 { row[key] = .blob(Data()) }
                    else {
                        guard let pointer = sqlite3_column_blob(prepared, index) else { throw QueueFailure.corruptStorage }
                        row[key] = .blob(Data(bytes: pointer, count: size))
                    }
                default: row[key] = .null
                }
            }
            rows.append(row)
        }
    }
    func transaction<T>(_ operation: () throws -> T) throws -> T {
        try query("BEGIN IMMEDIATE")
        do { let result = try operation(); try query("COMMIT"); return result }
        catch { _ = try? query("ROLLBACK"); throw error }
    }
}

extension Dictionary where Key == String, Value == SQLValue {
    func text(_ key: String) throws -> String {
        guard case .text(let value) = self[key] else { throw QueueFailure.corruptStorage }; return value
    }
    func integer(_ key: String) throws -> Int64 {
        guard case .integer(let value) = self[key] else { throw QueueFailure.corruptStorage }; return value
    }
    func blob(_ key: String) throws -> Data {
        guard case .blob(let value) = self[key] else { throw QueueFailure.corruptStorage }; return value
    }
}
