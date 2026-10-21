import Foundation

/// Находит только точные дубликаты. Размер используется как дешёвый первый
/// фильтр, а окончательное решение принимается исключительно после SHA-256.
public actor DuplicateDetectionService {
    public init() {}

    public func findExactDuplicates(
        rootURL: URL,
        records: [FileRecord],
        onProgress: @escaping @Sendable (Int, Int) async -> Void,
        persistHash: @escaping @Sendable (UUID, String) async throws -> Void = { _, _ in }
    ) async throws -> [DuplicateGroup] {
        let candidates = Dictionary(grouping: records, by: \.byteSize)
            .values
            .filter { $0.count > 1 && $0.first?.byteSize ?? 0 > 0 }
            .flatMap { $0 }
        var hashes: [String: [FileRecord]] = [:]
        // Старый индекс без FileVersion не даёт права доверять текущему пути:
        // нужен повторный scan. Проверяем весь набор до первой записи хэша.
        for record in candidates {
            guard let version = record.version else { throw AresFileFailure.snapshotRequired }
            guard version.byteSize == record.byteSize,
                  try VerifiedFileReader.capture(root: rootURL, relative: record.relativePath) == version
            else { throw AresFileFailure.staleSnapshot }
        }

        for (index, record) in candidates.enumerated() {
            try Task.checkCancellation()
            guard let version = record.version else { throw AresFileFailure.snapshotRequired }
            // Один reader для legacy и runtime: O_NOFOLLOW на каждом компоненте,
            // сверка inode/версии до и после чтения, отмена между блоками.
            let hash = try VerifiedFileReader.hash(root: rootURL, relative: record.relativePath, expected: version)
            // Хэш — производный технический идентификатор, а не содержимое
            // файла. Сохраняем его после успешного потокового чтения, чтобы
            // следующий анализ и MCP могли использовать устойчивый индекс.
            try await persistHash(record.id, hash)
            let hashedRecord = FileRecord(
                id: record.id, rootID: record.rootID, relativePath: record.relativePath,
                fileName: record.fileName, fileExtension: record.fileExtension,
                byteSize: record.byteSize, createdAt: record.createdAt, modifiedAt: record.modifiedAt,
                typeIdentifier: record.typeIdentifier, contentHash: hash, version: version
            )
            hashes[hash, default: []].append(hashedRecord)
            await onProgress(index + 1, candidates.count)
        }
        return hashes.compactMap { hash, group in
            guard group.count > 1, let size = group.first?.byteSize else { return nil }
            return DuplicateGroup(contentHash: hash, byteSize: size, records: group)
        }.sorted { $0.reclaimableByteSize > $1.reclaimableByteSize }
    }

}
