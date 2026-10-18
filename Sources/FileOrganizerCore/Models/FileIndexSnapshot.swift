import Foundation

/// Header и records публикуются одной транзакцией. Cursor ссылается на id,
/// поэтому следующая индексация не подменяет молча содержимое страницы.
public struct FileSnapshotHeader: Codable, Sendable {
    public let id: UUID
    public let rootID: UUID
    public let generation: Int64
    public let indexedAt: Date
    public let fileCount: Int
    public let totalByteSize: Int64
    public let skippedCount: Int
    public var hashesComputed: Bool
    public var hashesVerifiedAt: Date?
}
public struct FileIndexSnapshot: Codable, Sendable {
    public var header: FileSnapshotHeader
    public var records: [FileRecord]
}
public struct FileSnapshotPage: Codable, Sendable {
    public let snapshot: FileSnapshotHeader
    public let freshness: String
    public let verifiedAt: Date
    public let records: [FileRecord]
    public let nextCursor: String?
    public let fileCount: Int
    public let totalByteSize: Int64
    public let groups: [DuplicateGroup]
    public let totalDuplicateFileCount: Int?
    public let totalGroupCount: Int?
    public let hashesAvailable: Bool
    public let largeFiles: [FileRecord]
}
struct FilePageCursor: Codable {
    let version: Int
    let snapshotID: UUID
    let operation: String
    let query: String
    let pageSize: Int
    let offset: Int
}
