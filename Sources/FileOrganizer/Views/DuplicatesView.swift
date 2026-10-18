import SwiftUI
import QuickLook
import FileOrganizerCore

/// Экран показывает только результат анализа. Любые действия с файлами появятся
/// позднее в плане с явным подтверждением пользователя.
struct DuplicatesView: View {
    @ObservedObject var viewModel: OverviewViewModel
    @StateObject private var fileActions: FilesViewModel
    @State private var expandedGroups: Set<String> = []

    init(viewModel: OverviewViewModel) {
        self.viewModel = viewModel
        _fileActions = StateObject(wrappedValue: FilesViewModel(container: viewModel.container))
    }

    var body: some View {
        List {
            Section {
                Button("Найти точные дубликаты", systemImage: "magnifyingglass") {
                    viewModel.findDuplicates()
                }
                .disabled(viewModel.isFindingDuplicates || viewModel.roots.isEmpty)
                if let notice = viewModel.duplicateNotice { Text(notice).accessibilityIdentifier("duplicates.pageSummary") }
                if viewModel.nextDuplicateCursor != nil {
                    Button("Показать ещё") { viewModel.loadMoreDuplicates() }.disabled(viewModel.isFindingDuplicates)
                }
                if viewModel.isFindingDuplicates { ProgressView("Проверяем содержимое файлов…") }
                Text("Проверяются только файлы одинакового размера; совпадение подтверждается SHA-256.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Крупные файлы") {
                if viewModel.largeFiles.isEmpty { Text("Результаты появятся после анализа.").foregroundStyle(.secondary) }
                ForEach(viewModel.largeFiles) { file in
                    LabeledContent(file.fileName, value: ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file))
                }
            }
            Section("Точные дубликаты") {
                if viewModel.duplicateGroups.isEmpty { Text("Подтверждённых групп пока нет.").foregroundStyle(.secondary) }
                ForEach(viewModel.duplicateGroups) { group in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedGroups.contains(group.id) },
                        set: { if $0 { expandedGroups.insert(group.id) } else { expandedGroups.remove(group.id) } }
                    )) {
                        ForEach(group.records) { file in
                            duplicateRow(file)
                                .padding(.vertical, 8)
                        }
                        Text("Совпадение SHA-256 подтверждает одинаковое содержимое. Оно не определяет, нужны ли обе копии приложениям или проектам.")
                            .font(.caption).foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.records.first?.fileName ?? "Группа дубликатов").font(.headline)
                            Text("Показано \(group.records.count) из \(group.totalRecordCount ?? group.records.count) копий · каждая \(ByteCountFormatter.string(fromByteCount: group.byteSize, countStyle: .file))")
                            Text("Объём лишних копий: \(ByteCountFormatter.string(fromByteCount: group.reclaimableByteSize, countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .quickLookPreview($fileActions.previewURL)
        .onChange(of: fileActions.previewURL) { _, url in if url == nil { fileActions.closePreview() } }
        .onDisappear { fileActions.closePreview() }
        .alert("Не удалось открыть файл", isPresented: Binding(get: { fileActions.errorMessage != nil }, set: { if !$0 { fileActions.errorMessage = nil } })) {
            Button("Закрыть", role: .cancel) { fileActions.errorMessage = nil }
        } message: { Text(fileActions.errorMessage ?? "") }
    }

    private func duplicateRow(_ file: FileRecord) -> some View {
        let root = viewModel.roots.first { $0.id == file.rootID }
        let assessment = FileLocationAssessment.assess(rootPath: root?.relativePathHint, relativePath: file.relativePath)
        return VStack(alignment: .leading, spacing: 6) {
            Label(file.fileName, systemImage: "doc")
                .font(.headline)
            Text(root.map { URL(fileURLWithPath: $0.relativePathHint).appendingPathComponent(file.relativePath).path } ?? file.relativePath)
                .font(.caption).textSelection(.enabled)
            Text("Тип: \(file.fileExtension.isEmpty ? "Без расширения" : file.fileExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            Label(assessment.rawValue, systemImage: assessment == .ordinary ? "folder" : "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(assessment == .ordinary ? Color.secondary : Color.orange)
            Text("Оценка по пути; назначение файла не проверялось.")
                .font(.caption2).foregroundStyle(.secondary)
            if let date = file.modifiedAt { Text("Изменён: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
            HStack {
                Button("Предпросмотр", systemImage: "eye") { fileActions.open(file, preview: true) }
                Button("Показать в Finder", systemImage: "folder") { fileActions.open(file, preview: false) }
            }
        }
    }
}
