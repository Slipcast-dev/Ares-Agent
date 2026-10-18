import AppKit
import Combine
import Foundation
import FileOrganizerCore

/// Состояние экрана обзора. ViewModel владеет жизненным циклом безопасного
/// сканирования, но не содержит SwiftUI-представлений и не выполняет мутации
/// пользовательских файлов.
@MainActor
final class OverviewViewModel: ObservableObject {
    @Published private(set) var roots: [AuthorizedRoot] = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var lastSummary: ScanSummary?
    @Published var errorMessage: String?
    @Published private(set) var duplicateNotice: String?
    @Published private(set) var nextDuplicateCursor: String?
    private var duplicateRootID: UUID?
    private var totalDuplicateCount: Int?
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published private(set) var largeFiles: [FileRecord] = []
    @Published private(set) var isFindingDuplicates = false
    let container: AppContainer
    @Published private(set) var isRemovingRoot = false

    /// Не отзываем доступ во время локального чтения: открытый security scope
    /// завершится перед удалением bookmark. MCP-задачи проверяются хранилищем.
    func removeRoot(_ root: AuthorizedRoot) {
        guard !isScanning, !isFindingDuplicates, !isRemovingRoot else { return }
        isRemovingRoot = true
        Task {
            defer { isRemovingRoot = false }
            do {
                try await container.fileRepository.removeRoot(withID: root.id)
                roots = try await container.fileRepository.fetchRoots()
                if lastSummary?.rootID == root.id { lastSummary = nil }
                duplicateGroups = []
                largeFiles = []
            } catch { errorMessage = Self.userMessage(for: error) }
        }
    }

    init(container: AppContainer? = nil) {
        self.container = container ?? AppContainer(databaseURL: AppContainer.defaultApplicationSupportDatabaseURL())
    }

    func load() {
        do {
            try container.preparePersistentStore()
            Task {
                do {
                    roots = try await container.fileRepository.fetchRoots()
                } catch {
                    errorMessage = Self.userMessage(for: error)
                }
            }
        } catch {
            errorMessage = Self.userMessage(for: error)
        }
    }

    /// Стандартная панель macOS — единственный путь получения нового файлового
    /// доступа. Агентам и текстовым полям не разрешено передавать URL напрямую.
    func chooseRootAndScan() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку для анализа"
        panel.message = "Ares будет читать только метаданные файлов в этой папке."
        panel.prompt = "Добавить папку"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        startScan(selectedURL: selectedURL)
    }

    private func startScan(selectedURL: URL) {
        isScanning = true
        progress = ScanProgress(indexedFileCount: 0, skippedItemCount: 0)
        errorMessage = nil

        Task { [self] in
            do {
                try container.preparePersistentStore()
                let root = try await container.authorizedRootAccess.addRoot(from: selectedURL)
                let task = try await container.taskCoordinator.scan(rootID: root.id, origin: .user)
                let summary = try await container.taskCoordinator.waitForScan(task.id) { progress in
                    await self.updateProgress(progress)
                }
                roots = try await container.fileRepository.fetchRoots()
                lastSummary = summary
            } catch is CancellationError {
                errorMessage = "Сканирование отменено. Изменения файлов не выполнялись."
            } catch {
                errorMessage = Self.userMessage(for: error)
            }
            isScanning = false
        }
    }

    /// Анализирует только уже проиндексированный и разрешённый пользователем
    /// корень. Хэширование не запускается, если сканирование ещё не проводилось.
    func findDuplicates(rootID: UUID? = nil) {
        guard !isFindingDuplicates, !isScanning, !isRemovingRoot else { return }
        guard let root = rootID.flatMap({ id in roots.first { $0.id == id } }) ?? roots.first else {
            errorMessage = "Сначала добавьте и просканируйте папку."
            return
        }
        isFindingDuplicates = true
        Task { [self] in
            defer { isFindingDuplicates = false }
            do {
                let analysis = try await container.taskCoordinator.findDuplicates(rootID: root.id)
                largeFiles = analysis.largeFiles; duplicateGroups = analysis.groups
                duplicateRootID = root.id; nextDuplicateCursor = analysis.nextCursor
                totalDuplicateCount = analysis.totalDuplicateFileCount; updateDuplicateNotice(analysis.snapshot?.skippedCount ?? 0)
            } catch { duplicateGroups = []; nextDuplicateCursor = nil; duplicateNotice = nil; errorMessage = Self.userMessage(for: error) }
        }
    }
    func loadMoreDuplicates() {
        guard !isFindingDuplicates, let root = duplicateRootID, let cursor = nextDuplicateCursor else { return }
        isFindingDuplicates = true
        Task {
            defer { isFindingDuplicates = false }
            do {
                let page = try await container.taskCoordinator.duplicatePage(rootID: root, cursor: cursor)
                var groups = Dictionary(uniqueKeysWithValues: duplicateGroups.map { ($0.id, $0) })
                for group in page.groups {
                    let previous = groups[group.id]?.records ?? []
                    let merged = Dictionary((previous + group.records).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    groups[group.id] = DuplicateGroup(contentHash: group.id, byteSize: group.byteSize, records: merged.values.sorted { $0.relativePath < $1.relativePath }, totalRecordCount: group.totalRecordCount)
                }
                duplicateGroups = groups.values.sorted { $0.id < $1.id }; nextDuplicateCursor = page.nextCursor
                updateDuplicateNotice(page.snapshot?.skippedCount ?? 0)
            } catch { duplicateGroups = []; nextDuplicateCursor = nil; duplicateNotice = nil; errorMessage = Self.userMessage(for: error) }
        }
    }
    private func updateDuplicateNotice(_ skipped: Int) {
        let count = duplicateGroups.reduce(0) { $0 + $1.records.count }
        duplicateNotice = "Показано \(count) из \(totalDuplicateCount ?? count) файлов с дубликатами." + (skipped > 0 ? " Пропущено объектов: \(skipped)." : "")
    }

    private func updateProgress(_ newProgress: ScanProgress) {
        progress = newProgress
    }

    private static func userMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Не удалось завершить операцию. Файлы не изменены."
    }
}
