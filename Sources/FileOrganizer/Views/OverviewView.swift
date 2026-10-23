import SwiftUI
import EcosystemLocalization
import EcosystemUI
import FileOrganizerCore

/// Обзор управляет только доступом к папкам. Отзыв разрешения удаляет локальный
/// индекс, но никогда не удаляет содержимое выбранного пользователем каталога.
struct OverviewView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }

    @ObservedObject var viewModel: OverviewViewModel
    @State private var confirmation: ConfirmationLanguage?
    private var approval: AresLocalization { AresLocalization(language: confirmation?.language ?? language) }
    @State private var rootToRemove: AuthorizedRoot?
    @State private var areRootsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(l10n.text("Доступ к папкам")).font(.largeTitle.bold())
                Text(l10n.text("Выберите папки для поиска файлов и дубликатов. Доступ можно убрать в любой момент после завершения анализа."))
                    .foregroundStyle(.secondary)
                HStack {
                    Label(l10n.format("Разрешённых папок: %@", viewModel.roots.count.formatted()), systemImage: "folder")
                    Spacer()
                    Button(l10n.text("Добавить папку"), systemImage: "folder.badge.plus") {
                        viewModel.chooseRootAndScan(language: language)
                    }
                    .disabled(viewModel.isScanning || viewModel.isRemovingRoot)
                }
                if !viewModel.roots.isEmpty {
                    DisclosureGroup(l10n.format("Разрешённые папки (%@)", viewModel.roots.count.formatted()), isExpanded: $areRootsExpanded) {
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
                                    Button(l10n.text("Убрать доступ"), role: .destructive) { confirmation = ConfirmationLanguage(language: language); rootToRemove = root }
                                        .disabled(viewModel.isScanning || viewModel.isFindingDuplicates || viewModel.isRemovingRoot)
                                        .accessibilityLabel(l10n.format("Убрать доступ к папке %@", root.displayName))
                                }
                            }
                            Text(l10n.text("Удаляется только разрешение и локальный индекс. Файлы остаются на месте."))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                    .padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ContentUnavailableView(l10n.text("Папки ещё не добавлены"), systemImage: "folder.badge.plus",
                        description: Text(l10n.text("Добавьте папку через стандартное окно выбора macOS.")))
                        // ScrollView предлагает содержимому собственную ширину.
                        // Растягиваем пустое состояние на всю область, иначе
                        // оно центрируется в своей узкой колонке слева.
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if viewModel.isScanning {
                    ProgressView(l10n.format("Индексирование: %@ файлов", (viewModel.progress?.indexedFileCount ?? 0).formatted()))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .alert(approval.text("Убрать папку из разрешённых?"), isPresented: Binding(
            get: { rootToRemove != nil },
            set: { if !$0 { rootToRemove = nil } }
        )) {
            Button(approval.text("Убрать доступ"), role: .destructive) {
                if let root = rootToRemove { viewModel.removeRoot(root) }
                rootToRemove = nil
            }
            Button(approval.text("Отмена"), role: .cancel) { rootToRemove = nil }
        } message: {
            Text(approval.format("Файлы в папке «%@» останутся на месте. Для повторного доступа потребуется снова выбрать папку.", rootToRemove?.displayName ?? ""))
        }
    }
}
