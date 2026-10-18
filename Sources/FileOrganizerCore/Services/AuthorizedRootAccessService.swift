import Foundation
import EcosystemLocalIPC

/// Управляет security-scoped bookmarks. Этот слой — единственное место, где
/// абсолютный URL разрешённой папки восстанавливается из приватных данных.
public actor AuthorizedRootAccessService {
    private let repository: any FileRepository

    private let remote: Result<LocalRPCClient, Error>?
    public init(repository: any FileRepository, remote: Result<LocalRPCClient, Error>? = nil) {
        self.repository = repository; self.remote = remote
    }

    public func addRoot(from selectedURL: URL) async throws -> AuthorizedRoot {
        if let remote {
            // Implicit bookmark передаёт право выбранной папки. Persistent
            // bookmark создаёт сам runtime и никогда не возвращает клиенту.
            let bookmark = try selectedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return try await remote.get().call("grant.add", RootTransfer(bookmark: bookmark))
        }
        let values = try selectedURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .nameKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AuthorizedRootAccessError.notDirectory
        }

        // withSecurityScope сохраняет право доступа, выданное пользователем в
        // NSOpenPanel, между перезапусками. withoutUI при восстановлении ниже
        // не позволяет фоновому сервису неожиданно показывать системные диалоги.
        let bookmarkData = try selectedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let root = AuthorizedRoot(
            displayName: values.name ?? selectedURL.lastPathComponent,
            relativePathHint: selectedURL.path
        )
        try await repository.save(root: root, bookmarkData: bookmarkData)
        return root
    }

    /// Повторный явный выбор должен соответствовать сохранённому пути. Сам hint
    /// не выдаёт прав: новый security-scoped bookmark создаётся из выбранного URL.
    public func renewRoot(_ id: UUID, from selectedURL: URL) async throws -> AuthorizedRoot {
        guard let old = try await repository.root(withID: id),
              URL(fileURLWithPath: old.relativePathHint).standardizedFileURL.path == selectedURL.standardizedFileURL.path,
              try await repository.bookmarkData(forRootID: id)?.isEmpty == true else { throw AuthorizedRootAccessError.missingBookmark }
        let values = try selectedURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw AuthorizedRootAccessError.notDirectory }
        let bookmark = try selectedURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await repository.save(root: old, bookmarkData: bookmark)
        return old
    }

    public func resolveURL(for root: AuthorizedRoot) async throws -> URL {
        if let remote {
            let bookmark: Data = try await remote.get().call("grant.resolve", LocalTaskID(root.id))
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw AuthorizedRootAccessError.staleBookmark }
            return url
        }
        guard let bookmarkData = try await repository.bookmarkData(forRootID: root.id), !bookmarkData.isEmpty else {
            throw AuthorizedRootAccessError.missingBookmark
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else { throw AuthorizedRootAccessError.staleBookmark }
        return url
    }
}

public enum AuthorizedRootAccessError: Error, LocalizedError, Sendable {
    case notDirectory
    case missingBookmark
    case staleBookmark
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .notDirectory: "Можно добавить только папку."
        case .missingBookmark: "Для этой папки не сохранено разрешение доступа."
        case .staleBookmark: "Разрешение для папки устарело. Выберите её снова."
        case .accessDenied: "macOS не предоставила доступ к выбранной папке."
        }
    }
}
