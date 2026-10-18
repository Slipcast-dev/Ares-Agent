import Foundation
import CryptoKit
import EcosystemLocalIPC
import EcosystemRuntimeSupport
import FileOrganizerCore

/// Внешняя проекция исключает локальный request, inode и абсолютные пути.
/// Все даты API — UTC ISO 8601; unknown/uncomputed не подменяются нулём дублей.
enum SnapshotMCP {
    private struct Arguments: Decodable {
        let rootId: UUID?; let taskId: UUID?; let snapshotId: UUID?
        let correlationId: String?; let query: String?; let cursor: String?; let pageSize: Int?; let idempotencyKey: String?
    }
    private struct Job: Encodable { let rootID: UUID; let snapshotID: UUID?; let query: String?; let cursor: String?; let pageSize: Int?; let correlationID: String? }
    private struct Submission: Encodable { let capability: String; let job: Job; let key: String }
    static func call(_ name: String, args: [String: Any], client: LocalRPCClient, context: MCPCallContext? = nil) async throws -> [String: Any] {
        let allowed: Set<String>
        switch name {
        case "file.get_task": allowed = ["taskId"]
        case "file.scan": allowed = ["rootId", "idempotencyKey", "correlationId"]
        case "file.compute_duplicates": allowed = ["rootId", "snapshotId", "idempotencyKey"]
        case "file.search": allowed = ["rootId", "snapshotId", "query", "cursor", "pageSize"]
        case "file.analyze_storage", "file.find_duplicates": allowed = ["rootId", "snapshotId", "cursor", "pageSize"]
        default: throw LocalRuntimeFailure.denied
        }
        guard Set(args.keys).isSubset(of: allowed) else { throw LocalRuntimeFailure.invalidRequest }
        let value = try JSONDecoder().decode(Arguments.self, from: JSONSerialization.data(withJSONObject: args))
        if name == "file.get_task" {
            guard let id = value.taskId else { throw LocalRuntimeFailure.invalidRequest }
            let task: DurableTask = try await client.call("task.get", LocalTaskID(id))
            var result: [String: Any] = ["taskId": task.id.uuidString, "status": task.status.rawValue,
                "capability": task.capabilityID, "errorCode": task.errorCode?.rawValue as Any? ?? NSNull(), "stale": task.errorCode?.rawValue == "STALE_SNAPSHOT"]
            if let data = task.result {
                if task.capabilityID == "file.scan" {
                    let scan = try LocalWire.decode(ScanSummary.self, data)
                    result["result"] = ["snapshotId": scan.snapshotID?.uuidString as Any? ?? NSNull(), "indexGeneration": scan.indexGeneration as Any? ?? NSNull(), "fileCount": scan.indexedFileCount, "skippedCount": scan.skippedItemCount, "totalByteSize": scan.totalByteSize]
                } else if task.capabilityID == "rule.preview" {
                    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                    result["result"] = try JSONSerialization.jsonObject(with: encoder.encode(LocalWire.decode(RulePlanSummary.self, data)))
                } else if task.capabilityID == "rule.run" {
                    let run = try LocalWire.decode(RuleRun.self, data)
                    result["result"] = ["runId": run.id.uuidString, "ruleId": run.ruleID.uuidString, "status": run.status, "matchedCount": run.matchedCount]
                } else { result["result"] = payload(try LocalWire.decode(FileSnapshotPage.self, data)) }
            }
            return result
        }
        guard let root = value.rootId, value.pageSize.map({ (1...100).contains($0) }) ?? true,
              value.query.map({ $0.count <= 120 && !$0.contains("\0") }) ?? true,
              value.cursor.map({ $0.utf8.count < 4096 }) ?? true,
              value.idempotencyKey.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else { throw LocalRuntimeFailure.invalidRequest }
        if let correlation = args["correlationId"], !(correlation is String) { throw LocalRuntimeFailure.invalidRequest }
        let job = Job(rootID: root, snapshotID: value.snapshotId, query: value.query, cursor: value.cursor, pageSize: value.pageSize, correlationID: value.correlationId)
        let task: LocalTaskID = try await client.call("work.submit", Submission(capability: name, job: job, key: value.idempotencyKey ?? UUID().uuidString))
        if ["file.scan", "file.compute_duplicates"].contains(name) { return ["taskId": task.id.uuidString, "status": "accepted"] }
        let page: FileSnapshotPage = try await client.waitForResult(task.id, cancelOnCancellation: false, onProgress: { progress in
                if let progress { await context?.progress(Double(progress.processed.value), progress.total.map { Double($0.value) }, "Выполнение") }
            })
        return payload(page)
    }
    private static func time(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private static func record(_ record: FileRecord) -> [String: Any] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = record.version.flatMap { try? encoder.encode($0) }.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        return ["id": record.id.uuidString, "relativePath": record.relativePath, "name": record.fileName,
            "byteSize": record.byteSize, "modifiedAt": record.modifiedAt.map(time) as Any? ?? NSNull(),
            "version": fingerprint as Any? ?? NSNull(), "sha256": record.contentHash as Any? ?? NSNull()]
    }
    private static func payload(_ page: FileSnapshotPage) -> [String: Any] {
        ["snapshotId": page.snapshot.id.uuidString, "rootId": page.snapshot.rootID.uuidString,
         "indexGeneration": page.snapshot.generation, "indexedAt": time(page.snapshot.indexedAt),
         "verifiedAt": time(page.verifiedAt), "freshness": page.freshness, "stale": false,
         "skippedCount": page.snapshot.skippedCount, "fileCount": page.fileCount, "totalByteSize": page.totalByteSize,
         "hashesAvailable": page.hashesAvailable, "hashesVerifiedAt": page.snapshot.hashesVerifiedAt.map(time) as Any? ?? NSNull(),
         "totalDuplicateFileCount": page.totalDuplicateFileCount as Any? ?? NSNull(), "totalGroupCount": page.totalGroupCount as Any? ?? NSNull(),
         "records": page.records.map(record), "largeFiles": page.largeFiles.map(record),
         "nextCursor": page.nextCursor as Any? ?? NSNull(), "groups": page.groups.map {
             ["hash": $0.id, "fileCount": $0.totalRecordCount ?? $0.records.count, "byteSize": $0.byteSize, "records": $0.records.map(record)]
         }]
    }
}
