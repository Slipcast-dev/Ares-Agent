import Foundation
@preconcurrency import SQLite3
import XCTest
import EcosystemLocalIPC
import EcosystemRuntimeSupport
@testable import FileOrganizerCore

/// Реальный SQLite доказывает порядок/keyset и предел выдачи; fixture не
/// содержит пользовательских файлов или приватных путей/receipt summaries.
final class RuleHistoryPagingTests: XCTestCase {
    private func fixture() throws -> (URL, SQLiteFileRepository) {
        let directory = URL(fileURLWithPath: "/private/tmp/ares-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("store.sqlite")
        let container = AppContainer(databaseURL: database, allowLocalClient: false)
        try container.preparePersistentStore()
        return (directory, SQLiteFileRepository(databaseURL: database))
    }
    private func run(rule: AutomationRule, count: Int, created: Date) -> RuleRun {
        var run = RuleRun(rule: rule, origin: "test"); run.createdAt = created; run.status = "completed"
        run.results = (0..<count).map { index in RuleActionResult(actionID: UUID(), kind: .log,
            relativePath: "synthetic-\(index)", status: "completed", message: "PRIVATE-MESSAGE-MUST-NOT-EXPORT") }
        return run
    }
    func testAllPagesStayStableAcrossConcurrentAppendAndRepositoryRestart() async throws {
        let (directory, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let rule = AutomationRule(), date = Date(timeIntervalSince1970: 1_800_000_000)
        var runs: [RuleRun] = []
        for index in 0..<110 {
            let value = run(rule: rule, count: index.isMultiple(of: 3) ? 0 : 5, created: date.addingTimeInterval(Double(index / 4)))
            runs.append(value); try await repository.saveRuleObject(value, id: value.id.uuidString, table: .runs)
        }
        let ordered = runs.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
        let expected = ordered.flatMap { value in value.results.isEmpty ? [value.id.uuidString + ":empty"] : value.results.map { value.id.uuidString + ":" + $0.actionID.uuidString } }
        var page = try await repository.ruleHistoryPage(ruleID: rule.id, runID: nil, offset: 0, cursor: nil)
        XCTAssertEqual(page.items.count, 100)
        let new = run(rule: rule, count: 10, created: date.addingTimeInterval(100))
        try await repository.saveRuleObject(new, id: new.id.uuidString, table: .runs)
        let reopened = SQLiteFileRepository(databaseURL: directory.appendingPathComponent("store.sqlite"))
        var seen: [String] = []
        while true {
            XCTAssertLessThanOrEqual(page.items.count, 100)
            seen += page.items.map { $0.runID.uuidString + ":" + ($0.actionID?.uuidString ?? "empty") }
            guard let cursor = page.nextCursor else { break }
            page = try await reopened.ruleHistoryPage(ruleID: rule.id, runID: nil, offset: 0, cursor: cursor)
        }
        XCTAssertEqual(seen, expected); XCTAssertEqual(Set(seen).count, expected.count)
        let fresh = try await reopened.ruleHistoryPage(ruleID: rule.id, runID: nil, offset: 0, cursor: nil)
        XCTAssertEqual(fresh.items.first?.runID, new.id)
    }
    func testLegacyOffsetsAndSingleRunReturnOnlyBoundedPublicResults() async throws {
        let (directory, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let rule = AutomationRule(); let value = run(rule: rule, count: 1005, created: Date())
        try await repository.saveRuleObject(value, id: value.id.uuidString, table: .runs)
        let page = try await repository.ruleHistoryPage(ruleID: rule.id, runID: nil, offset: 100, cursor: nil)
        XCTAssertEqual(page.items.map(\.actionID), value.results[100..<200].map { Optional($0.actionID) })
        let detail = try await repository.ruleHistoryPage(ruleID: rule.id, runID: value.id, offset: 1000, cursor: nil)
        XCTAssertEqual(detail.items.count, 5); XCTAssertNil(detail.nextOffset)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(detail), as: UTF8.self).contains("PRIVATE-MESSAGE"))
        let beyond = try await repository.ruleHistoryPage(ruleID: rule.id, runID: nil, offset: 100_000, cursor: nil)
        XCTAssertTrue(beyond.items.isEmpty)
        var cursor: String?, seen: [UUID] = [], pages = 0
        repeat {
            let current = try await repository.ruleHistoryPage(ruleID: rule.id, runID: nil, offset: 0, cursor: cursor)
            seen += current.items.compactMap(\.actionID); cursor = current.nextCursor; pages += 1
            guard pages <= 11 else { return XCTFail("Single-run cursor loop") }
        } while cursor != nil
        XCTAssertEqual(pages, 11); XCTAssertEqual(seen, value.results.map(\.actionID))
        XCTAssertEqual(Set(seen).count, 1005)
    }
    func testCursorIsRuleBoundAndRejectsChangedInFlightRun() async throws {
        let (directory, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let rule = AutomationRule(); var value = run(rule: rule, count: 150, created: Date())
        try await repository.saveRuleObject(value, id: value.id.uuidString, table: .runs)
        let page = try await repository.ruleHistoryPage(ruleID: rule.id, runID: nil, offset: 0, cursor: nil)
        let cursor = try XCTUnwrap(page.nextCursor)
        await invalid { _ = try await repository.ruleHistoryPage(ruleID: UUID(), runID: nil, offset: 0, cursor: cursor) }
        value.results.append(RuleActionResult(actionID: UUID(), kind: .log, relativePath: "new", status: "completed", message: "private"))
        try await repository.saveRuleObject(value, id: value.id.uuidString, table: .runs)
        await invalid { _ = try await repository.ruleHistoryPage(ruleID: rule.id, runID: nil, offset: 0, cursor: cursor) }
    }
    func testMalformedCursorAndOffsetsFailClosedAndMissingRunDoesNotLeak() async throws {
        let (directory, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        for offset in [-1, 100_001] { await invalid { _ = try await repository.ruleHistoryPage(ruleID: id, runID: nil, offset: offset, cursor: nil) } }
        for cursor in ["", "broken", String(repeating: "a", count: 2049), Data("{}".utf8).base64EncodedString()] {
            await invalid { _ = try await repository.ruleHistoryPage(ruleID: id, runID: nil, offset: 0, cursor: cursor) }
        }
        do { _ = try await repository.ruleHistoryPage(ruleID: id, runID: UUID(), offset: 0, cursor: nil); XCTFail("Missing run disclosed") }
        catch { XCTAssertEqual(error as? RuleHistoryFailure, .missingRun) }
    }
    func testNativeSQLitePlanUsesHistoryIndexAndRowIDSurvivesRunUpdate() async throws {
        let (directory, repository) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let rule = AutomationRule(); var value = run(rule: rule, count: 5, created: Date())
        try await repository.saveRuleObject(value, id: value.id.uuidString, table: .runs)
        _ = try await repository.ruleHistoryPage(ruleID: rule.id, runID: nil, offset: 0, cursor: nil)
        let before = try rowID(database: directory.appendingPathComponent("store.sqlite"), id: value.id)
        value.status = "partial_or_failed"; try await repository.saveRuleObject(value, id: value.id.uuidString, table: .runs)
        XCTAssertEqual(try rowID(database: directory.appendingPathComponent("store.sqlite"), id: value.id), before)
        var database: OpaquePointer?; XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("store.sqlite").path, &database), SQLITE_OK)
        let db = try XCTUnwrap(database); defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "EXPLAIN QUERY PLAN SELECT id FROM rule_runs WHERE json_extract(CAST(payload AS TEXT),'$.ruleID')=? AND (json_extract(CAST(payload AS TEXT),'$.createdAt'),id)<(?,?) ORDER BY json_extract(CAST(payload AS TEXT),'$.createdAt') DESC,id DESC LIMIT 1"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement); defer { sqlite3_finalize(query) }
        var details: [String] = []
        while sqlite3_step(query) == SQLITE_ROW { if let text = sqlite3_column_text(query, 3) { details.append(String(cString: text)) } }
        XCTAssertTrue(details.contains { $0.contains("rule_runs_history_v1") })
        XCTAssertFalse(details.contains { $0.contains("TEMP B-TREE") })
    }
    private func rowID(database: URL, id: UUID) throws -> Int64 {
        var databasePointer: OpaquePointer?; XCTAssertEqual(sqlite3_open(database.path, &databasePointer), SQLITE_OK)
        let db = try XCTUnwrap(databasePointer); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT rowid FROM rule_runs WHERE id='\(id.uuidString)'", -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement); defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW); return sqlite3_column_int64(query, 0)
    }
    private func invalid(_ action: () async throws -> Void) async {
        do { try await action(); XCTFail("Invalid history request accepted") }
        catch { XCTAssertEqual(error as? RuleHistoryFailure, .invalidRequest) }
    }
}

/// Через настоящий runtime API cursor не обходит актуальный grant и не
/// раскрывает private message в публичной проекции run/results.
extension AccessPolicyAresTests {
    func testRuleHistoryCursorCannotSurviveRevokedGrantOrExposeMessages() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.base) }
        var rule = AutomationRule(); rule.rootID = f.root.id; rule.actions = [RuleAction(kind: .log)]
        try await f.container.fileRepository.saveRuleObject(rule, id: rule.id.uuidString, table: .rules)
        var run = RuleRun(rule: rule, origin: "test"); run.status = "completed"
        run.results = (0..<150).map { RuleActionResult(actionID: UUID(), kind: .log, relativePath: "synthetic-\($0)", status: "completed", message: "PRIVATE-HISTORY-MESSAGE") }
        try await f.container.fileRepository.saveRuleObject(run, id: run.id.uuidString, table: .runs)
        let approved = try await grant(f, client: .codex, roots: [f.root.id])
        let first = try await f.service.handle(role: .mcp, clientID: .codex,
            request: LocalRPCRequest(domain: "ares", operation: "rule.history", payload: LocalWire.encode(RuleControlRequest(ruleID: rule.id))))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let cursor = try XCTUnwrap(object["nextCursor"] as? String)
        XCTAssertEqual((object["items"] as? [[String: Any]])?.count, 100)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("PRIVATE-HISTORY-MESSAGE"))
        let detail = try await f.service.handle(role: .gui, request: LocalRPCRequest(domain: "ares", operation: "rule.history",
            payload: LocalWire.encode(RuleControlRequest(ruleID: rule.id, runID: run.id))))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: detail) as? [String: Any])?["nextOffset"] as? Int, 100)
        _ = try await f.policy.revoke(approved.id, role: .gui)
        do {
            _ = try await f.service.handle(role: .mcp, clientID: .codex,
                request: LocalRPCRequest(domain: "ares", operation: "rule.history", payload: LocalWire.encode(RuleControlRequest(ruleID: rule.id, cursor: cursor))))
            XCTFail("Revoked cursor read history")
        } catch { XCTAssertEqual(error as? LocalRuntimeFailure, .denied) }
    }
}
