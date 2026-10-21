import SwiftUI

/// Единая строка двух приложений: отсутствие кнопки не обещает доступную установку.
public struct PlannedHermesConnection: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Hermes — запланировано", systemImage: "clock")
            Text("Будущее подключение. Установка и доступ к данным пока недоступны.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("hermes-planned")
    }
}
