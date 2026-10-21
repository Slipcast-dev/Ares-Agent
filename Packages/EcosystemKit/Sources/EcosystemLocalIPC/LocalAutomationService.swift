import Darwin
import Foundation

public struct LocalAutomationSettings: Codable, Sendable {
    public var paused = false
    public var notificationsEnabled = false
    public var createdAt = Date()
    public init() {}
}
public struct LocalAutomationStatus: Codable, Sendable {
    public let settings: LocalAutomationSettings
    public let notificationAuthorization: String
    public let pendingEvents: Int
    public let lastFailure: String?
}
/// Один экземпляр на домен. Никаких вызовов модели: события только сохраняются
/// до явного claim клиентом. Ошибки системного баннера не блокируют локальную работу.
public actor LocalAutomationService {
    private struct Document: Codable {
        var version = 1
        var settings = LocalAutomationSettings()
        var notified: [UUID] = []
        var nextNotificationAt: Date? = nil
    }
    public nonisolated let inbox: LocalEventInbox
    public let schedules: LocalAutomationScheduleStore
    private let file: URL
    private let domain: String
    private let notifications: any LocalNotificationSending
    private var document: Document
    private var flushing = false
    private var lastFailure: String?
    private var inboxFailure: String?
    public init(directory: URL, domain: String, notifications: any LocalNotificationSending = NativeLocalNotifications()) throws {
        guard ["ares", "athena"].contains(domain) else { throw LocalRuntimeFailure.invalidConfiguration }
        self.domain = domain; self.notifications = notifications
        file = directory.appendingPathComponent("automation-v1.json")
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                  info.st_mode & 0o077 == 0, info.st_size <= 1_048_576 else { throw LocalRuntimeFailure.invalidConfiguration }
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1, document.notified.count <= 4096 else { throw LocalRuntimeFailure.invalidConfiguration }
        } else { guard errno == ENOENT else { throw LocalRuntimeFailure.invalidConfiguration }; document = Document() }
        inbox = try LocalEventInbox(directory: directory)
        schedules = try LocalAutomationScheduleStore(directory: directory)
        // Фиксируем cutoff до первого доменного события, чтобы после restart
        // не импортировать старую историю как новые уведомления.
        if !FileManager.default.fileExists(atPath: file.path) {
            try Self.write(document, to: file)
        }
    }
    private static func write(_ next: Document, to file: URL) throws {
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalRuntimeFailure.operationFailed }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw LocalRuntimeFailure.operationFailed }
        let parent = open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw LocalRuntimeFailure.operationFailed }; defer { close(parent) }
        guard fsync(parent) == 0 else { throw LocalRuntimeFailure.operationFailed }
    }
    private func persist(_ next: Document) throws { try Self.write(next, to: file); document = next }
    public func paused() -> Bool { document.settings.paused }
    public func cutoff() -> Date { document.settings.createdAt }
    public func configure(paused: Bool?, notificationsEnabled: Bool?) async throws {
        let pauseChanged = paused.map { $0 != document.settings.paused } ?? false
        var next = document
        if let paused { next.settings.paused = paused }
        if let notificationsEnabled { next.settings.notificationsEnabled = notificationsEnabled }
        // Не держим копию document через await: иначе настройка могла бы
        // перезаписать записанный параллельно receipt уведомления.
        try persist(next)
        if pauseChanged, let paused {
            for schedule in await schedules.schedules() { try await schedules.setPaused(schedule.id, paused: paused, now: Date()) }
        }
    }
    public func requestNotifications() async throws -> String { try await notifications.requestAuthorization() }
    public func status() async throws -> LocalAutomationStatus {
        LocalAutomationStatus(settings: document.settings, notificationAuthorization: await notifications.authorization(),
                              pendingEvents: try await inbox.events().count, lastFailure: inboxFailure ?? lastFailure)
    }
    public func record(id: UUID, kind: String, capability: String, roots: [UUID] = [], capturedAt: Date, significant: Bool) async throws {
        guard capturedAt >= document.settings.createdAt else { return }
        // Свободный текст правила/имя файла никогда не становится AI prompt.
        let summary = significant ? "Локальный агент: требуется внимание. Подробности доступны в приложении." : "Локальный агент завершил операцию."
        do {
            _ = try await inbox.append(id: id, kind: kind, capability: capability, rootIDs: roots, summary: summary, notificationEligible: significant, now: capturedAt)
            inboxFailure = nil
        } catch {
            inboxFailure = "Событие не добавлено во входящие. Исходная история доступна в приложении."
            throw error
        }
        if !significant && !document.notified.contains(id) {
            var next = document; next.notified.append(id); next.notified = Array(next.notified.suffix(4096)); try persist(next)
        }
    }
    /// При пустом inbox/выключенном opt-in таймер не нужен. Только свежая
    /// недоставленная запись даёт retry/cooldown; системное согласие не меняется.
    public func notificationRetryDelay(now: Date = Date()) async -> TimeInterval? {
        guard document.settings.notificationsEnabled else { return nil }
        do {
            let events = try await inbox.events(now: now)
            let notified = Set(document.notified)
            let pending = events.filter { $0.notificationEligible != false && !notified.contains($0.id) && now.timeIntervalSince($0.createdAt) <= 3600 }
            guard !pending.isEmpty else { return nil }
            // После перевода часов назад сохранённое событие может стать
            // будущим. Не теряем его: ждём createdAt, а не засыпаем навсегда.
            if pending.allSatisfy({ $0.createdAt > now }) {
                return pending.map { $0.createdAt.timeIntervalSince(now) }.min()
            }
            if let next = document.nextNotificationAt, next > now { return max(1, next.timeIntervalSince(now)) }
            return 60 // Отказ ОС/ошибка доставки не создают частый цикл пробуждений.
        } catch { return 60 }
    }
    public func flushNotifications(now: Date = Date()) async {
        guard !flushing, document.settings.notificationsEnabled, document.nextNotificationAt.map({ now >= $0 }) ?? true else { return }
        flushing = true; defer { flushing = false }
        // Тихая provisional-доставка остаётся разрешённой, но её отдельное
        // состояние в GUI не должно выдаваться за разрешение видимых баннеров.
        let authorization = await notifications.authorization()
        guard authorization == "authorized" || authorization == "provisional" else { return }
        do {
            // Не догоняем баннерами старые события после недели запрета. AI inbox
            // хранит их до TTL независимо от состояния системных уведомлений.
            let events = try await inbox.events(now: now)
            for event in events.filter({  $0.notificationEligible != false && !document.notified.contains($0.id) && (0...3600).contains(now.timeIntervalSince($0.createdAt)) }).prefix(1) {
                guard document.settings.notificationsEnabled else { return }
                try await notifications.send(id: event.id, title: domain == "ares" ? "Арес" : "Афина", body: event.summary)
                var next = document; next.nextNotificationAt = now.addingTimeInterval(60); next.notified.append(event.id); next.notified = Array(next.notified.suffix(4096)); try persist(next)
            }
            lastFailure = nil
        } catch { lastFailure = "Уведомление не доставлено; событие сохранено." }
    }
}
