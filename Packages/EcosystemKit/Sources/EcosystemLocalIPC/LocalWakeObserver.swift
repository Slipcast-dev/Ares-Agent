import AppKit
import Foundation

/// Повторный wake/mount — сигнал сверить сохранённое состояние, а не команда
/// заново выполнить действия. Coalescing использует monotonic uptime, не часы.
public final class LocalWakeObserver: @unchecked Sendable {
    private let center: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private let lock = NSLock()
    private var lastSignal: TimeInterval = -.infinity
    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter, changed: @escaping @Sendable () -> Void) {
        self.center = center
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                let now = ProcessInfo.processInfo.systemUptime
                let allowed = now - self.lastSignal >= 5
                if allowed { self.lastSignal = now }
                self.lock.unlock()
                if allowed { changed() }
            })
        }
    }
    deinit { for observer in observers { center.removeObserver(observer) } }
}
