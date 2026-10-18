import Foundation

/// Безопасно сохранённый корень, к которому пользователь явно предоставил доступ.
///
/// Закладка (`bookmarkData`) хранится отдельно от этой модели: её нельзя отдавать
/// интерфейсу агентов и нельзя включать в отчёты. Так метаданные разрешённой папки
/// можно безопасно передавать между слоями приложения.
public struct AuthorizedRoot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let relativePathHint: String
    public let createdAt: Date
    public let lastScannedAt: Date?

    public init(
        id: UUID = UUID(),
        displayName: String,
        relativePathHint: String,
        createdAt: Date = Date(),
        lastScannedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.relativePathHint = relativePathHint
        self.createdAt = createdAt
        self.lastScannedAt = lastScannedAt
    }
}
