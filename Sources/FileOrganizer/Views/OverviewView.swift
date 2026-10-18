import SwiftUI
import FileOrganizerCore

/// Обзор управляет только доступом к папкам. Отзыв разрешения удаляет локальный
/// индекс, но никогда не удаляет содержимое выбранного пользователем каталога.
struct OverviewView: View {
    @ObservedObject var viewModel: OverviewViewModel
    @State private var rootToRemove: AuthorizedRoot?
    @State private var areRootsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Доступ к папкам").font(.largeTitle.bold())
                Text("Выберите папки для поиска файлов и дубликатов. Доступ можно убрать в любой момент после завершения анализа.")
                    .foregroundStyle(.secondary)
                HStack {
                    Label("Разрешённых папок: \(viewModel.roots.count)", systemImage: "folder")
                    Spacer()
                    Button("Добавить папку", systemImage: "folder.badge.plus") {
                        viewModel.chooseRootAndScan()
                    }
                    .disabled(viewModel.isScanning || viewModel.isRemovingRoot)
                }
                if !viewModel.roots.isEmpty {
                    DisclosureGroup("Разрешённые папки (\(viewModel.roots.count))", isExpanded: $areRootsExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.roots) { root in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Label(root.displayName, systemImage: "folder")
                                        Text(root.relativePathHint)
                                            .font(.caption).foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    Button("Убрать доступ", role: .destructive) { rootToRemove = root }
                                        .disabled(viewModel.isScanning || viewModel.isFindingDuplicates || viewModel.isRemovingRoot)
                                        .accessibilityLabel("Убрать доступ к папке \(root.displayName)")
                                }
                            }
                            Text("Удаляется только разрешение и локальный индекс. Файлы остаются на месте.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                    .padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ContentUnavailableView("Папки ещё не добавлены", systemImage: "folder.badge.plus",
                        description: Text("Добавьте папку через стандартное окно выбора macOS."))
                        // ScrollView предлагает содержимому собственную ширину.
                        // Растягиваем пустое состояние на всю область, иначе
                        // оно центрируется в своей узкой колонке слева.
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if viewModel.isScanning {
                    ProgressView("Индексирование: \(viewModel.progress?.indexedFileCount ?? 0) файлов")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .alert("Убрать папку из разрешённых?", isPresented: Binding(
            get: { rootToRemove != nil },
            set: { if !$0 { rootToRemove = nil } }
        )) {
            Button("Убрать доступ", role: .destructive) {
                if let root = rootToRemove { viewModel.removeRoot(root) }
                rootToRemove = nil
            }
            Button("Отмена", role: .cancel) { rootToRemove = nil }
        } message: {
            Text("Файлы в папке «\(rootToRemove?.displayName ?? "")» останутся на месте. Для повторного доступа потребуется снова выбрать папку.")
        }
    }
}
