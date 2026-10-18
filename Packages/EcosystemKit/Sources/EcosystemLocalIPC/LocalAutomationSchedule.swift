import Darwin
import Foundation

/// Календарное расписание сохраняет часовой пояс, поэтому смена системного пояса
/// не переносит уже подтверждённое пользователем локальное время запуска.
public enum LocalAutomationTrigger: Codable, Equatable, Sendable {
    case interval(seconds: Int)
    case once(at: Date)
    /// weekday использует Calendar: 1 — воскресенье, 7 — суббота.
    case weekly(weekday: Int, hour: Int, minute: Int, timeZoneIdentifier: String)
    case daily(hour: Int, minute: Int, timeZoneIdentifier: String)
}

public struct LocalAutomationSchedule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var trigger: LocalAutomationTrigger
    public let createdAt: Date
    public var paused: Bool
    public var catchUpOnce: Bool
    public init(id: UUID = UUID(), trigger: LocalAutomationTrigger, createdAt: Date, paused: Bool = false, catchUpOnce: Bool = true) {
        self.id = id; self.trigger = trigger; self.createdAt = createdAt; self.paused = paused; self.catchUpOnce = catchUpOnce
    }
}

/// Ключ передаётся durable-очереди как idempotencyKey. Повторная выдача после
/// падения между admission и acknowledge не создаёт вторую задачу.
public struct LocalAutomationSlot: Codable, Equatable, Sendable {
    public let scheduleID: UUID
    public let scheduledAt: Date
    public let idempotencyKey: String
}

public struct LocalFileChangeSlot: Codable, Equatable, Sendable {
    public let rootID: UUID
    public let signature: String
    public let idempotencyKey: String
}

public actor LocalAutomationScheduleStore {
    private struct ScheduleState: Codable {
        var schedule: LocalAutomationSchedule
        var lastScheduledAt: Date
        var pending: LocalAutomationSlot?
    }
    private struct Observation: Codable {
        var signature: String?
        var changedAt: Date
        var firstChangedAt: Date
        var acknowledgedSignature: String?
        var pending: LocalFileChangeSlot?
        var generation: Int64 = 0
    }
    private struct Document: Codable {
        var version = 1
        var schedules: [ScheduleState] = []
        var observations: [String: Observation] = [:]
    }
    private let file: URL
    private var document: Document

    /// Хранилище относится только к одному агенту. Запись чужого владельца,
    /// symlink, hardlink и неизвестная версия считаются ошибкой, а не сбросом.
    public init(directory: URL) throws {
        file = directory.appendingPathComponent("automation-schedule-v1.json")
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_mode & 0o077 == 0,
                  info.st_size <= 1_048_576 else { throw LocalRuntimeFailure.invalidConfiguration }
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1, document.schedules.count <= 64,
                  document.observations.count <= 128,
                  Set(document.schedules.map { $0.schedule.id }).count == document.schedules.count else {
                throw LocalRuntimeFailure.invalidConfiguration
            }
            for state in document.schedules {
                try Self.validate(state.schedule)
                guard Self.validDate(state.lastScheduledAt), state.lastScheduledAt >= state.schedule.createdAt else { throw LocalRuntimeFailure.invalidConfiguration }
                if let pending = state.pending {
                    guard pending.scheduleID == state.schedule.id, Self.validDate(pending.scheduledAt),
                          pending.scheduledAt > state.lastScheduledAt,
                          pending.idempotencyKey == Self.slotKey(id: state.schedule.id, date: pending.scheduledAt) else { throw LocalRuntimeFailure.invalidConfiguration }
                }
            }
            for (key, observation) in document.observations {
                guard UUID(uuidString: key) != nil,
                      observation.signature.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
                      observation.acknowledgedSignature.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
                      Self.validDate(observation.changedAt), Self.validDate(observation.firstChangedAt),
                      observation.generation >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
                if let pending = observation.pending {
                    guard pending.rootID.uuidString == key, !pending.signature.isEmpty,
                          pending.signature.utf8.count <= 256,
                          pending.idempotencyKey == "change:\(key):\(observation.generation)" else { throw LocalRuntimeFailure.invalidConfiguration }
                }
            }
        } else {
            guard errno == ENOENT else { throw LocalRuntimeFailure.invalidConfiguration }
            document = Document()
        }
    }

    public func schedules() -> [LocalAutomationSchedule] { document.schedules.map(\.schedule) }

    public func upsert(_ schedule: LocalAutomationSchedule) throws {
        try Self.validate(schedule)
        var next = document
        if let index = next.schedules.firstIndex(where: { $0.schedule.id == schedule.id }) {
            if next.schedules[index].schedule == schedule { return }
            // Изменённый триггер не должен исполнить pending старой конфигурации.
            if next.schedules[index].schedule.trigger != schedule.trigger || next.schedules[index].schedule.createdAt != schedule.createdAt {
                next.schedules[index] = ScheduleState(schedule: schedule, lastScheduledAt: schedule.createdAt)
            } else { next.schedules[index].schedule = schedule }
        } else {
            guard next.schedules.count < 64 else { throw LocalRuntimeFailure.invalidRequest }
            next.schedules.append(ScheduleState(schedule: schedule, lastScheduledAt: schedule.createdAt))
        }
        try persist(next)
    }

    public func remove(_ id: UUID) throws {
        var next = document; next.schedules.removeAll { $0.schedule.id == id }; try persist(next)
    }

    public func setPaused(_ id: UUID, paused: Bool, now: Date) throws {
        guard now.timeIntervalSince1970.isFinite, abs(now.timeIntervalSince1970) < 100_000_000_000,
              let index = document.schedules.firstIndex(where: { $0.schedule.id == id }) else { throw LocalRuntimeFailure.invalidRequest }
        var next = document
        next.schedules[index].schedule.paused = paused
        next.schedules[index].pending = nil
        // Ручная пауза не накапливает скрытую очередь. После возобновления ждём
        // следующий слот; откат часов не уменьшает durable watermark.
        next.schedules[index].lastScheduledAt = max(next.schedules[index].lastScheduledAt, now)
        try persist(next)
    }

    public func due(now: Date, recovering: Bool = false) throws -> [LocalAutomationSlot] {
        guard now.timeIntervalSince1970.isFinite, abs(now.timeIntervalSince1970) < 100_000_000_000 else { throw LocalRuntimeFailure.invalidRequest }
        var next = document; var result: [LocalAutomationSlot] = []; var changed = false
        for index in next.schedules.indices {
            let state = next.schedules[index]
            guard !state.schedule.paused else { continue }
            if let pending = state.pending { result.append(pending); continue }
            guard let date = Self.latestSlot(state.schedule, now: now), date > state.lastScheduledAt else { continue }
            if recovering && !state.schedule.catchUpOnce {
                next.schedules[index].lastScheduledAt = date; changed = true
                continue
            }
            // Один последний пропущенный слот предотвращает шторм после сна.
            let key = Self.slotKey(id: state.schedule.id, date: date)
            let slot = LocalAutomationSlot(scheduleID: state.schedule.id, scheduledAt: date, idempotencyKey: key)
            next.schedules[index].pending = slot; result.append(slot); changed = true
        }
        if changed { try persist(next) }; return result
    }

    public func acknowledge(_ slot: LocalAutomationSlot, now: Date) throws {
        guard now.timeIntervalSince1970.isFinite, abs(now.timeIntervalSince1970) < 100_000_000_000,
              let index = document.schedules.firstIndex(where: { $0.schedule.id == slot.scheduleID }) else { throw LocalRuntimeFailure.invalidRequest }
        guard document.schedules[index].pending == slot else { return }
        var next = document
        // Если admission был задержан, пропускаем уже устаревшие интервалы.
        let latest = Self.latestSlot(next.schedules[index].schedule, now: now) ?? slot.scheduledAt
        next.schedules[index].lastScheduledAt = max(slot.scheduledAt, latest)
        next.schedules[index].pending = nil
        try persist(next)
    }

    /// signature — ограниченный агрегированный fingerprint, не список путей.
    /// nil означает недоступный корень: он никогда не считается пустой папкой.
    /// maximumWait ограничивает окно наблюдения, но НЕ разрешает запуск на
    /// нестабильном файле: продолжающаяся запись всегда ждёт quietPeriod.
    public func observe(rootID: UUID, signature: String?, now: Date,
                        quietPeriod: TimeInterval = 5, maximumWait: TimeInterval = 60) throws -> LocalFileChangeSlot? {
        guard now.timeIntervalSince1970.isFinite, abs(now.timeIntervalSince1970) < 100_000_000_000, quietPeriod.isFinite, maximumWait.isFinite,
              quietPeriod >= 1, maximumWait >= quietPeriod,
              signature.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else { throw LocalRuntimeFailure.invalidRequest }
        let key = rootID.uuidString
        guard document.observations[key] != nil || document.observations.count < 128 else { throw LocalRuntimeFailure.invalidRequest }
        var next = document
        var value = next.observations[key] ?? Observation(signature: nil, changedAt: now, firstChangedAt: now)
        if signature == nil {
            value.signature = nil; value.changedAt = now; value.firstChangedAt = now
            // Уже созданный слот тоже не выдаётся, пока OS-доступ отсутствует.
            next.observations[key] = value; try persist(next); return nil
        }
        if value.signature != signature || now < value.changedAt {
            value.signature = signature; value.changedAt = now
        }
        if now.timeIntervalSince(value.firstChangedAt) > maximumWait { value.firstChangedAt = now }
        if let pending = value.pending {
            next.observations[key] = value; try persist(next); return pending
        }
        if value.signature != value.acknowledgedSignature && now.timeIntervalSince(value.changedAt) >= quietPeriod {
            guard value.generation < Int64.max else { throw LocalRuntimeFailure.invalidRequest }
            value.generation += 1
            value.pending = LocalFileChangeSlot(rootID: rootID, signature: signature!,
                                               idempotencyKey: "change:\(key):\(value.generation)")
        }
        next.observations[key] = value; try persist(next); return value.pending
    }

    public func acknowledgeChange(_ slot: LocalFileChangeSlot) throws {
        let key = slot.rootID.uuidString
        guard document.observations[key]?.pending == slot else { return }
        var next = document
        next.observations[key]?.acknowledgedSignature = slot.signature
        next.observations[key]?.pending = nil
        try persist(next)
    }

    public func removeObservation(rootID: UUID) throws {
        var next = document; next.observations.removeValue(forKey: rootID.uuidString); try persist(next)
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && abs(date.timeIntervalSince1970) < 100_000_000_000
    }

    private static func slotKey(id: UUID, date: Date) -> String {
        "schedule:\(id.uuidString):\(Int64((date.timeIntervalSince1970 * 1000).rounded()))"
    }

    private static func validate(_ schedule: LocalAutomationSchedule) throws {
        guard schedule.createdAt.timeIntervalSince1970.isFinite,
              abs(schedule.createdAt.timeIntervalSince1970) < 100_000_000_000 else { throw LocalRuntimeFailure.invalidRequest }
        switch schedule.trigger {
        case .interval(let seconds):
            guard (30...31_536_000).contains(seconds) else { throw LocalRuntimeFailure.invalidRequest }
        case .once(let date):
            guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) < 100_000_000_000, date > schedule.createdAt else { throw LocalRuntimeFailure.invalidRequest }
        case .weekly(let weekday, let hour, let minute, let identifier):
            guard (1...7).contains(weekday), (0...23).contains(hour), (0...59).contains(minute), TimeZone(identifier: identifier) != nil else { throw LocalRuntimeFailure.invalidRequest }
        case .daily(let hour, let minute, let identifier):
            guard (0...23).contains(hour), (0...59).contains(minute), TimeZone(identifier: identifier) != nil else { throw LocalRuntimeFailure.invalidRequest }
        }
    }

    private static func latestSlot(_ schedule: LocalAutomationSchedule, now: Date) -> Date? {
        guard now >= schedule.createdAt else { return nil }
        switch schedule.trigger {
        case .interval(let seconds):
            let count = floor(now.timeIntervalSince(schedule.createdAt) / Double(seconds))
            return count >= 1 ? schedule.createdAt.addingTimeInterval(count * Double(seconds)) : nil
        case .once(let at): return at <= now ? at : nil
        case .daily(let hour, let minute, let identifier):
            return latestCalendarSlot(schedule, now: now, weekday: nil, hour: hour, minute: minute, identifier: identifier)
        case .weekly(let weekday, let hour, let minute, let identifier):
            return latestCalendarSlot(schedule, now: now, weekday: weekday, hour: hour, minute: minute, identifier: identifier)
        }
    }

    private static func latestCalendarSlot(_ schedule: LocalAutomationSchedule, now: Date,
                                           weekday: Int?, hour: Int, minute: Int, identifier: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: identifier) else { return nil }; calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        // nextTime: отсутствующие 02:30 весной выполняются в 03:00.
        // first: повторившиеся 01:30 осенью выполняются только первый раз.
        for offset in 0...(weekday == nil ? 2 : 8) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            if let weekday, calendar.component(.weekday, from: day) != weekday { continue }
            guard let date = calendar.nextDate(after: day.addingTimeInterval(-1),
                                              matching: DateComponents(hour: hour, minute: minute, second: 0),
                                              matchingPolicy: .nextTime, repeatedTimePolicy: .first),
                  calendar.isDate(date, inSameDayAs: day) else { continue }
            if date <= now && date > schedule.createdAt { return date }
        }
        return nil
    }

    private func persist(_ next: Document) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard data.count <= 1_048_576 else { throw LocalRuntimeFailure.invalidRequest }
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".automation-\(UUID().uuidString).tmp")
        // O_EXCL/O_NOFOLLOW исключают подмену временного файла. fsync до rename
        // сохраняет и данные, и атомарность при аварийном завершении процесса.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        defer { close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LocalRuntimeFailure.invalidConfiguration }; offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        let parent = open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard parent >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        document = next
    }
}
