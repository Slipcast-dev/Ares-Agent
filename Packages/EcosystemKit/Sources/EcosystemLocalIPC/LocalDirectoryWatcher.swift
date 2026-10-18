import CoreServices
import Foundation

/// FSEvents наблюдает всю иерархию. Событие служит только сигналом повторной
/// проверки: пути из callback не становятся параметрами файлового действия.
public final class LocalDirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.ecosystem.file-observation")
    private var stream: FSEventStreamRef?
    private var urls: [URL] = []
    private let changed: @Sendable () -> Void
    public init(changed: @escaping @Sendable () -> Void) { self.changed = changed }
    public func replace(_ roots: [URL]) {
        queue.sync {
            stopLocked()
            urls = roots.filter { $0.startAccessingSecurityScopedResource() }
            guard !urls.isEmpty else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, pointer, _, _, _, _ in
                guard let pointer else { return }
                Unmanaged<LocalDirectoryWatcher>.fromOpaque(pointer).takeUnretainedValue().changed()
            }
            stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, urls.map(\.path) as CFArray,
                                         FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
                                         FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer))
            guard let stream else { stopLocked(); return }
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) { stopLocked() }
        }
    }
    private func stopLocked() {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
        for url in urls { url.stopAccessingSecurityScopedResource() }
        urls = []
    }
    public func stop() { queue.sync { stopLocked() } }
    deinit { stopLocked() }
}
