import SwiftUI
import EcosystemUI

/// Главная оболочка окна. Она управляет только выбранным разделом; данные и
/// будущие файловые задачи будут принадлежать отдельным ViewModel, а не View.
struct ContentView: View {
    @ObservedObject var viewModel: OverviewViewModel
    @State private var selectedSection: AppSection? = .overview
    @StateObject private var ruleMonitor = RuleDirectoryMonitor()
    @State private var ruleRootID: UUID?
    @State private var rulePaths: Set<String>?
    @State private var navigationID = UUID()

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedSection)
                .navigationSplitViewColumnWidth(min: EcosystemSidebarStyle.minimumWidth,
                                                ideal: EcosystemSidebarStyle.idealWidth,
                                                max: EcosystemSidebarStyle.maximumWidth)
        } detail: {
            detailView(for: selectedSection ?? .overview)
                .navigationTitle(selectedSection?.title ?? AppSection.overview.title)
        }
        .navigationSplitViewStyle(.balanced)
        // Не навязываем окну прежний минимум 900×600. Нулевые нижние границы
        // позволяют пользователю сжимать окно, не наследуя минимум контента.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .task {
            viewModel.load()
            guard !viewModel.container.isLocalRuntimeClient else { return }
            await ruleMonitor.refresh(container: viewModel.container)
            // Сверка снимков каждые 30 секунд работает только с включёнными
            // правилами. Этот цикл отменяется при закрытии окна приложения.
            try? await viewModel.container.ruleCoordinator.poll(appLaunch: true)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { break }
                await ruleMonitor.refresh(container: viewModel.container)
                try? await viewModel.container.ruleCoordinator.poll()
            }
        }
        .onDisappear { ruleMonitor.stop() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FileOrganizer.ruleNavigation"))) { event in
            guard let rootID = event.userInfo?["rootID"] as? UUID else { return }
            if event.userInfo?["duplicates"] as? Bool == true {
                selectedSection = .duplicates
                viewModel.findDuplicates(rootID: rootID)
            } else {
                ruleRootID = rootID
                rulePaths = Set(event.userInfo?["paths"] as? [String] ?? [])
                navigationID = UUID()
                selectedSection = .files
            }
        }
        .alert("Не удалось завершить операцию", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func detailView(for section: AppSection) -> some View {
        switch section {
        case .overview:
            OverviewView(viewModel: viewModel)
        case .duplicates:
            DuplicatesView(viewModel: viewModel)
        case .files:
            FilesView(container: viewModel.container, initialRootID: ruleRootID, includedPaths: rulePaths).id(navigationID)
        case .settings:
            SettingsOverviewView(container: viewModel.container)
        case .rules:
            RulesView(container: viewModel.container)
        case .history:
            RuleHistoryView(container: viewModel.container)
        }
    }
}
