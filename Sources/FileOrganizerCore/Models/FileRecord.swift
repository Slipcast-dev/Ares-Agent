import Foundation

/// Метаданные одного файла, индексируемые локально. Содержимое файла не
/// сохраняется: этого достаточно для поиска и будущей проверки дубликатов.
public struct FileRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let rootID: UUID
    public let relativePath: String
    public let fileName: String
    public let fileExtension: String
    public let byteSize: Int64
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let typeIdentifier: String?
    public let version: FileVersion?
    public let contentHash: String?

    public init(
        id: UUID = UUID(),
        rootID: UUID,
        relativePath: String,
        fileName: String,
        fileExtension: String,
        byteSize: Int64,
        createdAt: Date?,
        modifiedAt: Date?,
        typeIdentifier: String?,
        contentHash: String? = nil,
        version: FileVersion? = nil
    ) {
        self.version = version
        self.id = id
        self.rootID = rootID
        self.relativePath = relativePath
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.typeIdentifier = typeIdentifier
        self.contentHash = contentHash
    }
}

/// Группа файлов, идентичность которых подтверждена SHA-256, а не только именем
/// или размером. Первичный кандидат «оставить» появится на этапе планов CP-05.
public struct DuplicateGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let byteSize: Int64
    public let records: [FileRecord]
    public let totalRecordCount: Int?

    public init(contentHash: String, byteSize: Int64, records: [FileRecord], totalRecordCount: Int? = nil) {
        self.totalRecordCount = totalRecordCount
        self.id = contentHash
        self.byteSize = byteSize
        self.records = records
    }

    public var reclaimableByteSize: Int64 {
        byteSize * Int64(max((totalRecordCount ?? records.count) - 1, 0))
    }
}

/// Снимок прогресса передаётся в UI без раскрытия абсолютного пути текущего
/// файла: путь может содержать персональные данные и не нужен для индикатора.
public struct ScanProgress: Equatable, Sendable {
    public let indexedFileCount: Int
    public let skippedItemCount: Int

    public init(indexedFileCount: Int, skippedItemCount: Int) {
        self.indexedFileCount = indexedFileCount
        self.skippedItemCount = skippedItemCount
    }
}

/// Результат завершённого сканирования для карточки обзора и аудита.
public struct ScanSummary: Codable, Equatable, Sendable {
    public let snapshotID: UUID?
    public let indexGeneration: Int64?
    public let rootID: UUID
    public let indexedFileCount: Int
    public let skippedItemCount: Int
    public let totalByteSize: Int64

    public init(rootID: UUID, indexedFileCount: Int, skippedItemCount: Int, totalByteSize: Int64, snapshotID: UUID? = nil, indexGeneration: Int64? = nil) {
        self.snapshotID = snapshotID; self.indexGeneration = indexGeneration
        self.rootID = rootID
        self.indexedFileCount = indexedFileCount
        self.skippedItemCount = skippedItemCount
        self.totalByteSize = totalByteSize
    }
}
