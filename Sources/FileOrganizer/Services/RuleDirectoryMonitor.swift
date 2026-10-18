import Foundation
import Combine
import Darwin
import FileOrganizerCore

/// DispatchSource даёт быстрые сигналы изменения выбранных корней. Сверка
/// снимков каждые 30 секунд дополняет их для вложенных каталогов и потерянных
/// событий; это также поддерживает возрастные условия без файлового события.
@MainActor
final class RuleDirectoryMonitor: ObservableObject {
    private var sources: [UUID: DispatchSourceFileSystemObject] = [:]
    func refresh(container: AppContainer) async {
        guard !container.isLocalRuntimeClient else { stop(); return }
        guard let rules = try? await container.fileRepository.ruleObjects(AutomationRule.self, table: .rules) else { return }
        let ids = Set(rules.filter { $0.enabled && $0.event != .manual }.compactMap(\.rootID))
        for id in Array(sources.keys) where !ids.contains(id) { sources.removeValue(forKey: id)?.cancel() }
        for id in ids where sources[id] == nil {
            guard let root = try? await container.fileRepository.root(withID: id),
                  let url = try? await container.authorizedRootAccess.resolveURL(for: root),
                  url.startAccessingSecurityScopedResource() else { continue }
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { url.stopAccessingSecurityScopedResource(); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib], queue: .global(qos: .utility))
            source.setEventHandler { [coordinator = container.ruleCoordinator] in Task { try? await coordinator.poll() } }
            source.setCancelHandler { close(descriptor); url.stopAccessingSecurityScopedResource() }
            sources[id] = source
            source.resume()
        }
    }
    func stop() { for source in sources.values { source.cancel() }; sources.removeAll() }
}
