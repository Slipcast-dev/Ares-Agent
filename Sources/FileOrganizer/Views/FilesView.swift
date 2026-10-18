import SwiftUI
import QuickLook
import FileOrganizerCore

/// Таблица использует устойчивые UUID индекса и множественный выбор macOS.
/// Фильтры меняют только представление списка, а не пользовательские файлы.
struct FilesView: View {
    @StateObject private var model: FilesViewModel
    init(container: AppContainer, initialRootID: UUID? = nil, includedPaths: Set<String>? = nil) {
        _model = StateObject(wrappedValue: FilesViewModel(container: container, initialRootID: initialRootID, includedPaths: includedPaths))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Папка", selection: $model.rootID) {
                    Text("Выберите папку").tag(Optional<UUID>.none)
                    ForEach(model.roots) { Text($0.displayName).tag(Optional($0.id)) }
                }.frame(maxWidth: 350)
                Spacer()
                Button("Обновить", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading)
            }
            AresInputRow("Поиск файлов") {
                TextField("Поиск по имени или относительному пути", text: $model.query)
            }
            if model.includedPaths != nil {
                HStack { Text("Результаты правила").font(.caption); Button("Показать все файлы") { model.includedPaths = nil } }
            }
            HStack {
                Picker("Тип", selection: $model.fileType) {
                    Text("Все типы").tag("")
                    ForEach(model.types, id: \.self) { Text($0.uppercased()).tag($0) }
                }
                Picker("Размер", selection: $model.minimumSize) {
                    Text("Любой").tag(Int64(0))
                    Text("От 10 МБ").tag(Int64(10_000_000))
                    Text("От 100 МБ").tag(Int64(100_000_000))
                    Text("От 1 ГБ").tag(Int64(1_000_000_000))
                }
                Picker("Изменены", selection: $model.modifiedWithinDays) {
                    Text("В любое время").tag(0)
                    Text("За 7 дней").tag(7)
                    Text("За 30 дней").tag(30)
                }
            }
            Picker("Подборка", selection: $model.collection) {
                ForEach(FileCollection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if model.isLoading {
                ProgressView("Загрузка индекса…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                fileTable
            }
            HStack {
                Text("Найдено: \(model.visibleRecords.count) из \(model.records.count). Выбрано: \(model.selectedIDs.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Предпросмотр", systemImage: "eye") { model.openSelected(preview: true) }
                    .disabled(model.selectedIDs.count != 1)
                Button("Показать в Finder", systemImage: "folder") { model.openSelected(preview: false) }
                    .disabled(model.selectedIDs.count != 1)
            }
            Text("Данные из последнего сканирования. «Обновить» перечитывает индекс.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .task { await model.load() }
        .onChange(of: model.rootID) { _, _ in Task { await model.loadRecords() } }
        .onChange(of: model.previewURL) { _, url in if url == nil { model.closePreview() } }
        .onDisappear { model.closePreview() }
        .quickLookPreview($model.previewURL)
        .alert("Не удалось открыть файл", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Закрыть", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var fileTable: some View {
        Table(model.visibleRecords, selection: $model.selectedIDs) {
            TableColumn("Имя", value: \.fileName).width(min: 150, ideal: 230)
            TableColumn("Тип") { Text($0.fileExtension.isEmpty ? "—" : $0.fileExtension.uppercased()) }.width(60)
            TableColumn("Размер") { Text(ByteCountFormatter.string(fromByteCount: $0.byteSize, countStyle: .file)) }.width(90)
            TableColumn("Изменён") { file in
                if let date = file.modifiedAt { Text(date, format: .dateTime.day().month().year()) } else { Text("—") }
            }.width(100)
            TableColumn("Папка") { file in
                let parent = (file.relativePath as NSString).deletingLastPathComponent
                Text(parent.isEmpty ? "Корень" : parent).foregroundStyle(.secondary)
            }
        }
        .overlay {
            if model.visibleRecords.isEmpty {
                ContentUnavailableView(model.roots.isEmpty ? "Добавьте папку в «Обзоре»" : "Нет файлов по выбранным условиям", systemImage: "doc.text.magnifyingglass")
                    .allowsHitTesting(false)
            }
        }
    }
}
