import AppKit
import EcosystemLocalization
import Combine
import Foundation
import FileOrganizerCore
import EcosystemLocalIPC

/// Повторная выдача права сохраняет прежний rootID и индекс, но требует новый
/// системный выбор папки. Путь из импортированной БД не заменяет этот выбор.
@MainActor final class MigratedRootAccessViewModel: ObservableObject {
    @Published private(set) var roots: [AuthorizedRoot] = []
    @Published private(set) var busy = false
    @Published var message: AresMessage?
    private let client: Result<LocalRPCClient, Error>
    init(client: Result<LocalRPCClient, Error>) { self.client = client }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { roots = try await client.get().call("grant.pending", LocalEmpty()); message = nil }
        catch {
            // safe() сводит неизвестную ошибку к конечному typed code. Только
            // встроенный текст этого enum — ключ; текст ОС не ищется в словаре.
            message = AresMessage(LocalRuntimeFailure.safe(error).localizedDescription)
        }
    }
    func renew(_ root: AuthorizedRoot, language: AgentLanguage) async {
        // Панель получает готовую копию текста в момент открытия, без смены
        // региональных настроек или перевода имени пользовательской папки.
        let l10n = AresLocalization(language: language)
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = l10n.format("Заново выберите папку «%@». Правила останутся выключенными.", args: root.displayName)
        panel.prompt = l10n.text("Выбрать папку заново")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let _: AuthorizedRoot = try await client.get().call("grant.renew", RootRenewal(id: root.id, bookmark: data))
            busy = false; await refresh(); message = AresMessage("Доступ подтверждён. Правила можно проверить и включить вручную.")
        } catch { busy = false; message = AresMessage("Не удалось подтвердить доступ. Выберите ту же папку, которая указана в перенесённых данных.") }
    }
}
