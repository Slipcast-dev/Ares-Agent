import AppKit
import Combine
import Foundation
import FileOrganizerCore
import EcosystemLocalIPC

/// Повторная выдача права сохраняет прежний rootID и индекс, но требует новый
/// системный выбор папки. Путь из импортированной БД не заменяет этот выбор.
@MainActor final class MigratedRootAccessViewModel: ObservableObject {
    @Published private(set) var roots: [AuthorizedRoot] = []
    @Published private(set) var busy = false
    @Published var message: String?
    private let client: Result<LocalRPCClient, Error>
    init(client: Result<LocalRPCClient, Error>) { self.client = client }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { roots = try await client.get().call("grant.pending", LocalEmpty()); message = nil }
        catch { message = LocalRuntimeFailure.safe(error).localizedDescription }
    }
    func renew(_ root: AuthorizedRoot) async {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = "Заново выберите папку «\(root.displayName)». Правила останутся выключенными."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        do {
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let _: AuthorizedRoot = try await client.get().call("grant.renew", RootRenewal(id: root.id, bookmark: data))
            busy = false; await refresh(); message = "Доступ подтверждён. Правила можно проверить и включить вручную."
        } catch { busy = false; message = "Не удалось подтвердить доступ. Выберите ту же папку, которая указана в перенесённых данных." }
    }
}
