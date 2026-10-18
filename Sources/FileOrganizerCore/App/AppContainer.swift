import Foundation
import EcosystemLocalIPC

/// Минимальный контейнер зависимостей Core. Он принимает путь базы извне вместо
/// глобального синглтона: тесты могут использовать временный файл, а приложение
/// позднее выберет Application Support после согласия пользователя.
public final class AppContainer {
    public let migrations: any DatabaseMigrating
    public let fileRepository: any FileRepository
    public let authorizedRootAccess: AuthorizedRootAccessService
    public let indexingService: FileIndexingService
    public let duplicateDetectionService: DuplicateDetectionService
    public let keychainSecretStore: KeychainSecretStore
    public let taskCoordinator: TaskCoordinator
    public let ruleCoordinator: RuleCoordinator

    public let localRuntimeClient: Result<LocalRPCClient, Error>?
    public let isLocalRuntimeClient: Bool

    public init(
        databaseURL: URL,
        migrations: (any DatabaseMigrating)? = nil,
        localRole: LocalRole = .gui, allowLocalClient: Bool = true,
        localClientOverride: Result<LocalRPCClient, Error>? = nil,
        runtimeOwnedStore: Bool = false
    ) {
        let remote: Result<LocalRPCClient, Error>?
        if let localClientOverride { remote = localClientOverride }
        else if allowLocalClient, ProcessInfo.processInfo.environment["ARES_LOCAL_RUNTIME_CONFIG"] != nil {
            remote = Result {
                guard let (config, _) = try LocalRuntimeConfiguration.environment(domain: "ares") else { throw LocalRuntimeFailure.invalidConfiguration }
                return LocalRPCClient(configuration: config, role: localRole)
            }
        } else { remote = nil }
        localRuntimeClient = remote
        isLocalRuntimeClient = remote != nil
        self.migrations = remote.map { ClientStorePreparation(configuration: $0) } ?? (migrations ?? SQLiteMigrator(databaseURL: databaseURL, runtimeOwned: runtimeOwnedStore))
        self.fileRepository = remote.map { RemoteFileRepository(client: $0) as any FileRepository } ?? SQLiteFileRepository(databaseURL: databaseURL, runtimeOwned: runtimeOwnedStore)
        self.authorizedRootAccess = AuthorizedRootAccessService(repository: fileRepository, remote: remote)
        self.indexingService = FileIndexingService()
        self.duplicateDetectionService = DuplicateDetectionService()
        self.keychainSecretStore = KeychainSecretStore()
        self.taskCoordinator = TaskCoordinator(repository: fileRepository, access: authorizedRootAccess, remote: remote)
        self.ruleCoordinator = RuleCoordinator(repository: fileRepository, access: authorizedRootAccess,
            lockURL: databaseURL.appendingPathExtension("rules.lock"), remote: remote)
    }

    /// Вызывается при контролируемом старте приложения. Миграции не затрагивают
    /// файлы пользователя: они изменяют только внутреннюю SQLite-базу приложения.
    public func preparePersistentStore() throws {
        try migrations.migrate()
    }

    /// Единая точка выбора БД гарантирует, что GUI и отдельный MCP-процесс
    /// обращаются к одному локальному, а не временному, состоянию.
    public static func defaultApplicationSupportDatabaseURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["ARES_LOCAL_RUNTIME_CONFIG"] {
            // Клиент даже не создаёт прежнюю Application Support папку.
            return URL(fileURLWithPath: path).deletingLastPathComponent()
                .appendingPathComponent("ares-state/domain.sqlite")
        }
        let manager = FileManager.default
        let baseURL = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileOrganizer", isDirectory: true)
        try? manager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL.appendingPathComponent("FileOrganizer.sqlite")
    }
}

/// Проверяем профиль, но не открываем/мигрируем БД из клиентского процесса.
private struct ClientStorePreparation: DatabaseMigrating {
    let configuration: Result<LocalRPCClient, Error>
    func migrate() throws { _ = try configuration.get() }
    func appliedVersion() throws -> Int { throw LocalRuntimeFailure.denied }
}
