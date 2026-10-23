import SwiftUI
import EcosystemLocalization
import EcosystemUI
import QuickLook
import FileOrganizerCore

/// Экран показывает только результат анализа. Любые действия с файлами появятся
/// позднее в плане с явным подтверждением пользователя.
struct DuplicatesView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }

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
                Button(l10n.text("Найти точные дубликаты"), systemImage: "magnifyingglass") {
                    viewModel.findDuplicates()
                }
                .disabled(viewModel.isFindingDuplicates || viewModel.roots.isEmpty)
                if let notice = viewModel.duplicateNotice { Text(l10n.render(notice)).accessibilityIdentifier("duplicates.pageSummary") }
                if viewModel.nextDuplicateCursor != nil {
                    Button(l10n.text("Показать ещё")) { viewModel.loadMoreDuplicates() }.disabled(viewModel.isFindingDuplicates)
                }
                if viewModel.isFindingDuplicates { ProgressView(l10n.text("Проверяем содержимое файлов…")) }
                Text(l10n.text("Проверяются только файлы одинакового размера; совпадение подтверждается SHA-256."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(l10n.text("Крупные файлы")) {
                if viewModel.largeFiles.isEmpty { Text(l10n.text("Результаты появятся после анализа.")).foregroundStyle(.secondary) }
                ForEach(viewModel.largeFiles) { file in
                    LabeledContent(file.fileName, value: ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file))
                }
            }
            Section(l10n.text("Точные дубликаты")) {
                if viewModel.duplicateGroups.isEmpty { Text(l10n.text("Подтверждённых групп пока нет.")).foregroundStyle(.secondary) }
                ForEach(viewModel.duplicateGroups) { group in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedGroups.contains(group.id) },
                        set: { if $0 { expandedGroups.insert(group.id) } else { expandedGroups.remove(group.id) } }
                    )) {
                        ForEach(group.records) { file in
                            duplicateRow(file)
                                .padding(.vertical, 8)
                        }
                        Text(l10n.text("Совпадение SHA-256 подтверждает одинаковое содержимое. Оно не определяет, нужны ли обе копии приложениям или проектам."))
                            .font(.caption).foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.records.first?.fileName ?? l10n.text("Группа дубликатов")).font(.headline)
                            Text(l10n.format("Показано %@ из %@ копий · каждая %@", group.records.count.formatted(), (group.totalRecordCount ?? group.records.count).formatted(), ByteCountFormatter.string(fromByteCount: group.byteSize, countStyle: .file)))
                            Text(l10n.format("Объём лишних копий: %@", ByteCountFormatter.string(fromByteCount: group.reclaimableByteSize, countStyle: .file)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .quickLookPreview($fileActions.previewURL)
        .onChange(of: fileActions.previewURL) { _, url in if url == nil { fileActions.closePreview() } }
        .onDisappear { fileActions.closePreview() }
        .alert(l10n.text("Не удалось открыть файл"), isPresented: Binding(get: { fileActions.errorMessage != nil }, set: { if !$0 { fileActions.errorMessage = nil } })) {
            Button(l10n.text("Закрыть"), role: .cancel) { fileActions.errorMessage = nil }
        } message: { Text(fileActions.errorMessage.map(l10n.render) ?? "") }
    }

    private func duplicateRow(_ file: FileRecord) -> some View {
        let root = viewModel.roots.first { $0.id == file.rootID }
        let assessment = FileLocationAssessment.assess(rootPath: root?.relativePathHint, relativePath: file.relativePath)
        return VStack(alignment: .leading, spacing: 6) {
            Label(file.fileName, systemImage: "doc")
                .font(.headline)
            Text(root.map { URL(fileURLWithPath: $0.relativePathHint).appendingPathComponent(file.relativePath).path } ?? file.relativePath)
                .font(.caption).textSelection(.enabled)
            Text(l10n.format("Тип: %@ · %@", file.fileExtension.isEmpty ? l10n.text("Без расширения") : file.fileExtension.uppercased(), ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file)))
                .font(.caption).foregroundStyle(.secondary)
            Label(l10n.text(assessment.rawValue), systemImage: assessment == .ordinary ? "folder" : "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(assessment == .ordinary ? Color.secondary : Color.orange)
            Text(l10n.text("Оценка по пути; назначение файла не проверялось."))
                .font(.caption2).foregroundStyle(.secondary)
            if let date = file.modifiedAt { Text(l10n.format("Изменён: %@", date.formatted(date: .abbreviated, time: .shortened))).font(.caption) }
            HStack {
                Button(l10n.text("Предпросмотр"), systemImage: "eye") { fileActions.open(file, preview: true) }
                Button(l10n.text("Показать в Finder"), systemImage: "folder") { fileActions.open(file, preview: false) }
            }
        }
    }
}
