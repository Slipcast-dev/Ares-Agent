import SwiftUI
import EcosystemLocalization
import EcosystemUI
import FileOrganizerCore

/// Приложение хранит свою selection и собственные разделы. Общая библиотека
/// отвечает только за одинаковые размеры, цвета, выделение и клавиатуру.
struct SidebarView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }

    @Binding var selection: AppSection?
    private var selectedID: Binding<String?> {
        Binding(get: { selection?.rawValue }, set: { selection = $0.flatMap(AppSection.init(rawValue:)) })
    }
    var body: some View {
        EcosystemSidebar(title: FileOrganizerProduct.displayName, items: AppSection.allCases.map {
            EcosystemSidebarItem(id: $0.rawValue, title: l10n.text($0.title), symbol: $0.systemImage)
        }, selection: selectedID)
    }
    static func destination(from selection: AppSection?, direction: MoveCommandDirection) -> AppSection? {
        EcosystemSidebar.destination(in: AppSection.allCases.map(\.rawValue), from: selection?.rawValue,
                                     direction: direction).flatMap(AppSection.init(rawValue:))
    }
}
