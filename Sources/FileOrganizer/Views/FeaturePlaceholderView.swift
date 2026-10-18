import SwiftUI

/// Единое честное состояние для модулей, которые уже видны в навигации, но ещё
/// не реализованы соответствующим checkpoint. Так интерфейс остаётся целостным,
/// не создавая фиктивных таблиц и результатов анализа.
struct FeaturePlaceholderView: View {
    let section: AppSection

    var body: some View {
        ContentUnavailableView(
            section.title,
            systemImage: section.systemImage,
            description: Text("Этот раздел будет доступен в одном из следующих этапов разработки.")
        )
        .accessibilityElement(children: .combine)
    }
}
