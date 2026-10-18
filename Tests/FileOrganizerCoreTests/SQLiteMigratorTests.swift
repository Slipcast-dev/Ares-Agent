import Foundation
import XCTest
@testable import FileOrganizerCore

final class SQLiteMigratorTests: XCTestCase {
    /// Новая установка должна получить последнюю схему за один запуск, а повторный
    /// запуск не должен создавать вторую запись той же миграции.
    func testMigratorAppliesInitialSchemaOnlyOnce() throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let migrator = SQLiteMigrator(databaseURL: databaseURL)
        try migrator.migrate()
        XCTAssertEqual(try migrator.appliedVersion(), 10)

        try migrator.migrate()
        XCTAssertEqual(try migrator.appliedVersion(), 10)
    }

    /// Контейнер остаётся пригодным для тестирования, потому что путь и мигратор
    /// можно явно внедрить без обращения к глобальному состоянию приложения.
    func testContainerPreparesInjectedPersistentStore() throws {
        let databaseURL = makeTemporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let container = AppContainer(databaseURL: databaseURL)
        try container.preparePersistentStore()

        XCTAssertEqual(try container.migrations.appliedVersion(), 10)
    }

    private func makeTemporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }
}
