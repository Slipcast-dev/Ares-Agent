@preconcurrency import SQLite3
import Foundation

/// Ошибки локального хранилища не включают SQL и приватные пути в публичный
/// текст. Диагностическая строка SQLite сохраняется только в значении ошибки,
/// которое вызывающий код может обработать без показа пользователю как есть.
public enum SQLiteMigrationError: Error, LocalizedError {
    case openDatabaseFailed(String)
    case executionFailed(String)
    case invalidMigrationVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .openDatabaseFailed:
            return "Не удалось открыть локальное хранилище Ares."
        case .executionFailed:
            return "Не удалось обновить структуру локального хранилища."
        case let .invalidMigrationVersion(version):
            return "Некорректная версия миграции: \(version)."
        }
    }
}

/// Общий контракт мигратора облегчает подмену на тестовую реализацию, не связывая
/// контейнер зависимостей с SQLite на уровне публичного API.
public protocol DatabaseMigrating: Sendable {
    func migrate() throws
    func appliedVersion() throws -> Int
}

/// Последовательный исполнитель SQLite-миграций.
///
/// Экземпляр намеренно используется только во время запуска приложения. Все
/// будущие конкурентные обращения к данным будут идти через actor-репозитории,
/// а не через этот низкоуровневый синхронный объект.
public final class SQLiteMigrator: DatabaseMigrating, @unchecked Sendable {
    private let runtimeOwned: Bool
    private let databaseURL: URL
    private let migrations: [DatabaseMigration]

    public init(databaseURL: URL, migrations: [DatabaseMigration] = DatabaseMigrations.all, runtimeOwned: Bool = false) {
        self.runtimeOwned = runtimeOwned
        self.databaseURL = databaseURL
        self.migrations = migrations
    }

    public func migrate() throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        try execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                applied_at REAL NOT NULL
            )
            """,
            database: database
        )

        let currentVersion = try appliedVersion(in: database)
        for migration in migrations.sorted(by: { $0.version < $1.version }) {
            guard migration.version > 0 else {
                throw SQLiteMigrationError.invalidMigrationVersion(migration.version)
            }

            guard migration.version > currentVersion else {
                continue
            }

            try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
            do {
                for statement in migration.statements {
                    try execute(statement, database: database)
                }

                let escapedName = migration.name.replacingOccurrences(of: "'", with: "''")
                try execute(
                    "INSERT INTO schema_migrations(version, name, applied_at) VALUES (\(migration.version), '\(escapedName)', unixepoch())",
                    database: database
                )
                try execute("COMMIT", database: database)
            } catch {
                // Откат обязателен: частичная схема опаснее отсутствующей, потому
                // что сервисы могут ошибочно посчитать её готовой к использованию.
                _ = try? execute("ROLLBACK", database: database)
                throw error
            }
        }
    }

    public func appliedVersion() throws -> Int {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        return try appliedVersion(in: database)
    }

    private func openDatabase() throws -> OpaquePointer {
        try ManagedStoreGuard.validate(databaseURL, runtimeOwned: runtimeOwned)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)

        guard result == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            if let database {
                sqlite3_close(database)
            }
            throw SQLiteMigrationError.openDatabaseFailed(detail)
        }

        return database
    }

    private func appliedVersion(in database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let sql = "SELECT COALESCE(MAX(version), 0) FROM schema_migrations"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteMigrationError.executionFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteMigrationError.executionFailed(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }

        guard result == SQLITE_OK else {
            // `sqlite3_exec` отдаёт изменяемый C-указатель; явное замыкание
            // сохраняет его точный тип и не допускает неявного преобразования
            // в optional при сборке современным компилятором Swift.
            let detail = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            throw SQLiteMigrationError.executionFailed(detail)
        }
    }
}
