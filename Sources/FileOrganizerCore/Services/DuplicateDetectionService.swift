import CryptoKit
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
        let rootPath = rootURL.standardizedFileURL.path + "/"

        for (index, record) in candidates.enumerated() {
            try Task.checkCancellation()
            let url = rootURL.appendingPathComponent(record.relativePath).standardizedFileURL
            guard url.path.hasPrefix(rootPath) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let hash = try hashFile(at: url)
            // Хэш — производный технический идентификатор, а не содержимое
            // файла. Сохраняем его после успешного потокового чтения, чтобы
            // следующий анализ и MCP могли использовать устойчивый индекс.
            try await persistHash(record.id, hash)
            var hashedRecord = record
            hashedRecord = FileRecord(
                id: record.id, rootID: record.rootID, relativePath: record.relativePath,
                fileName: record.fileName, fileExtension: record.fileExtension,
                byteSize: record.byteSize, createdAt: record.createdAt, modifiedAt: record.modifiedAt,
                typeIdentifier: record.typeIdentifier, contentHash: hash
            )
            hashes[hash, default: []].append(hashedRecord)
            await onProgress(index + 1, candidates.count)
        }
        return hashes.compactMap { hash, group in
            guard group.count > 1, let size = group.first?.byteSize else { return nil }
            return DuplicateGroup(contentHash: hash, byteSize: size, records: group)
        }.sorted { $0.reclaimableByteSize > $1.reclaimableByteSize }
    }

    /// Потоковое чтение ограничивает использование памяти даже для больших видео
    /// и образов диска. Содержимое не сохраняется, передаётся только хэш.
    private func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
