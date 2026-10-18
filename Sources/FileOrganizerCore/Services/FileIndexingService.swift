import Foundation
import UniformTypeIdentifiers

/// Сервис сканирует только уже разрешённый корень. Он не получает путь от MCP и
/// не модифицирует файловую систему: его единственная задача — собрать метаданные
/// обычных файлов для локального индекса.
public actor FileIndexingService {
    public init() {}

    public func scan(
        root: AuthorizedRoot,
        rootURL: URL,
        onProgress: @escaping @Sendable (ScanProgress) async throws -> Void
    ) async throws -> (records: [FileRecord], summary: ScanSummary) {
        try Task.checkCancellation()
        let requestedKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentTypeKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants
        ]

        // Перечислитель создаётся только для каталога, ранее выбранного через
        // NSOpenPanel. Нельзя подменить корень относительным путём из интерфейса
        // внешнего агента, потому что UI передаёт уже разрешённый URL.
        var enumerationFailures = 0
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(requestedKeys),
            options: options,
            errorHandler: { _, _ in enumerationFailures += 1; return true }
        ) else {
            throw FileIndexingError.enumerationUnavailable
        }

        var records: [FileRecord] = []
        var skippedItemCount = 0
        var totalByteSize: Int64 = 0

        while let itemURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            do {
                let values = try itemURL.resourceValues(forKeys: requestedKeys)
                // Переход по ссылкам мог бы вывести сканирование за пределы
                // разрешённого каталога, поэтому их полностью исключаем.
                guard values.isSymbolicLink != true, values.isRegularFile == true else {
                    // URL enumerator сам не обходит symlink. skipDescendants на
                    // ссылке-файле способен пропустить следующий соседний каталог.
                    if values.isSymbolicLink == true { skippedItemCount += 1 }
                    continue
                }

                let normalizedRootPath = rootURL.standardizedFileURL.path
                let normalizedItemPath = itemURL.standardizedFileURL.path
                let rootPrefix = normalizedRootPath.hasSuffix("/")
                    ? normalizedRootPath
                    : normalizedRootPath + "/"
                // Удаляем только проверенный префикс разрешённого корня. В отличие
                // от замены подстроки, этот подход не может случайно оставить
                // абсолютный путь или обработать похожее имя соседней папки.
                guard normalizedItemPath.hasPrefix(rootPrefix) else {
                    skippedItemCount += 1
                    continue
                }
                let relativePath = String(normalizedItemPath.dropFirst(rootPrefix.count))
                guard !relativePath.isEmpty, !relativePath.hasPrefix("../") else {
                    skippedItemCount += 1
                    continue
                }

                let version = try VerifiedFileReader.capture(root: rootURL, relative: relativePath)
                let byteSize = version.byteSize
                guard byteSize == Int64(values.fileSize ?? 0) else { throw AresFileFailure.staleSnapshot }
                guard records.count < 50_000 else { throw AresFileFailure.capacityExceeded }
                records.append(
                    FileRecord(
                        rootID: root.id,
                        relativePath: relativePath,
                        fileName: itemURL.lastPathComponent,
                        fileExtension: itemURL.pathExtension.lowercased(),
                        byteSize: byteSize,
                        createdAt: values.creationDate,
                        modifiedAt: values.contentModificationDate,
                        typeIdentifier: values.contentType?.identifier, version: version
                    )
                )
                let (sum, overflow) = totalByteSize.addingReportingOverflow(byteSize)
                guard !overflow else { throw AresFileFailure.capacityExceeded }; totalByteSize = sum
            } catch AresFileFailure.staleSnapshot { throw AresFileFailure.staleSnapshot }
            catch AresFileFailure.capacityExceeded { throw AresFileFailure.capacityExceeded }
            catch is CancellationError { throw CancellationError() }
            catch {
                // Ошибка доступа к одному элементу не должна останавливать весь
                // анализ разрешённой папки. Сводка честно сообщает их количество.
                skippedItemCount += 1
            }

            if (records.count + skippedItemCount).isMultiple(of: 100) {
                try await onProgress(
                    ScanProgress(indexedFileCount: records.count, skippedItemCount: skippedItemCount + enumerationFailures)
                )
            }
        }

        try await onProgress(ScanProgress(indexedFileCount: records.count, skippedItemCount: skippedItemCount + enumerationFailures))
        return (
            records,
            ScanSummary(
                rootID: root.id,
                indexedFileCount: records.count,
                skippedItemCount: skippedItemCount + enumerationFailures,
                totalByteSize: totalByteSize
            )
        )
    }
}

public enum FileIndexingError: Error, LocalizedError, Sendable {
    case enumerationUnavailable

    public var errorDescription: String? {
        "Не удалось начать сканирование выбранной папки."
    }
}
