@preconcurrency import SQLite3
import Foundation

/// Локальное хранилище корней и индекса. Actor сериализует доступ к SQLite:
/// это устраняет гонки между будущим UI, фоновым сканированием и MCP-мостом.
public actor SQLiteFileRepository: FileRepository {
    private let runtimeOwned: Bool
    private let databaseURL: URL
    private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL, runtimeOwned: Bool = false) {
        self.runtimeOwned = runtimeOwned
        self.databaseURL = databaseURL
    }

    public func save(root: AuthorizedRoot, bookmarkData: Data) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let sql = """
        INSERT INTO authorized_roots(id, display_name, relative_path_hint, bookmark_data, created_at, last_scanned_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            display_name = excluded.display_name,
            relative_path_hint = excluded.relative_path_hint,
            bookmark_data = excluded.bookmark_data,
            last_scanned_at = excluded.last_scanned_at
        """
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }

        try bind(root.id.uuidString, to: statement, at: 1)
        try bind(root.displayName, to: statement, at: 2)
        try bind(root.relativePathHint, to: statement, at: 3)
        try bind(bookmarkData, to: statement, at: 4)
        try bind(root.createdAt.timeIntervalSince1970, to: statement, at: 5)
        try bind(root.lastScannedAt?.timeIntervalSince1970, to: statement, at: 6)
        try stepDone(statement, database: database)
    }

    public func fetchRoots() throws -> [AuthorizedRoot] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }

        let statement = try prepare(
            "SELECT id, display_name, relative_path_hint, created_at, last_scanned_at FROM authorized_roots ORDER BY display_name COLLATE NOCASE",
            database: database
        )
        defer { sqlite3_finalize(statement) }

        var roots: [AuthorizedRoot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, at: 0), let id = UUID(uuidString: idText),
                  let displayName = columnText(statement, at: 1),
                  let pathHint = columnText(statement, at: 2) else {
                continue
            }
            roots.append(
                AuthorizedRoot(
                    id: id,
                    displayName: displayName,
                    relativePathHint: pathHint,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    lastScannedAt: sqlite3_column_type(statement, 4) == SQLITE_NULL
                        ? nil
                        : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                )
            )
        }
        return roots
    }

    public func root(withID id: UUID) throws -> AuthorizedRoot? {
        try fetchRoots().first { $0.id == id }
    }

    /// Отзывает сохранённый доступ одной транзакцией. Удаляется только локальная
    /// информация; файловых API здесь нет, поэтому содержимое папки сохраняется.
    public func removeRoot(withID id: UUID) throws {
        let affectedRules = try ruleObjects(AutomationRule.self, table: .rules).filter {
            $0.rootID == id || $0.actions.contains { $0.destinationRootID == id }
        }
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            let busy = try prepare("SELECT 1 FROM agent_tasks WHERE root_id = ? AND status IN ('queued', 'running') LIMIT 1", database: database)
            defer { sqlite3_finalize(busy) }
            try bind(id.uuidString, to: busy, at: 1)
            guard sqlite3_step(busy) != SQLITE_ROW else { throw TaskCoordinatorError.rootBusy }
            for table in ["file_snapshot_records", "file_snapshot_state"] {
                let deletion = try prepare("DELETE FROM " + table + " WHERE root_id=?", database: database)
                defer { sqlite3_finalize(deletion) }
                try bind(id.uuidString, to: deletion, at: 1); try stepDone(deletion, database: database)
            }
            // Сначала удаляются дочерние записи, поскольку старые версии схемы
            // не включали каскадные внешние ключи для всех таблиц.
            let statements = [
                "DELETE FROM file_records WHERE root_id = ?",
                "DELETE FROM agent_tasks WHERE root_id = ?",
                "DELETE FROM authorized_roots WHERE id = ?"
            ]
            for sql in statements {
                let statement = try prepare(sql, database: database)
                defer { sqlite3_finalize(statement) }
                try bind(id.uuidString, to: statement, at: 1)
                try stepDone(statement, database: database)
            }
            // Отключение зависимых правил входит в ту же транзакцию отзыва.
            // Ошибка SQLite не должна оставить половину изменения committed.
            for var rule in affectedRules {
                rule.enabled = false
                let statement = try prepare("UPDATE automation_rules SET payload=? WHERE id=?", database: database)
                defer { sqlite3_finalize(statement) }
                try bind(JSONEncoder().encode(rule), to: statement, at: 1)
                try bind(rule.id.uuidString, to: statement, at: 2)
                try stepDone(statement, database: database)
            }
            try execute("COMMIT", database: database)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    /// Закладка доступна только внутреннему сервису разрешений и никогда не
    /// выдаётся в MCP-ответе или ViewModel.
    public func bookmarkData(forRootID id: UUID) throws -> Data? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let statement = try prepare("SELECT bookmark_data FROM authorized_roots WHERE id = ?", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let length = Int(sqlite3_column_bytes(statement, 0))
        // Пустой BLOB обозначает импортированный корень без нового grant;
        // nil обозначает отсутствие строки/данных. Не смешиваем эти состояния.
        guard sqlite3_column_type(statement, 0) == SQLITE_BLOB else { return nil }
        if length == 0 { return Data() }
        guard let pointer = sqlite3_column_blob(statement, 0) else { return nil }
        return Data(bytes: pointer, count: length)
    }

    public func replaceIndex(records: [FileRecord], forRootID rootID: UUID) throws {
        _ = try writeIndex(records: records, rootID: rootID, summary: nil)
    }
    public func publishSnapshot(records: [FileRecord], summary: ScanSummary) throws -> FileIndexSnapshot {
        guard let snapshot = try writeIndex(records: records, rootID: summary.rootID, summary: summary) else { throw AresFileFailure.snapshotRequired }
        return snapshot
    }
    private func writeIndex(records: [FileRecord], rootID: UUID, summary: ScanSummary?) throws -> FileIndexSnapshot? {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try execute("BEGIN IMMEDIATE TRANSACTION", database: database)
        do {
            if summary != nil {
                let granted = try prepare("SELECT 1 FROM authorized_roots WHERE id=? AND length(bookmark_data)>0", database: database)
                try bind(rootID.uuidString, to: granted, at: 1); let present = sqlite3_step(granted) == SQLITE_ROW; sqlite3_finalize(granted)
                guard present else { throw AresFileFailure.snapshotRequired }
            }
            let deleteStatement = try prepare("DELETE FROM file_records WHERE root_id = ?", database: database)
            try bind(rootID.uuidString, to: deleteStatement, at: 1)
            try stepDone(deleteStatement, database: database)
            sqlite3_finalize(deleteStatement)

            let insertStatement = try prepare(
                """
                INSERT INTO file_records(
                    id, root_id, relative_path, file_name, file_extension, byte_size,
                    created_at, modified_at, type_identifier
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                database: database
            )
            defer { sqlite3_finalize(insertStatement) }

            for record in records {
                try bind(record.id.uuidString, to: insertStatement, at: 1)
                try bind(rootID.uuidString, to: insertStatement, at: 2)
                try bind(record.relativePath, to: insertStatement, at: 3)
                try bind(record.fileName, to: insertStatement, at: 4)
                try bind(record.fileExtension, to: insertStatement, at: 5)
                try bind(record.byteSize, to: insertStatement, at: 6)
                try bind(record.createdAt?.timeIntervalSince1970, to: insertStatement, at: 7)
                try bind(record.modifiedAt?.timeIntervalSince1970, to: insertStatement, at: 8)
                try bind(record.typeIdentifier, to: insertStatement, at: 9)
                try stepDone(insertStatement, database: database)
                sqlite3_reset(insertStatement)
                sqlite3_clear_bindings(insertStatement)
            }
            let existing = try prepare("SELECT generation FROM file_snapshot_state WHERE root_id=?", database: database)
            try bind(rootID.uuidString, to: existing, at: 1)
            let generation = sqlite3_step(existing) == SQLITE_ROW ? sqlite3_column_int64(existing, 0) : 0
            sqlite3_finalize(existing)
            guard generation < Int64.max else { throw AresFileFailure.capacityExceeded }
            let removal = try prepare("DELETE FROM file_snapshot_records WHERE root_id=?", database: database)
            try bind(rootID.uuidString, to: removal, at: 1); try stepDone(removal, database: database); sqlite3_finalize(removal)
            var published: FileIndexSnapshot?
            if let summary {
                guard records.count <= 50_000, records.allSatisfy({ $0.rootID == rootID && $0.version != nil }),
                      summary.indexedFileCount == records.count else { throw AresFileFailure.snapshotRequired }
                let header = FileSnapshotHeader(id: UUID(), rootID: rootID, generation: generation + 1, indexedAt: Date(),
                    fileCount: records.count, totalByteSize: summary.totalByteSize, skippedCount: summary.skippedItemCount, hashesComputed: false, hashesVerifiedAt: nil)
                published = FileIndexSnapshot(header: header, records: records.sorted { $0.relativePath < $1.relativePath })
                let insertion = try prepare("INSERT INTO file_snapshot_records VALUES (?,?,?)", database: database)
                defer { sqlite3_finalize(insertion) }
                for record in records {
                    try bind(rootID.uuidString, to: insertion, at: 1); try bind(record.id.uuidString, to: insertion, at: 2)
                    try bind(JSONEncoder().encode(record), to: insertion, at: 3); try stepDone(insertion, database: database)
                    sqlite3_reset(insertion); sqlite3_clear_bindings(insertion)
                }
            }
            // Даже legacy replaceIndex инвалидирует старый snapshot. Header,
            // поколения и все строки записываются в одной SQL-транзакции.
            let state = try prepare("INSERT INTO file_snapshot_state VALUES (?,?,?) ON CONFLICT(root_id) DO UPDATE SET generation=excluded.generation,document=excluded.document", database: database)
            defer { sqlite3_finalize(state) }
            try bind(rootID.uuidString, to: state, at: 1); try bind(generation + 1, to: state, at: 2)
            if let published { try bind(JSONEncoder().encode(published.header), to: state, at: 3) }
            else { sqlite3_bind_null(state, 3) }
            try stepDone(state, database: database)
            try execute("COMMIT", database: database)
            return published
        } catch {
            _ = try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    public func currentSnapshot(rootID: UUID) throws -> FileIndexSnapshot? {
        let database = try openDatabase(); defer { sqlite3_close(database) }
        try execute("BEGIN", database: database)
        defer { _ = try? execute("ROLLBACK", database: database) }
        let statement = try prepare("SELECT document FROM file_snapshot_state WHERE root_id=?", database: database)
        defer { sqlite3_finalize(statement) }; try bind(rootID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let header = try JSONDecoder().decode(FileSnapshotHeader.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        let rows = try prepare("SELECT document FROM file_snapshot_records WHERE root_id=?", database: database)
        defer { sqlite3_finalize(rows) }; try bind(rootID.uuidString, to: rows, at: 1)
        var records: [FileRecord] = []
        while sqlite3_step(rows) == SQLITE_ROW {
            guard records.count < 50_000, let pointer = sqlite3_column_blob(rows, 0) else { throw AresFileFailure.capacityExceeded }
            records.append(try JSONDecoder().decode(FileRecord.self, from: Data(bytes: pointer, count: Int(sqlite3_column_bytes(rows, 0)))))
        }
        guard header.rootID == rootID, header.fileCount == records.count else { throw AresFileFailure.staleSnapshot }
        return FileIndexSnapshot(header: header, records: records.sorted { $0.relativePath < $1.relativePath })
    }
    public func publishHashes(rootID: UUID, snapshotID: UUID, hashes: [UUID: String]) throws -> FileIndexSnapshot {
        guard var snapshot = try currentSnapshot(rootID: rootID), snapshot.header.id == snapshotID else { throw AresFileFailure.staleSnapshot }
        let known = Set(Dictionary(grouping: snapshot.records, by: \.byteSize).values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        guard Set(hashes.keys) == known, hashes.values.allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else { throw AresFileFailure.staleSnapshot }
        let database = try openDatabase(); defer { sqlite3_close(database) }
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            for index in snapshot.records.indices {
                let record = snapshot.records[index]
                guard let hash = hashes[record.id] else { continue }
                let updated = FileRecord(id: record.id, rootID: rootID, relativePath: record.relativePath, fileName: record.fileName,
                    fileExtension: record.fileExtension, byteSize: record.byteSize, createdAt: record.createdAt, modifiedAt: record.modifiedAt,
                    typeIdentifier: record.typeIdentifier, contentHash: hash, version: record.version)
                snapshot.records[index] = updated
                // Каждый statement закрывается и при bind/step failure, иначе
                // sqlite3_close оставит открытый connection после rollback.
                do {
                    let row = try prepare("UPDATE file_snapshot_records SET document=? WHERE root_id=? AND record_id=?", database: database)
                    defer { sqlite3_finalize(row) }
                    try bind(JSONEncoder().encode(updated), to: row, at: 1); try bind(rootID.uuidString, to: row, at: 2); try bind(record.id.uuidString, to: row, at: 3)
                    try stepDone(row, database: database)
                }
                do {
                    let legacy = try prepare("UPDATE file_records SET content_hash=? WHERE root_id=? AND id=?", database: database)
                    defer { sqlite3_finalize(legacy) }
                    try bind(hash, to: legacy, at: 1); try bind(rootID.uuidString, to: legacy, at: 2); try bind(record.id.uuidString, to: legacy, at: 3)
                    try stepDone(legacy, database: database)
                }
            }
            snapshot.header.hashesComputed = true; snapshot.header.hashesVerifiedAt = Date()
            let state = try prepare("UPDATE file_snapshot_state SET document=? WHERE root_id=?", database: database)
            defer { sqlite3_finalize(state) }; try bind(JSONEncoder().encode(snapshot.header), to: state, at: 1); try bind(rootID.uuidString, to: state, at: 2)
            try stepDone(state, database: database); try execute("COMMIT", database: database); return snapshot
        } catch { _ = try? execute("ROLLBACK", database: database); throw error }
    }

    public func indexedFileCount(forRootID rootID: UUID) throws -> Int {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let statement = try prepare("SELECT COUNT(*) FROM file_records WHERE root_id = ?", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(rootID.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteFileRepositoryError.queryFailed
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    public func records(forRootID rootID: UUID) throws -> [FileRecord] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let statement = try prepare(
            "SELECT id, relative_path, file_name, file_extension, byte_size, created_at, modified_at, type_identifier, content_hash FROM file_records WHERE root_id = ? ORDER BY relative_path",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(rootID.uuidString, to: statement, at: 1)
        var result: [FileRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, at: 0), let id = UUID(uuidString: idText),
                  let relativePath = columnText(statement, at: 1), let fileName = columnText(statement, at: 2),
                  let fileExtension = columnText(statement, at: 3) else { continue }
            result.append(FileRecord(
                id: id, rootID: rootID, relativePath: relativePath, fileName: fileName,
                fileExtension: fileExtension, byteSize: sqlite3_column_int64(statement, 4),
                createdAt: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                modifiedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                typeIdentifier: columnText(statement, at: 7), contentHash: columnText(statement, at: 8)
            ))
        }
        return result
    }

    public func updateContentHash(_ hash: String, forRecordID recordID: UUID) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let statement = try prepare("UPDATE file_records SET content_hash = ? WHERE id = ?", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(hash, to: statement, at: 1)
        try bind(recordID.uuidString, to: statement, at: 2)
        try stepDone(statement, database: database)
    }

    /// Правило может обнаружить файл раньше ручного сканирования. Добавляем его
    /// в индекс без удаления остальных записей, чтобы переход «Показать файлы»
    /// открывал действительные совпадения. При изменении версии сбрасываем хэш.
    public func upsertRuleFile(_ file: RuleFileSnapshot, rootID: UUID) throws {
        let database = try openDatabase(); defer { sqlite3_close(database) }
        let statement = try prepare("""
            INSERT INTO file_records(id, root_id, relative_path, file_name, file_extension, byte_size, created_at, modified_at)
            SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM authorized_roots WHERE id = ?)
            ON CONFLICT(root_id, relative_path) DO UPDATE SET
                content_hash = CASE WHEN file_records.byte_size = excluded.byte_size AND file_records.modified_at IS excluded.modified_at THEN file_records.content_hash ELSE NULL END,
                byte_size = excluded.byte_size, modified_at = excluded.modified_at, created_at = excluded.created_at
            """, database: database)
        defer { sqlite3_finalize(statement) }
        try bind(UUID().uuidString, to: statement, at: 1)
        try bind(rootID.uuidString, to: statement, at: 2)
        try bind(file.relativePath, to: statement, at: 3)
        try bind((file.relativePath as NSString).lastPathComponent, to: statement, at: 4)
        try bind((file.relativePath as NSString).pathExtension.lowercased(), to: statement, at: 5)
        try bind(file.byteSize, to: statement, at: 6)
        try bind(file.createdAt?.timeIntervalSince1970, to: statement, at: 7)
        try bind(file.modifiedAt?.timeIntervalSince1970, to: statement, at: 8)
        // Проверка в самом INSERT атомарна с записью: отзыв разрешения не
        // позволит позднему результату правила восстановить удалённый индекс.
        try bind(rootID.uuidString, to: statement, at: 9)
        try stepDone(statement, database: database)
    }

    /// Журнал записывается в SQLite, а не в UserDefaults: так он сохраняется
    /// после перезапуска и не смешивается с пользовательскими настройками.
    public func record(_ event: AuditEvent) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let statement = try prepare("INSERT INTO audit_events(id, origin, correlation_id, event_type, created_at, summary) VALUES (?, ?, ?, ?, ?, ?)", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(event.id.uuidString, to: statement, at: 1)
        try bind(event.origin.rawValue, to: statement, at: 2)
        try bind(event.correlationID, to: statement, at: 3)
        try bind(event.eventType, to: statement, at: 4)
        try bind(event.createdAt.timeIntervalSince1970, to: statement, at: 5)
        try bind(event.summary, to: statement, at: 6)
        try stepDone(statement, database: database)
    }

    public func recentEvents(limit: Int) throws -> [AuditEvent] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let statement = try prepare("SELECT id, origin, correlation_id, event_type, created_at, summary FROM audit_events ORDER BY created_at DESC LIMIT ?", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(Int64(max(0, limit)), to: statement, at: 1)
        var events: [AuditEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, at: 0), let id = UUID(uuidString: idText),
                  let originText = columnText(statement, at: 1), let origin = TaskOrigin(rawValue: originText),
                  let type = columnText(statement, at: 3), let summary = columnText(statement, at: 5) else { continue }
            events.append(AuditEvent(id: id, origin: origin, correlationID: columnText(statement, at: 2), eventType: type, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)), summary: summary))
        }
        return events
    }

    public func searchRecords(forRootID rootID: UUID, query: String, limit: Int = 100) throws -> [FileRecord] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let statement = try prepare("SELECT id, relative_path, file_name, file_extension, byte_size, created_at, modified_at, type_identifier, content_hash FROM file_records WHERE root_id = ? AND file_name LIKE ? ESCAPE '\\\\' ORDER BY file_name COLLATE NOCASE LIMIT ?", database: database)
        defer { sqlite3_finalize(statement) }
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        try bind(rootID.uuidString, to: statement, at: 1)
        try bind("%\(escaped)%", to: statement, at: 2)
        try bind(Int64(min(max(limit, 1), 100)), to: statement, at: 3)
        return try readRecords(statement: statement, rootID: rootID)
    }

    public func save(profile: AIProviderProfile) throws {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let statement = try prepare("INSERT OR REPLACE INTO ai_provider_profiles(id, name, kind, endpoint, secret_reference, model_name) VALUES (?, ?, ?, ?, ?, ?)", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(profile.id.uuidString, to: statement, at: 1)
        try bind(profile.name, to: statement, at: 2)
        try bind(profile.kind.rawValue, to: statement, at: 3)
        try bind(profile.endpoint.absoluteString, to: statement, at: 4)
        try bind(profile.secretReference, to: statement, at: 5)
        try bind(profile.modelName, to: statement, at: 6)
        try stepDone(statement, database: database)
    }

    public func fetchProviderProfiles() throws -> [AIProviderProfile] {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        let statement = try prepare("SELECT id, name, kind, endpoint, secret_reference, model_name FROM ai_provider_profiles ORDER BY name COLLATE NOCASE", database: database)
        defer { sqlite3_finalize(statement) }
        var profiles: [AIProviderProfile] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, at: 0), let id = UUID(uuidString: idText), let name = columnText(statement, at: 1), let kindText = columnText(statement, at: 2), let kind = AIProviderKind(rawValue: kindText), let endpointText = columnText(statement, at: 3), let endpoint = URL(string: endpointText), let profile = try? AIProviderProfile(id: id, name: name, kind: kind, endpoint: endpoint, secretReference: columnText(statement, at: 4), modelName: columnText(statement, at: 5)) else { continue }
            profiles.append(profile)
        }
        return profiles
    }

    public func save(task: AgentTask) throws {
        let database = try openDatabase(); defer { sqlite3_close(database) }
        let statement = try prepare("INSERT OR REPLACE INTO agent_tasks(id, root_id, origin, correlation_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?)", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(task.id.uuidString, to: statement, at: 1); try bind(task.rootID.uuidString, to: statement, at: 2)
        try bind(task.origin.rawValue, to: statement, at: 3); try bind(task.correlationID, to: statement, at: 4)
        try bind(task.status.rawValue, to: statement, at: 5); try bind(task.createdAt.timeIntervalSince1970, to: statement, at: 6)
        try stepDone(statement, database: database)
    }

    public func task(withID id: UUID) throws -> AgentTask? {
        let database = try openDatabase(); defer { sqlite3_close(database) }
        let statement = try prepare("SELECT root_id, origin, correlation_id, status, created_at FROM agent_tasks WHERE id = ?", database: database)
        defer { sqlite3_finalize(statement) }; try bind(id.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW, let rootText = columnText(statement, at: 0), let rootID = UUID(uuidString: rootText), let originText = columnText(statement, at: 1), let origin = TaskOrigin(rawValue: originText), let statusText = columnText(statement, at: 3), let status = AgentTaskStatus(rawValue: statusText) else { return nil }
        return AgentTask(id: id, rootID: rootID, origin: origin, correlationID: columnText(statement, at: 2), status: status, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)))
    }

    public func recentTasks(limit: Int = 30) throws -> [AgentTask] {
        let database = try openDatabase(); defer { sqlite3_close(database) }
        let statement = try prepare("SELECT id, root_id, origin, correlation_id, status, created_at FROM agent_tasks ORDER BY created_at DESC LIMIT ?", database: database)
        defer { sqlite3_finalize(statement) }; try bind(Int64(min(max(limit, 1), 100)), to: statement, at: 1)
        var tasks: [AgentTask] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, at: 0), let id = UUID(uuidString: idText), let rootText = columnText(statement, at: 1), let rootID = UUID(uuidString: rootText), let originText = columnText(statement, at: 2), let origin = TaskOrigin(rawValue: originText), let statusText = columnText(statement, at: 4), let status = AgentTaskStatus(rawValue: statusText) else { continue }
            tasks.append(AgentTask(id: id, rootID: rootID, origin: origin, correlationID: columnText(statement, at: 3), status: status, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))))
        }
        return tasks
    }

    private func readRecords(statement: OpaquePointer, rootID: UUID) throws -> [FileRecord] {
        var result: [FileRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = columnText(statement, at: 0), let id = UUID(uuidString: idText),
                  let relativePath = columnText(statement, at: 1), let fileName = columnText(statement, at: 2),
                  let fileExtension = columnText(statement, at: 3) else { continue }
            result.append(FileRecord(id: id, rootID: rootID, relativePath: relativePath, fileName: fileName, fileExtension: fileExtension, byteSize: sqlite3_column_int64(statement, 4), createdAt: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)), modifiedAt: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)), typeIdentifier: columnText(statement, at: 7), contentHash: columnText(statement, at: 8)))
        }
        return result
    }

    /// Таблицы выбираются закрытым enum, а значения связываются параметрами.
    /// JSON позволяет эволюционировать типизированные условия без SQL на каждое поле.
    public enum RuleTable: String, Codable, Sendable { case plans = "rule_plans", permissions = "rule_permissions", rules = "automation_rules", observations = "rule_observations", runs = "rule_runs", receipts = "rule_receipts" }
    public func saveRuleObject<T: Encodable & Sendable>(_ object: T, id: String, table: RuleTable) throws {
        let database = try openDatabase(); defer { sqlite3_close(database) }
        let statement = try prepare("INSERT OR REPLACE INTO \(table.rawValue)(id, payload) VALUES (?, ?)", database: database)
        defer { sqlite3_finalize(statement) }
        try bind(id, to: statement, at: 1)
        try bind(JSONEncoder().encode(object), to: statement, at: 2)
        try stepDone(statement, database: database)
    }
    public func ruleObjects<T: Decodable & Sendable>(_ type: T.Type, table: RuleTable) throws -> [T] {
        let database = try openDatabase(); defer { sqlite3_close(database) }
        let statement = try prepare("SELECT payload FROM \(table.rawValue) ORDER BY rowid DESC", database: database)
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
            result.append(try JSONDecoder().decode(type, from: data))
        }
        return result
    }
    public func ruleObject<T: Decodable & Sendable>(_ type: T.Type, id: String, table: RuleTable) throws -> T? {
        let database = try openDatabase(); defer { sqlite3_close(database) }
        let statement = try prepare("SELECT payload FROM \(table.rawValue) WHERE id = ?", database: database)
        defer { sqlite3_finalize(statement) }; try bind(id, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { return nil }
        return try JSONDecoder().decode(type, from: Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0))))
    }
    public func deleteRule(id: UUID) throws {
        let database = try openDatabase(); defer { sqlite3_close(database) }
        let statement = try prepare("DELETE FROM automation_rules WHERE id = ?", database: database)
        defer { sqlite3_finalize(statement) }; try bind(id.uuidString, to: statement, at: 1)
        try stepDone(statement, database: database)
    }

    private func openDatabase() throws -> OpaquePointer {
        try ManagedStoreGuard.validate(databaseURL, runtimeOwned: runtimeOwned)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw SQLiteFileRepositoryError.openFailed
        }
        return database
    }

    private func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteFileRepositoryError.queryFailed
        }
        return statement
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteFileRepositoryError.queryFailed
        }
    }

    private func stepDone(_ statement: OpaquePointer, database: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteFileRepositoryError.queryFailed
        }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transientDestructor) == SQLITE_OK else {
            throw SQLiteFileRepositoryError.queryFailed
        }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        if value.isEmpty {
            guard sqlite3_bind_zeroblob(statement, index, 0) == SQLITE_OK else { throw SQLiteFileRepositoryError.queryFailed }; return
        }
        let result = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), transientDestructor)
        }
        guard result == SQLITE_OK else { throw SQLiteFileRepositoryError.queryFailed }
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw SQLiteFileRepositoryError.queryFailed
        }
    }

    private func bind(_ value: Double?, to statement: OpaquePointer, at index: Int32) throws {
        let result = value.map { sqlite3_bind_double(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw SQLiteFileRepositoryError.queryFailed }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw SQLiteFileRepositoryError.queryFailed }
            return
        }
        try bind(value, to: statement, at: index)
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }
}

public enum SQLiteFileRepositoryError: Error, LocalizedError, Sendable {
    case openFailed
    case queryFailed

    public var errorDescription: String? {
        switch self {
        case .openFailed: "Не удалось открыть локальный индекс файлов."
        case .queryFailed: "Не удалось обновить локальный индекс файлов."
        }
    }
}
