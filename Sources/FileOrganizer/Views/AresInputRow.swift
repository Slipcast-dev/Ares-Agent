import SwiftUI

/// Постоянная подпись не исчезает после ввода, в отличие от placeholder.
/// Поле занимает ширину строки, а не сжимается справа в grouped Form macOS.
/// Нативная рамка сохраняет фокус, клавиатурную навигацию и адаптацию к теме.
struct AresInputRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            content()
                .labelsHidden()
                .accessibilityLabel(title)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
