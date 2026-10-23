import SwiftUI
import EcosystemUI
import EcosystemLocalization

/// Единое честное состояние для модулей, которые уже видны в навигации, но ещё
/// не реализованы соответствующим checkpoint. Так интерфейс остаётся целостным,
/// не создавая фиктивных таблиц и результатов анализа.
struct FeaturePlaceholderView: View {
    @Environment(\.agentLanguage) private var language
    private var l10n: AresLocalization { AresLocalization(language: language) }
    let section: AppSection

    var body: some View {
        ContentUnavailableView(
            l10n.text(section.title),
            systemImage: section.systemImage,
            description: Text(l10n.text("Этот раздел будет доступен в одном из следующих этапов разработки."))
        )
        .accessibilityElement(children: .combine)
    }
}
