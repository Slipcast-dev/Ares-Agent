import Foundation

/// Только чистые представления одного immutable snapshot. Здесь нет grants,
/// URL, freshness verdict или страниц конкретного клиента/поискового запроса.
/// Полная verify в FileSnapshotOperations выполняется до каждого обращения.
final class FileSnapshotViewCache: @unchecked Sendable {
    private struct Key: Equatable {
        let rootID: UUID
        let id: UUID
        let generation: Int64
        let hashesComputed: Bool
        let hashesVerifiedAt: Date?
        init(_ header: FileSnapshotHeader) {
            rootID = header.rootID; id = header.id; generation = header.generation
            hashesComputed = header.hashesComputed; hashesVerifiedAt = header.hashesVerifiedAt
        }
    }
    /// NSLock защищает короткий синхронный API без await. По контракту runtime
    /// Ареса один callback; lock также защищает будущие независимые callers.
    private let lock = NSLock()
    private var key: Key?
    private var cached: PreparedSnapshotViews?
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        key = nil; cached = nil
    }
    func prepare(_ snapshot: FileIndexSnapshot) throws -> PreparedSnapshotViews {
        try Task.checkCancellation()
        lock.lock(); defer { lock.unlock() }
        let requested = Key(snapshot.header)
        if key == requested, let cached { return cached }
        // До построения нового индекса освобождаем старый: нет LRU по корням,
        // запросам или поколениям, которое росло бы вместе с историей.
        key = nil; cached = nil
        let result = try PreparedSnapshotViews(snapshot)
        if snapshot.records.count <= FileAnalysisLimits.maximumFiles {
            key = requested; cached = result
        }
        return result
    }
}

/// Объём O(N): две упорядоченные последовательности и counts групп; пути и
/// строки FileRecord используют copy-on-write. Query-specific arrays не храним.
final class PreparedSnapshotViews: Sendable {
    let storage: [FileRecord]
    let duplicates: [FileRecord]
    let groupCounts: [String: Int]
    let duplicateCount: Int
    let largeFiles: [FileRecord]
    init(_ snapshot: FileIndexSnapshot) throws {
        let groups = Dictionary(grouping: snapshot.records.filter { $0.contentHash != nil }, by: { $0.contentHash! })
            .filter { $0.value.count > 1 }
        groupCounts = groups.mapValues { $0.count }
        duplicates = groups.keys.sorted().flatMap { key in groups[key]!.sorted { $0.relativePath < $1.relativePath } }
        duplicateCount = duplicates.count
        try Task.checkCancellation()
        storage = snapshot.records.sorted { $0.byteSize == $1.byteSize ? $0.relativePath < $1.relativePath : $0.byteSize > $1.byteSize }
        largeFiles = Array(storage.prefix(20))
        try Task.checkCancellation()
    }
}
