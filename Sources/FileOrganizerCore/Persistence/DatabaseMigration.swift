import Foundation

/// Одна идемпотентно применяемая миграция схемы. Идентификатор монотонно растёт;
/// SQLiteMigrator записывает его в служебную таблицу только после успешного SQL.
public struct DatabaseMigration: Equatable, Sendable {
    public let version: Int
    public let name: String
    public let statements: [String]

    public init(version: Int, name: String, statements: [String]) {
        self.version = version
        self.name = name
        self.statements = statements
    }
}

/// Централизованный список миграций. SQL расположен рядом с версией, а не в
/// строковых литералах сервисов, чтобы новую установку и обновление можно было
/// проверить одинаковым набором тестов.
public enum DatabaseMigrations {
    public static let all: [DatabaseMigration] = [
        DatabaseMigration(
            version: 1,
            name: "Create initial local metadata schema",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS authorized_roots (
                    id TEXT PRIMARY KEY NOT NULL,
                    display_name TEXT NOT NULL,
                    relative_path_hint TEXT NOT NULL,
                    bookmark_data BLOB NOT NULL,
                    created_at REAL NOT NULL,
                    last_scanned_at REAL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS agent_tasks (
                    id TEXT PRIMARY KEY NOT NULL,
                    root_id TEXT NOT NULL,
                    origin TEXT NOT NULL,
                    correlation_id TEXT,
                    status TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS organization_plans (
                    id TEXT PRIMARY KEY NOT NULL,
                    root_id TEXT NOT NULL,
                    origin TEXT NOT NULL,
                    correlation_id TEXT,
                    created_at REAL NOT NULL
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS organization_plan_actions (
                    id TEXT PRIMARY KEY NOT NULL,
                    plan_id TEXT NOT NULL,
                    action_kind TEXT NOT NULL,
                    source_relative_path TEXT,
                    destination_relative_path TEXT,
                    reason TEXT NOT NULL,
                    is_selected INTEGER NOT NULL CHECK (is_selected IN (0, 1)),
                    FOREIGN KEY(plan_id) REFERENCES organization_plans(id) ON DELETE CASCADE
                )
                """,
                """
                CREATE TABLE IF NOT EXISTS audit_events (
                    id TEXT PRIMARY KEY NOT NULL,
                    origin TEXT NOT NULL,
                    correlation_id TEXT,
                    event_type TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    summary TEXT NOT NULL
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_agent_tasks_root_created ON agent_tasks(root_id, created_at DESC)",
                "CREATE INDEX IF NOT EXISTS idx_audit_events_created ON audit_events(created_at DESC)"
            ]
        ),
        DatabaseMigration(
            version: 2,
            name: "Create local file index",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS file_records (
                    id TEXT PRIMARY KEY NOT NULL,
                    root_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    file_name TEXT NOT NULL,
                    file_extension TEXT NOT NULL,
                    byte_size INTEGER NOT NULL,
                    created_at REAL,
                    modified_at REAL,
                    type_identifier TEXT,
                    UNIQUE(root_id, relative_path)
                )
                """,
                "CREATE INDEX IF NOT EXISTS idx_file_records_root_size ON file_records(root_id, byte_size DESC)",
                "CREATE INDEX IF NOT EXISTS idx_file_records_root_name ON file_records(root_id, file_name)"
            ]
        ),
        DatabaseMigration(
            version: 3,
            name: "Add content hashes for exact duplicate detection",
            statements: [
                "ALTER TABLE file_records ADD COLUMN content_hash TEXT",
                "CREATE INDEX IF NOT EXISTS idx_file_records_root_size_hash ON file_records(root_id, byte_size, content_hash)"
            ]
        ),
        DatabaseMigration(
            version: 4,
            name: "Create local AI provider profiles",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS ai_provider_profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    endpoint TEXT NOT NULL,
                    secret_reference TEXT
                )
                """
            ]
        ),
        DatabaseMigration(
            version: 5,
            name: "Persist user review requests",
            statements: [
                """
                CREATE TABLE IF NOT EXISTS pending_plan_reviews (
                    plan_id TEXT PRIMARY KEY NOT NULL,
                    requested_at REAL NOT NULL,
                    FOREIGN KEY(plan_id) REFERENCES organization_plans(id) ON DELETE CASCADE
                )
                """
            ]
        ),
        DatabaseMigration(
            version: 6,
            name: "Remove discontinued organization plans",
            statements: [
                "DROP TABLE IF EXISTS pending_plan_reviews",
                "DROP TABLE IF EXISTS organization_plan_actions",
                "DROP TABLE IF EXISTS organization_plans"
            ]
        ),
        DatabaseMigration(
            version: 7,
            name: "Persist automation rules, observations and execution journal",
            statements: [
                "CREATE TABLE automation_rules (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)",
                "CREATE TABLE rule_observations (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)",
                "CREATE TABLE rule_runs (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)",
                "CREATE TABLE rule_receipts (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)"
            ]
        ),
        DatabaseMigration(version: 8, name: "Save selected AI model in provider profiles", statements: [
            "ALTER TABLE ai_provider_profiles ADD COLUMN model_name TEXT"
        ]),
        DatabaseMigration(version: 9, name: "Publish versioned file snapshots", statements: [
            "CREATE TABLE file_snapshot_state (root_id TEXT PRIMARY KEY NOT NULL, generation INTEGER NOT NULL, document BLOB)",
            "CREATE TABLE file_snapshot_records (root_id TEXT NOT NULL, record_id TEXT NOT NULL, document BLOB NOT NULL, PRIMARY KEY(root_id,record_id))"
        ]),
        DatabaseMigration(version: 10, name: "Persist rule plans and local permissions", statements: [
            "CREATE TABLE rule_plans (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)",
            "CREATE TABLE rule_permissions (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)"
        ])
    ]
}
