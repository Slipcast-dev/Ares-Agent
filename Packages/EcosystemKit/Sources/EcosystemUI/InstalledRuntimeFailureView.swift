import AppKit
import SwiftUI

/// Ошибка запуска показывается после создания окна SwiftUI. NSAlert.runModal
/// в App.init блокирует инициализацию приложения и делает окно недоступным AX.
public struct InstalledRuntimeFailureView: View {
    private let message: String
    public init(message: String) { self.message = message }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Не удалось запустить службу", systemImage: "exclamationmark.triangle")
                .font(.title2)
            Text(message).textSelection(.enabled)
            Text("Данные профиля сохранены. После устранения причины повторно откройте приложение.")
                .foregroundStyle(.secondary)
            if let instruction = Bundle.main.url(forResource: "ProfileMaintenance", withExtension: "md") {
                Button("Инструкция по обновлению и восстановлению") { NSWorkspace.shared.open(instruction) }
            }
            Button("Закрыть приложение") { NSApplication.shared.terminate(nil) }
        }
        .padding(28).frame(minWidth: 480, minHeight: 220)
    }
}
