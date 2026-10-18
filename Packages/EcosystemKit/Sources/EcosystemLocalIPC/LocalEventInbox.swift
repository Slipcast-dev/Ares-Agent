import Darwin
import Foundation

/// Внешний ИИ получает только агрегатное описание события. Идентификаторы корней
/// нужны серверу для повторной проверки действующего разрешения перед выдачей.
public struct LocalInboxEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: String
    public let capability: String
    public let rootIDs: [UUID]
    public let summary: String
    /// Сохраняется вместе с событием: crash между append и уведомлением
    /// не может превратить обычное завершение в важный системный баннер.
    public let notificationEligible: Bool?
    public let createdAt: Date
    public let expiresAt: Date
}

public enum LocalInboxDeliveryState: String, Codable, Sendable {
    case pending, claimed, acked, expired
}

public struct LocalInboxDelivery: Codable, Sendable {
    public let event: LocalInboxEvent
    public let state: LocalInboxDeliveryState
    public let token: UUID?
    public let leaseExpiresAt: Date?
}

/// Доставка сообщения и право начать обработку — разные состояния.
/// Проигравшему клиенту не выдаются ни чужой токен, ни идентификатор задачи.
public struct LocalProcessingClaim: Codable, Sendable {
    public let eventID: UUID
    public let claimed: Bool
    public let state: String
    public let processingToken: UUID?
    public let leaseExpiresAt: Date?
}

/// Доставка независима для каждого доверенного IPC-клиента: подтверждение Codex
/// не удаляет событие Harness. Actor принадлежит одному runtime-процессу агента.
/// Очередь ничего не запускает: модель должна явно опрашивать и подтверждать её.
public actor LocalEventInbox {
    private struct Receipt: Codable {
        var token: UUID?
        var authorizationID: UUID?
        var leaseExpiresAt: Date?
        var acknowledged = false
    }
    private struct ProcessingReceipt: Codable {
        let client: LocalMCPClient
        let authorizationID: UUID
        let token: UUID
        let leaseExpiresAt: Date
        var finished: Bool = false
    }
    private struct EffectReceipt: Codable {
        let client: LocalMCPClient
        let authorizationID: UUID
    }
    private struct Entry: Codable {
        let event: LocalInboxEvent
        var receipts: [String: Receipt] = [:]
        // Optional сохраняет чтение E7/E8 JSON без миграции пользовательских данных.
        var processing: ProcessingReceipt? = nil
        var effects: [String: EffectReceipt]? = nil
    }
    private struct Document: Codable {
        var version = 1
        var entries: [Entry] = []
    }
    public static let maximumEvents = 4096
    public static let maximumDocumentBytes = 8_388_608
    private static let filename = "event-inbox-v1.json"
    private let directory: URL
    private var document: Document

    public init(directory: URL) throws {
        self.directory = directory
        let parent = try Self.openDirectory(directory)
        defer { close(parent) }
        let descriptor = openat(parent, Self.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            guard errno == ENOENT else { throw LocalRuntimeFailure.invalidConfiguration }
            document = Document()
            return
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.privateRegularFile(info),
              info.st_size <= Self.maximumDocumentBytes else { throw LocalRuntimeFailure.invalidConfiguration }
        // Читаем именно проверенный дескриптор, чтобы замена имени не подменила JSON.
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= Self.maximumDocumentBytes else { throw LocalRuntimeFailure.invalidConfiguration }
        }
        do {
            let decoded = try JSONDecoder().decode(Document.self, from: bytes)
            try Self.validate(decoded)
            document = decoded
        } catch { throw LocalRuntimeFailure.invalidConfiguration }
    }

    /// Повторное событие с тем же стабильным ID возвращает исходную запись даже
    /// после ack/restart; повторный wake не создаёт новую доставку.
    @discardableResult
    public func append(id: UUID, kind: String, capability: String, rootIDs: [UUID] = [],
                       summary: String, notificationEligible: Bool = true, now: Date = Date(), ttl: TimeInterval = 604_800) throws -> LocalInboxEvent {
        if let old = document.entries.first(where: { $0.event.id == id }) { return old.event }
        guard now.timeIntervalSinceReferenceDate.isFinite, ttl.isFinite, (1...2_592_000).contains(ttl),
              Self.safeIdentifier(kind), Self.safeIdentifier(capability),
              rootIDs.count <= 128, Set(rootIDs).count == rootIDs.count,
              Self.safeSummary(summary) else { throw LocalRuntimeFailure.invalidRequest }
        var next = document
        // Только истёкшие записи можно вытеснять. Неподтверждённые события не
        // теряются молча при переполнении: вызывающий получает busy и повторяет.
        if next.entries.count >= Self.maximumEvents { next.entries.removeAll { $0.event.expiresAt <= now } }
        guard next.entries.count < Self.maximumEvents else { throw LocalRuntimeFailure.busy }
        let event = LocalInboxEvent(id: id, kind: kind, capability: capability, rootIDs: rootIDs,
                                   summary: summary, notificationEligible: notificationEligible, createdAt: now, expiresAt: now.addingTimeInterval(ttl))
        next.entries.append(Entry(event: event))
        try persist(next)
        return event
    }

    /// allowedEventIDs вычисляет runtime из текущей политики, а не из MCP payload.
    /// nil предназначен для локального GUI; пустое множество выдаёт пустой ответ.
    public func list(client: LocalMCPClient, allowedEventIDs: Set<UUID>? = nil,
                     limit: Int = 50, now: Date = Date()) throws -> [LocalInboxDelivery] {
        try validateQuery(limit: limit, now: now)
        return document.entries.reversed().lazy.filter { allowedEventIDs?.contains($0.event.id) ?? true }
            .prefix(limit).map { delivery($0, client: client, now: now) }
    }

    /// Серверу нужен весь ограниченный каталог для фильтрации capability/roots.
    /// Этот метод не является MCP-инструментом и не раскрывает токены доставки.
    public func events(limit: Int = 4096, now: Date = Date()) throws -> [LocalInboxEvent] {
        guard (1...Self.maximumEvents).contains(limit), now.timeIntervalSinceReferenceDate.isFinite
        else { throw LocalRuntimeFailure.invalidRequest }
        return Array(document.entries.lazy.map(\.event).filter { $0.expiresAt > now }.prefix(limit))
    }

    public func event(id: UUID) -> LocalInboxEvent? {
        document.entries.first { $0.event.id == id }?.event
    }

    public func claim(client: LocalMCPClient, allowedEventIDs: Set<UUID>? = nil,
                      limit: Int = 50, leaseSeconds: TimeInterval = 120,
                      authorizationID: UUID? = nil, now: Date = Date()) throws -> [LocalInboxDelivery] {
        try validateQuery(limit: limit, now: now)
        guard leaseSeconds.isFinite, (30...300).contains(leaseSeconds) else { throw LocalRuntimeFailure.invalidRequest }
        var next = document
        var output: [LocalInboxDelivery] = []
        for index in next.entries.indices {
            guard output.count < limit else { break }
            let entry = next.entries[index]
            guard allowedEventIDs?.contains(entry.event.id) ?? true,
                  entry.event.createdAt <= now,
                  delivery(entry, client: client, now: now).state == .pending else { continue }
            next.entries[index].receipts[client.rawValue] = Receipt(
                token: UUID(), authorizationID: authorizationID, leaseExpiresAt: min(now.addingTimeInterval(leaseSeconds), entry.event.expiresAt))
            output.append(delivery(next.entries[index], client: client, now: now))
        }
        if !output.isEmpty { try persist(next) }
        return output
    }

    public func ack(id: UUID, client: LocalMCPClient, token: UUID, authorizationID: UUID? = nil, now: Date = Date()) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let index = document.entries.firstIndex(where: { $0.event.id == id }),
              document.entries[index].event.expiresAt > now,
              let receipt = document.entries[index].receipts[client.rawValue],
              receipt.token == token, receipt.authorizationID == authorizationID, let deadline = receipt.leaseExpiresAt, deadline > now
        else { throw LocalRuntimeFailure.denied }
        // Повтор ack того же действующего lease безопасен при потере RPC-ответа.
        if receipt.acknowledged { return }
        var next = document
        next.entries[index].receipts[client.rawValue]?.acknowledged = true
        try persist(next)
    }

    /// Глобальный lease обрабатывает одно событие, сохраняя независимую
    /// доставку обоим клиентам. Повтор владельца возвращает тот же токен.
    public func claimProcessing(id: UUID, client: LocalMCPClient, authorizationID: UUID,
                                leaseSeconds: TimeInterval = 120, now: Date = Date()) throws -> LocalProcessingClaim {
        guard now.timeIntervalSinceReferenceDate.isFinite, leaseSeconds.isFinite,
              (30...300).contains(leaseSeconds),
              let index = document.entries.firstIndex(where: { $0.event.id == id }),
              document.entries[index].event.createdAt <= now,
              document.entries[index].event.expiresAt > now else { throw LocalRuntimeFailure.denied }
        let entry = document.entries[index]
        if let receipt = entry.processing {
            if receipt.finished { return LocalProcessingClaim(eventID: id, claimed: false, state: "finished", processingToken: nil, leaseExpiresAt: nil) }
            if receipt.leaseExpiresAt > now {
                guard receipt.client == client, receipt.authorizationID == authorizationID else {
                    return LocalProcessingClaim(eventID: id, claimed: false, state: "busy", processingToken: nil, leaseExpiresAt: nil)
                }
                return LocalProcessingClaim(eventID: id, claimed: true, state: "claimed", processingToken: receipt.token, leaseExpiresAt: receipt.leaseExpiresAt)
            }
        }
        let receipt = ProcessingReceipt(client: client, authorizationID: authorizationID, token: UUID(),
                                        leaseExpiresAt: min(now.addingTimeInterval(leaseSeconds), entry.event.expiresAt))
        // Старый runtime понимает только version=1 и обязан отказать после
        // появления новых гарантий, а не затереть processing/effects при downgrade.
        var next = document; next.version = 2; next.entries[index].processing = receipt
        try persist(next)
        return LocalProcessingClaim(eventID: id, claimed: true, state: "claimed", processingToken: receipt.token, leaseExpiresAt: receipt.leaseExpiresAt)
    }

    /// Подтверждение обработки не изменяет receipts доставки другого клиента.
    /// Оно не заявляет об успехе файловой задачи: её результат читается отдельно.
    public func ackProcessing(id: UUID, client: LocalMCPClient, token: UUID,
                              authorizationID: UUID, now: Date = Date()) throws {
        let index = try processingIndex(id: id, client: client, token: token, authorizationID: authorizationID, now: now, allowFinished: true)
        if document.entries[index].processing?.finished == true { return }
        var next = document; next.entries[index].processing?.finished = true
        try persist(next)
    }

    /// Резервируем смысл эффекта ДО admission в SQLite. В случае crash между
    /// двумя хранилищами сохраняем запрет для другого владельца, а не угадываем
    /// исход. Повтор того же grant безопасно дойдёт до UNIQUE ключа очереди.
    public func reserveProcessingEffect(id: UUID, client: LocalMCPClient, token: UUID,
                                        authorizationID: UUID, key: String, now: Date = Date()) throws {
        let index = try processingIndex(id: id, client: client, token: token, authorizationID: authorizationID, now: now)
        guard Self.safeIdentifier(key) else { throw LocalRuntimeFailure.invalidRequest }
        if let old = document.entries[index].effects?[key] {
            guard old.client == client, old.authorizationID == authorizationID else { throw LocalRuntimeFailure.conflict }
            return
        }
        var next = document
        var effects = next.entries[index].effects ?? [:]
        guard effects.count < 32 else { throw LocalRuntimeFailure.busy }
        effects[key] = EffectReceipt(client: client, authorizationID: authorizationID)
        next.entries[index].effects = effects
        try persist(next)
    }

    private func processingIndex(id: UUID, client: LocalMCPClient, token: UUID,
                                 authorizationID: UUID, now: Date, allowFinished: Bool = false) throws -> Int {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let index = document.entries.firstIndex(where: { $0.event.id == id }),
              document.entries[index].event.createdAt <= now, document.entries[index].event.expiresAt > now,
              let receipt = document.entries[index].processing, receipt.client == client,
              receipt.authorizationID == authorizationID, receipt.token == token,
              receipt.leaseExpiresAt > now, allowFinished || !receipt.finished else { throw LocalRuntimeFailure.denied }
        return index
    }

    private func delivery(_ entry: Entry, client: LocalMCPClient, now: Date) -> LocalInboxDelivery {
        let receipt = entry.receipts[client.rawValue]
        let state: LocalInboxDeliveryState
        if entry.event.expiresAt <= now { state = .expired }
        else if receipt?.acknowledged == true { state = .acked }
        else if let deadline = receipt?.leaseExpiresAt, deadline > now { state = .claimed }
        else { state = .pending }
        return LocalInboxDelivery(event: entry.event, state: state,
                                  token: state == .claimed || state == .acked ? receipt?.token : nil,
                                  leaseExpiresAt: state == .claimed || state == .acked ? receipt?.leaseExpiresAt : nil)
    }

    private func validateQuery(limit: Int, now: Date) throws {
        guard (1...50).contains(limit), now.timeIntervalSinceReferenceDate.isFinite else { throw LocalRuntimeFailure.invalidRequest }
    }
    private static func safeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
    private static func safeSummary(_ value: String) -> Bool {
        // Producer передаёт фиксированный агрегатный заголовок, а не ошибку ОС,
        // имя файла или текст документа. Дополнительно отсекаем пути и управление.
        !value.isEmpty && value.utf8.count <= 512 && !value.contains("/") && !value.contains("\\")
            && !value.contains("~") && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func validate(_ value: Document) throws {
        guard [1, 2].contains(value.version), value.entries.count <= maximumEvents,
              Set(value.entries.map { $0.event.id }).count == value.entries.count else { throw LocalRuntimeFailure.invalidConfiguration }
        for entry in value.entries {
            let event = entry.event, ttl = event.expiresAt.timeIntervalSince(event.createdAt)
            guard safeIdentifier(event.kind), safeIdentifier(event.capability), safeSummary(event.summary),
                  event.createdAt.timeIntervalSinceReferenceDate.isFinite, ttl.isFinite, (1...2_592_000).contains(ttl),
                  event.rootIDs.count <= 128, Set(event.rootIDs).count == event.rootIDs.count,
                  Set(entry.receipts.keys).isSubset(of: Set(LocalMCPClient.allCases.map(\.rawValue)))
            else { throw LocalRuntimeFailure.invalidConfiguration }
            guard value.version == 2 || (entry.processing == nil && entry.effects == nil) else { throw LocalRuntimeFailure.invalidConfiguration }
            if let processing = entry.processing {
                guard processing.leaseExpiresAt.timeIntervalSinceReferenceDate.isFinite,
                      processing.leaseExpiresAt > event.createdAt, processing.leaseExpiresAt <= event.expiresAt
                else { throw LocalRuntimeFailure.invalidConfiguration }
            }
            if let effects = entry.effects {
                guard effects.count <= 32, effects.keys.allSatisfy(Self.safeIdentifier) else { throw LocalRuntimeFailure.invalidConfiguration }
            }
            for receipt in entry.receipts.values {
                guard receipt.token != nil, let deadline = receipt.leaseExpiresAt,
                      deadline.timeIntervalSinceReferenceDate.isFinite, deadline > event.createdAt,
                      deadline <= event.expiresAt else { throw LocalRuntimeFailure.invalidConfiguration }
            }
        }
    }
    private static func privateRegularFile(_ info: stat) -> Bool {
        info.st_uid == geteuid() && info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 && info.st_mode & 0o077 == 0
    }
    private static func openDirectory(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalRuntimeFailure.invalidConfiguration }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(fd); throw LocalRuntimeFailure.invalidConfiguration
        }
        return fd
    }
    private func persist(_ next: Document) throws {
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= Self.maximumDocumentBytes else { throw LocalRuntimeFailure.busy }
        let parent = try Self.openDirectory(directory)
        defer { close(parent) }
        var oldInfo = stat()
        let oldStatus = fstatat(parent, Self.filename, &oldInfo, AT_SYMLINK_NOFOLLOW)
        guard oldStatus == 0 ? Self.privateRegularFile(oldInfo) : errno == ENOENT else { throw LocalRuntimeFailure.invalidConfiguration }
        let temporary = ".event-inbox-" + UUID().uuidString
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LocalRuntimeFailure.operationFailed }
        defer { close(descriptor); unlinkat(parent, temporary, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LocalRuntimeFailure.operationFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, renameat(parent, temporary, parent, Self.filename) == 0,
              fsync(parent) == 0 else { throw LocalRuntimeFailure.operationFailed }
        document = next
    }
}
