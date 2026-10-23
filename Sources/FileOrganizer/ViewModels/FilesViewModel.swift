import AppKit
import Combine
import Foundation
import FileOrganizerCore

/// Браузер читает локальный индекс. Security scope удерживается отдельно лишь
/// на время предпросмотра: Quick Look читает содержимое асинхронно после клика.
@MainActor
final class FilesViewModel: ObservableObject {
    @Published var roots: [AuthorizedRoot] = []
    @Published var rootID: UUID?
    @Published var records: [FileRecord] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var query = ""
    @Published var fileType = ""
    @Published var collection = FileCollection.all
    @Published var minimumSize = Int64(0)
    @Published var modifiedWithinDays = 0
    @Published var isLoading = false
    @Published var errorMessage: AresMessage?
    @Published var previewURL: URL?
    @Published var includedPaths: Set<String>?
    private var scopedRoot: URL?
    private var requestID = UUID()
    private let container: AppContainer

    init(container: AppContainer, initialRootID: UUID? = nil, includedPaths: Set<String>? = nil) {
        self.container = container; self.rootID = initialRootID; self.includedPaths = includedPaths
    }

    var types: [String] { Set(records.map(\.fileExtension).filter { !$0.isEmpty }).sorted() }
    var visibleRecords: [FileRecord] {
        let now = Date()
        return records.filter { record in
            (includedPaths == nil || includedPaths!.contains(record.relativePath)) &&
            (query.isEmpty || record.relativePath.localizedCaseInsensitiveContains(query)) &&
            (fileType.isEmpty || record.fileExtension == fileType) &&
            record.byteSize >= minimumSize &&
            (modifiedWithinDays == 0 || (record.modifiedAt.map { now.timeIntervalSince($0) <= Double(modifiedWithinDays) * 86_400 } ?? false)) &&
            collection.includes(record, now: now)
        }.sorted {
            collection == .large ? $0.byteSize > $1.byteSize : $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    func load() async {
        do {
            roots = try await container.fileRepository.fetchRoots()
            if !roots.contains(where: { $0.id == rootID }) { rootID = roots.first?.id }
            await loadRecords()
        } catch { errorMessage = .runtime(AresErrorLocalization.message(for: error)) }
    }

    func loadRecords() async {
        let token = UUID()
        requestID = token
        closePreview()
        selectedIDs = []
        records = []
        fileType = ""
        guard let rootID else { isLoading = false; return }
        isLoading = true
        do {
            let result = try await container.fileRepository.records(forRootID: rootID)
            // Быстрое переключение папок не должно показывать ответ старого запроса.
            guard requestID == token else { return }
            records = result
        } catch {
            if requestID == token { errorMessage = .runtime(AresErrorLocalization.message(for: error)) }
        }
        if requestID == token { isLoading = false }
    }

    func openSelected(preview: Bool) {
        let visible = visibleRecords
        guard let record = visible.first(where: { selectedIDs.contains($0.id) }) else { return }
        open(record, preview: preview)
    }

    /// Тот же проверенный доступ используется экраном дубликатов: произвольный
    /// путь из строки UI не может заменить UUID корня и запись индекса.
    func open(_ record: FileRecord, preview: Bool) {
        Task {
            do {
                guard let root = try await container.fileRepository.root(withID: record.rootID) else { throw AuthorizedRootAccessError.missingBookmark }
                let url = try await container.authorizedRootAccess.resolveURL(for: root)
                guard url.startAccessingSecurityScopedResource() else { throw AuthorizedRootAccessError.accessDenied }
                // resolvingSymlinks также проверяет ссылки в родительских каталогах,
                // поскольку индекс мог устареть после изменения файлов пользователем.
                let canonicalRoot = url.resolvingSymlinksInPath().standardizedFileURL
                let file = url.appendingPathComponent(record.relativePath).resolvingSymlinksInPath().standardizedFileURL
                guard file.path.hasPrefix(canonicalRoot.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
                    url.stopAccessingSecurityScopedResource()
                    throw AuthorizedRootAccessError.accessDenied
                }
                if preview {
                    closePreview()
                    scopedRoot = url
                    previewURL = file
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                    url.stopAccessingSecurityScopedResource()
                }
            } catch { errorMessage = .runtime(AresErrorLocalization.message(for: error)) }
        }
    }

    func closePreview() {
        previewURL = nil
        scopedRoot?.stopAccessingSecurityScopedResource()
        scopedRoot = nil
    }
}

/// Недавние файлы определяются датой создания из индекса, а старые — датой
/// изменения; отсутствующая дата не считается доказательством возраста.
enum FileCollection: String, CaseIterable, Identifiable {
    case all = "Все файлы", large = "Крупные ≥ 100 МБ", recent = "Созданы за 7 дней", old = "Не менялись год"
    var id: Self { self }
    func includes(_ record: FileRecord, now: Date) -> Bool {
        switch self {
        case .all: return true
        case .large: return record.byteSize >= 100_000_000
        case .recent: return record.createdAt.map { now.timeIntervalSince($0) <= 7 * 86_400 } ?? false
        case .old: return record.modifiedAt.map { now.timeIntervalSince($0) >= 365 * 86_400 } ?? false
        }
    }
}
