import SwiftUI
import EcosystemLocalization
import EcosystemUI
import QuickLook
import FileOrganizerCore

/// Таблица использует устойчивые UUID индекса и множественный выбор macOS.
/// Фильтры меняют только представление списка, а не пользовательские файлы.
struct FilesView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }

    @StateObject private var model: FilesViewModel
    init(container: AppContainer, initialRootID: UUID? = nil, includedPaths: Set<String>? = nil) {
        _model = StateObject(wrappedValue: FilesViewModel(container: container, initialRootID: initialRootID, includedPaths: includedPaths))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(l10n.text("Папка"), selection: $model.rootID) {
                    Text(l10n.text("Выберите папку")).tag(Optional<UUID>.none)
                    ForEach(model.roots) { Text($0.displayName).tag(Optional($0.id)) }
                }.frame(maxWidth: 350)
                Spacer()
                Button(l10n.text("Обновить"), systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading)
            }
            AresInputRow(l10n.text("Поиск файлов")) {
                TextField(l10n.text("Поиск по имени или относительному пути"), text: $model.query)
            }
            if model.includedPaths != nil {
                HStack { Text(l10n.text("Результаты правила")).font(.caption); Button(l10n.text("Показать все файлы")) { model.includedPaths = nil } }
            }
            HStack {
                Picker(l10n.text("Тип"), selection: $model.fileType) {
                    Text(l10n.text("Все типы")).tag("")
                    ForEach(model.types, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                Picker(l10n.text("Размер"), selection: $model.minimumSize) {
                    Text(l10n.text("Любой")).tag(Int64(0))
                    Text(l10n.text("От 10 МБ")).tag(Int64(10_000_000))
                    Text(l10n.text("От 100 МБ")).tag(Int64(100_000_000))
                    Text(l10n.text("От 1 ГБ")).tag(Int64(1_000_000_000))
                }
                Picker(l10n.text("Изменены"), selection: $model.modifiedWithinDays) {
                    Text(l10n.text("В любое время")).tag(0)
                    Text(l10n.text("За 7 дней")).tag(7)
                    Text(l10n.text("За 30 дней")).tag(30)
                }
            }
            Picker(l10n.text("Подборка"), selection: $model.collection) {
                ForEach(FileCollection.allCases) { Text(l10n.text($0.rawValue)).tag($0) }
            }.pickerStyle(.segmented)
            if model.isLoading {
                ProgressView(l10n.text("Загрузка индекса…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileTable
            }
            HStack {
                Text(l10n.format("Найдено: %@ из %@. Выбрано: %@", model.visibleRecords.count.formatted(), model.records.count.formatted(), model.selectedIDs.count.formatted()))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(l10n.text("Предпросмотр"), systemImage: "eye") { model.openSelected(preview: true) }
                    .disabled(model.selectedIDs.count != 1)
                Button(l10n.text("Показать в Finder"), systemImage: "folder") { model.openSelected(preview: false) }
                    .disabled(model.selectedIDs.count != 1)
            }
            Text(l10n.text("Данные из последнего сканирования. «Обновить» перечитывает индекс."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .task { await model.load() }
        .onChange(of: model.rootID) { _, _ in Task { await model.loadRecords() } }
        .onChange(of: model.previewURL) { _, url in if url == nil { model.closePreview() } }
        .onDisappear { model.closePreview() }
        .quickLookPreview($model.previewURL)
        .alert(l10n.text("Не удалось открыть файл"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(l10n.text("Закрыть"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage.map(l10n.render) ?? "") }
    }

    private var fileTable: some View {
        Table(model.visibleRecords, selection: $model.selectedIDs) {
            TableColumn(l10n.text("Имя"), value: \.fileName).width(min: 150, ideal: 230)
            TableColumn(l10n.text("Тип")) { Text($0.fileExtension.isEmpty ? "—" : $0.fileExtension.uppercased()) }.width(60)
            TableColumn(l10n.text("Размер")) { Text(ByteCountFormatter.string(fromByteCount: $0.byteSize, countStyle: .file)) }.width(90)
            TableColumn(l10n.text("Изменён")) { file in
                if let date = file.modifiedAt { Text(date, format: .dateTime.day().month().year()) } else { Text("—") }
            }.width(100)
            TableColumn(l10n.text("Папка")) { file in
                let parent = (file.relativePath as NSString).deletingLastPathComponent
                Text(parent.isEmpty ? l10n.text("Корень") : parent).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.visibleRecords.isEmpty {
                ContentUnavailableView(model.roots.isEmpty ? l10n.text("Добавьте папку в «Обзоре»") : l10n.text("Нет файлов по выбранным условиям"), systemImage: "doc.text.magnifyingglass")
                    .allowsHitTesting(false)
            }
        }
    }
}
