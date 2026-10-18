import Combine
import Foundation
import EcosystemLocalIPC

/// Модель одинакового операторского раздела двух приложений. Она читает только
/// разрешённые GUI-проекции; решение и проверка revision остаются на сервере.
@MainActor public final class LocalRecoveryViewModel: ObservableObject {
    @Published public private(set) var items: [RecoveryItem] = []
    @Published public private(set) var details: RecoveryDetails?
    @Published public private(set) var recorded: [RecoveryReceipt] = []
    @Published public private(set) var unresolved: [RecoveryReceipt] = []
    @Published public private(set) var busy = false
    @Published public var message: String?
    @Published public var notes: [UUID: String] = [:]
    @Published public var outcomes: [UUID: String] = [:]
    @Published public var factsChecked = false
    private let client: Result<LocalRPCClient, Error>
    public init(client: Result<LocalRPCClient, Error>) { self.client = client }
    public var readyToConfirm: Bool {
        details?.item.canConfirm == true && factsChecked && unresolved.allSatisfy {
            ["done", "confirmedNoEffect"].contains(outcomes[$0.id] ?? "") &&
            (20...2000).contains((notes[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count)
        }
    }
    public func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let connection = try client.get(); var offset: Int64 = 0; var rows: [RecoveryItem] = []
            repeat {
                try Task.checkCancellation()
                let page: RecoveryPage = try await connection.call("recovery.list", RecoveryListRequest(offset: offset))
                rows += page.items
                guard let next = page.nextOffset else { break }; offset = next
            } while true
            items = rows; details = nil; recorded = []; unresolved = []; message = nil
        } catch { message = LocalRuntimeFailure.safe(error).localizedDescription }
    }
    public func inspect(_ id: UUID) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let connection = try client.get(); var offset: Int64 = 0; var pending: [RecoveryReceipt] = []
            var selected: RecoveryDetails?
            repeat {
                try Task.checkCancellation()
                let page: RecoveryDetails = try await connection.call("recovery.inspect", RecoveryInspectRequest(id: id, offset: offset))
                selected = page; pending += page.receipts
                guard let next = page.nextOffset else { break }; offset = next
            } while true
            details = selected; recorded = pending; unresolved = pending.filter { $0.state == .started }; notes = [:]; outcomes = [:]; factsChecked = false; message = nil
        } catch { message = LocalRuntimeFailure.safe(error).localizedDescription }
    }
    public func confirm() async {
        guard !busy, readyToConfirm, let selected = details else { return }
        busy = true
        do {
            let decisions = unresolved.map { RecoveryDecision(receiptID: $0.id,
                state: outcomes[$0.id] == "done" ? .done : .confirmedNoEffect, note: notes[$0.id] ?? "") }
            let _: LocalEmpty = try await client.get().call("recovery.confirm",
                RecoveryConfirmation(id: selected.item.id, revision: selected.item.revision, decisions: decisions))
            busy = false; await refresh()
            message = "Сверка сохранена. Задание не повторялось. Приостановленные правила остаются выключенными."
        } catch { busy = false; message = LocalRuntimeFailure.safe(error).localizedDescription }
    }
}
