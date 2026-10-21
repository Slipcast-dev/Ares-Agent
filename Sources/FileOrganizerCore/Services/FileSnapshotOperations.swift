import Foundation
import EcosystemContracts
import EcosystemRuntimeSupport
import EcosystemLocalIPC

/// Все операции исполняются под ares.domain. Чтение индексного snapshot не
/// означает свежесть файлов: перед ответом повторно сверяем полный набор версий.
struct FileSnapshotOperations: Sendable {
    let repository: any FileRepository
    let access: AuthorizedRootAccessService
    private let views: FileSnapshotViewCache
    init(repository: any FileRepository, access: AuthorizedRootAccessService, views: FileSnapshotViewCache = FileSnapshotViewCache()) {
        self.repository = repository; self.access = access; self.views = views
    }
    func perform(capability: String, job: AresJob, context: QueueExecutionContext) async throws -> Data {
        guard let id = job.rootID, let root = try await repository.root(withID: id) else { throw LocalRuntimeFailure.denied }
        let url = try await access.resolveURL(for: root)
        guard url.startAccessingSecurityScopedResource() else { throw LocalRuntimeFailure.denied }
        defer { url.stopAccessingSecurityScopedResource() }
        guard var snapshot = try await repository.currentSnapshot(rootID: id) else { throw AresFileFailure.snapshotRequired }
        if let requested = job.snapshotID, requested != snapshot.header.id { throw AresFileFailure.staleSnapshot }
        try await context.authorizeRoot(id)
        try await context.authorizeBudget(objects: snapshot.header.fileCount + snapshot.header.skippedCount, bytes: 0)
        try await verify(root: root, url: url, snapshot: snapshot, context: context)
        if capability == "file.compute_duplicates" {
            let candidates = Dictionary(grouping: snapshot.records, by: \.byteSize).values.filter { $0.count > 1 }.flatMap { $0 }
            var inputBytes: Int64 = 0
            for file in candidates {
                let (sum, overflow) = inputBytes.addingReportingOverflow(file.byteSize)
                guard !overflow else { throw AresFileFailure.capacityExceeded }; inputBytes = sum
            }
            // Метаданные не читают всё содержимое больших файлов; hash читает,
            // поэтому отдельный byte budget проверяется до открытия кандидатов.
            try await context.authorizeBudget(objects: candidates.count, bytes: inputBytes)
            var hashes: [UUID: String] = [:]
            for (index, record) in candidates.enumerated() {
                try await context.checkpoint()
                guard let version = record.version else { throw AresFileFailure.snapshotRequired }
                hashes[record.id] = try VerifiedFileReader.hash(root: url, relative: record.relativePath, expected: version)
                try await context.progress(TaskProgress(phase: "hash", processed: NonnegativeInt(Int64(index + 1))))
            }
            // В том числе обнаруживает новые файлы и изменения некандидатов.
            try await verify(root: root, url: url, snapshot: snapshot, context: context)
            guard try await repository.root(withID: id) != nil else { throw LocalRuntimeFailure.denied }
            snapshot = try await repository.publishHashes(rootID: id, snapshotID: snapshot.header.id, hashes: hashes)
        }
        try await context.checkpoint()
        let effective = capability == "file.compute_duplicates" ? "file.find_duplicates" : capability
        return try LocalWire.encode(try page(snapshot, operation: effective, job: job))
    }
    private func verify(root: AuthorizedRoot, url: URL, snapshot: FileIndexSnapshot, context: QueueExecutionContext) async throws {
        let actual = try await FileIndexingService().scan(root: root, rootURL: url) { progress in
            try await context.authorizeBudget(objects: progress.indexedFileCount + progress.skippedItemCount, bytes: 0)
        }
        try await context.checkpoint()
        guard actual.records.count == snapshot.records.count,
              actual.summary.skippedItemCount == snapshot.header.skippedCount else { throw AresFileFailure.staleSnapshot }
        let versions = Dictionary(actual.records.map { ($0.relativePath, $0.version) }, uniquingKeysWith: { first, _ in first })
        guard versions.count == actual.records.count else { throw AresFileFailure.staleSnapshot }
        for record in snapshot.records {
            guard let version = record.version, versions[record.relativePath] == version else { throw AresFileFailure.staleSnapshot }
        }
        guard try await repository.bookmarkData(forRootID: root.id)?.isEmpty == false else { throw LocalRuntimeFailure.denied }
    }
    func page(_ snapshot: FileIndexSnapshot, operation: String, job: AresJob) throws -> FileSnapshotPage {
        let size = job.pageSize ?? 100, query = job.query ?? ""
        guard (1...100).contains(size), query.count <= 120, !query.contains("\0") else { throw LocalRuntimeFailure.invalidRequest }
        var offset = 0
        if let cursor = job.cursor {
            guard cursor.utf8.count < 4096, let data = Data(base64Encoded: cursor) else { throw AresFileFailure.invalidCursor }
            let decoded: FilePageCursor
            do { decoded = try JSONDecoder().decode(FilePageCursor.self, from: data) }
            catch { throw AresFileFailure.invalidCursor }
            guard decoded.version == 1, decoded.snapshotID == snapshot.header.id else { throw AresFileFailure.staleSnapshot }
            guard decoded.operation == operation, decoded.query == query, decoded.pageSize == size, decoded.offset >= 0 else { throw AresFileFailure.invalidCursor }
            offset = decoded.offset
        }
        let prepared = try views.prepare(snapshot)
        let groupCounts = prepared.groupCounts
        let eligible: [FileRecord]
        switch operation {
        case "file.search": eligible = query.isEmpty ? snapshot.records : snapshot.records.filter { $0.relativePath.range(of: query, options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) != nil }
        case "file.analyze_storage": eligible = prepared.storage
        case "file.find_duplicates": eligible = snapshot.header.hashesComputed ? prepared.duplicates : []
        default: throw LocalRuntimeFailure.denied
        }
        guard offset <= eligible.count else { throw AresFileFailure.invalidCursor }
        let rows = Array(eligible.dropFirst(offset).prefix(size))
        let next = offset + rows.count < eligible.count ? try JSONEncoder().encode(FilePageCursor(version: 1, snapshotID: snapshot.header.id, operation: operation, query: query, pageSize: size, offset: offset + rows.count)).base64EncodedString() : nil
        let groups = operation == "file.find_duplicates" ? Dictionary(grouping: rows, by: { $0.contentHash! }).map {
            DuplicateGroup(contentHash: $0.key, byteSize: $0.value[0].byteSize, records: $0.value, totalRecordCount: groupCounts[$0.key])
        }.sorted { $0.id < $1.id } : []
        return FileSnapshotPage(snapshot: snapshot.header, freshness: snapshot.header.skippedCount == 0 ? "verified" : "partial",
            verifiedAt: Date(), records: rows, nextCursor: next, fileCount: snapshot.header.fileCount, totalByteSize: snapshot.header.totalByteSize,
            groups: groups, totalDuplicateFileCount: snapshot.header.hashesComputed ? prepared.duplicateCount : nil,
            totalGroupCount: snapshot.header.hashesComputed ? prepared.groupCounts.count : nil, hashesAvailable: snapshot.header.hashesComputed,
            largeFiles: prepared.largeFiles)
    }
}
