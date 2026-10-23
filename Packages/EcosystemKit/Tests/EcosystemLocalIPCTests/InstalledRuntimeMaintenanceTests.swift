import Darwin
import Foundation
import SQLite3
import XCTest
import EcosystemContracts
import EcosystemRuntimeSupport
@testable import EcosystemLocalIPC

/// Реальные файлы, flock, SQLite и подписи: mocks не доказывают сохранение
/// WAL, аварийного latch или границы владельца при замене каталога.
final class InstalledRuntimeMaintenanceTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ecosystem-maintenance-unit-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    private func app(_ domain: String, generation: String) throws -> URL {
        let p = try InstalledRuntimeBootstrap.Product(domain: domain)
        let app = root.appendingPathComponent(generation + "/" + p.name + ".app")
        let mac = app.appendingPathComponent("Contents/MacOS")
        let runtime = app.appendingPathComponent("Contents/Library/LoginItems/" + p.name + "Background.app/Contents/MacOS")
        for dir in [mac, runtime] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        for (directory, name) in [(mac, p.gui), (mac, p.mcp), (runtime, p.runtime)] + (p.worker.map { [(mac, $0)] } ?? []) {
            let file = directory.appendingPathComponent(name)
            try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: file)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = ["--force", "--sign", "-", "--identifier", generation + "." + name, file.path]
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        return app
    }
    private func profile(_ domain: String) -> URL { root.appendingPathComponent(domain + "/Runtime") }
    private func setup(_ domain: String = "ares") throws -> (URL, URL) {
        let application = try app(domain, generation: "old")
        let profile = profile(domain)
        try InstalledRuntimeBootstrap.prepare(domain: domain, application: application, profile: profile)
        return (application, profile)
    }
    private func put(_ value: String, _ file: URL) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(value.utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func seed(_ domain: String, profile: URL, stopped: Bool = false) async throws {
        let state = profile.appendingPathComponent(domain + "-state")
        let queue = try DurableTaskQueue(directory: state.appendingPathComponent("queue"), agentID: AgentID(rawValue: domain)!)
        for i in 0..<125 {
            let request = try TaskRequest(requestID: UUID(), agentID: AgentID(rawValue: domain)!,
                capabilityID: domain == "ares" ? "file.scan" : "system.get_metrics", parameters: ["sample": i], origin: .user,
                idempotencyKey: "preserved-" + String(i), rootID: domain == "ares" ? UUID() : nil, createdAt: UTCTimestamp("2026-10-19T12:00:00Z"))
            _ = try await queue.accept(QueueSubmission(request: request, resources: ["fixture." + String(i)], mutating: false))
        }
        if stopped { try await queue.emergencyStop() }
        for name in ["automation-v1.json", "events-v1.json", "settings.json", "bookmarks.bin"] {
            try put("fixture-" + name + "-Ω", state.appendingPathComponent(name))
        }
        let language = try LocalLanguagePreferences(directory: state, domain: domain)
        _ = try await language.set(.en)
        // Согласие выдаётся только синтетическому in-process GUI, без TCC и
        // доступа к реальным каталогам. Проверяем настоящий Codable документ.
        let policy = try LocalAccessPolicy(directory: state, domain: domain)
        var draft = LocalAccessDraft(); draft.client = .codex
        draft.capabilities = [domain == "ares" ? "file.list_roots" : "system.get_metrics"]
        let plan = try await policy.request(draft, client: .codex)
        _ = try await policy.approve(plan.id, fingerprint: plan.fingerprint, role: .gui)
        // Возвращение из функции освобождает единственного actor-владельца.
    }
    private func dataEntries(_ profile: URL, _ domain: String) throws -> [InstalledRuntimeMaintenance.Entry] {
        try InstalledRuntimeMaintenance.inventory(profile).filter { $0.path.hasPrefix(domain + "-state/") }
    }
    func testUninstallPreserves125TasksGrantsSettingsAndCanRepeatForBothDomains() async throws {
        for domain in ["ares", "athena"] {
            let (application, profile) = try setup(domain)
            try await seed(domain, profile: profile, stopped: true)
            let before = try dataEntries(profile, domain)
            for _ in 0..<2 {
                let checkpoint = try InstalledRuntimeMaintenance.prepareUninstall(domain: domain, profile: profile)
                XCTAssertEqual(try dataEntries(profile, domain), before)
                XCTAssertEqual(try dataEntries(checkpoint.appendingPathComponent("profile"), domain), before)
                let marker = try InstalledRuntimeBootstrap.readObject(profile.appendingPathComponent("profile.json"))
                XCTAssertEqual(marker["persistent"] as? [String: String], [:])
            }
            // Повторная установка того же кода не должна создавать пустой профиль.
            try InstalledRuntimeBootstrap.prepare(domain: domain, application: application, profile: profile)
            XCTAssertEqual(try dataEntries(profile, domain), before)
            let policy = try LocalAccessPolicy(directory: profile.appendingPathComponent(domain + "-state"), domain: domain)
            let grants = await policy.state().grants
            XCTAssertEqual(grants.count, 1)
        }
    }
    func testUninstallRefusesForeignDomainAndTamperedCodeWithoutChangingState() async throws {
        let (_, profile) = try setup()
        try await seed("ares", profile: profile)
        let before = try dataEntries(profile, "ares")
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.prepareUninstall(domain: "athena", profile: profile))
        let mcp = profile.appendingPathComponent("FileOrganizerMCP-codex")
        try fm.removeItem(at: mcp); try put("tampered", mcp)
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.prepareUninstall(domain: "ares", profile: profile))
        XCTAssertEqual(try dataEntries(profile, "ares"), before)
    }
    func testBothDomainsUpgradeRollbackPreserveAll125TasksAndPrivateState() async throws {
        for domain in ["ares", "athena"] {
            let (old, profile) = try setup(domain)
            try await seed(domain, profile: profile)
            let before = try dataEntries(profile, domain)
            let configuration = try LocalRuntimeConfiguration.load(profile.appendingPathComponent(domain + ".json"), domain: domain)
            let new = try app(domain, generation: "new")
            let checkpoint = try InstalledRuntimeMaintenance.upgrade(domain: domain, application: new, profile: profile)
            XCTAssertEqual(try dataEntries(profile, domain), before)
            try InstalledRuntimeBootstrap.prepare(domain: domain, application: new, profile: profile)
            let updated = try LocalRuntimeConfiguration.load(profile.appendingPathComponent(domain + ".json"), domain: domain)
            XCTAssertNotEqual(updated.serverRequirement, configuration.serverRequirement)
            XCTAssertEqual(updated.endpoints["gui"]?.service, configuration.endpoints["gui"]?.service)
            try InstalledRuntimeMaintenance.rollback(domain: domain, profile: profile, checkpoint: checkpoint)
            XCTAssertEqual(try dataEntries(profile, domain), before)
            try InstalledRuntimeBootstrap.prepare(domain: domain, application: old, profile: profile)
            let policy = try LocalAccessPolicy(directory: profile.appendingPathComponent(domain + "-state"), domain: domain)
            let grants = await policy.state().grants
            XCTAssertEqual(grants.count, 1); XCTAssertEqual(grants.first?.draft.client, .codex)
            XCTAssertEqual(try LocalRuntimeConfiguration.load(profile.appendingPathComponent(domain + ".json"), domain: domain).serverRequirement, configuration.serverRequirement)
        }
    }
    func testEmergencyStopLatchSurvivesUpgradeAndRollback() async throws {
        let (_, profile) = try setup()
        try await seed("ares", profile: profile, stopped: true)
        let checkpoint = try InstalledRuntimeMaintenance.upgrade(domain: "ares", application: app("ares", generation: "new"), profile: profile)
        try InstalledRuntimeMaintenance.rollback(domain: "ares", profile: profile, checkpoint: checkpoint)
        let queue = try DurableTaskQueue(directory: profile.appendingPathComponent("ares-state/queue"), agentID: .ares)
        let status = try await queue.emergencyStatus()
        XCTAssertTrue(status.stopped)
        let tasks = try await queue.tasks(limit: 500)
        XCTAssertEqual(tasks.count, 125); XCTAssertTrue(tasks.allSatisfy { $0.status == .cancelled })
    }
    func testRevocationOrNewWorkRefusesRollbackAndKeepsCurrentBytes() async throws {
        let (_, profile) = try setup()
        try await seed("ares", profile: profile)
        let checkpoint = try InstalledRuntimeMaintenance.upgrade(domain: "ares", application: app("ares", generation: "new"), profile: profile)
        let file = profile.appendingPathComponent("ares-state/access-v1.json")
        let policy = try LocalAccessPolicy(directory: profile.appendingPathComponent("ares-state"), domain: "ares")
        let grant = await policy.state().grants.first!
        _ = try await policy.revoke(grant.id, role: .gui)
        let before = try InstalledRuntimeMaintenance.inventory(profile)
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.rollback(domain: "ares", profile: profile, checkpoint: checkpoint))
        XCTAssertEqual(try InstalledRuntimeMaintenance.inventory(profile), before)
        let reloaded = try LocalAccessPolicy(directory: profile.appendingPathComponent("ares-state"), domain: "ares")
        let remaining = await reloaded.state().grants
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }
    func testOwnerLockBlocksSnapshotEvenWithoutRegisteredService() throws {
        let (_, profile) = try setup()
        let directory = profile.appendingPathComponent("ares-state/queue")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("runtime-owner.lock")
        let fd = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600); XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.backup(domain: "ares", profile: profile))
        XCTAssertFalse(fm.fileExists(atPath: profile.deletingLastPathComponent().appendingPathComponent("Backups").path))
    }
    func testCorruptBackupAndSymlinksAreRejected() throws {
        let (_, profile) = try setup()
        try put("data", profile.appendingPathComponent("ares-state/settings.json"))
        let checkpoint = try InstalledRuntimeMaintenance.backup(domain: "ares", profile: profile)
        try put("tampered", checkpoint.appendingPathComponent("profile/ares-state/settings.json"))
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.rollback(domain: "ares", profile: profile, checkpoint: checkpoint))
        try fm.createSymbolicLink(at: profile.appendingPathComponent("alias"), withDestinationURL: root)
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.backup(domain: "ares", profile: profile))
    }
    func testForeignDomainAndCodeTamperAreRejected() throws {
        let (_, profile) = try setup()
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.backup(domain: "athena", profile: profile))
        let binary = profile.appendingPathComponent("FileOrganizerMCP-codex")
        let handle = try FileHandle(forWritingTo: binary); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.backup(domain: "ares", profile: profile))
    }
    func testInterruptedJournalBlocksPrepareStartAndVerifiesBothGenerations() throws {
        let (old, profile) = try setup()
        let before = try InstalledRuntimeMaintenance.inventory(profile)
        let retained = profile.deletingLastPathComponent().appendingPathComponent(".retained-test")
        try fm.copyItem(at: profile, to: retained)
        let journal = profile.deletingLastPathComponent().appendingPathComponent(".maintenance-Runtime.json")
        let value = InstalledRuntimeMaintenance.Journal(version: 1, domain: "ares", before: before, after: before, retained: retained.path)
        try JSONEncoder().encode(value).write(to: journal)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
        XCTAssertThrowsError(try InstalledRuntimeBootstrap.prepare(domain: "ares", application: old, profile: profile))
        XCTAssertThrowsError(try InstalledRuntimeBootstrap.start(domain: "ares", profile: profile))
        XCTAssertThrowsError(try LocalRuntimeCLI.configurationFile(arguments: ["--config", profile.appendingPathComponent("ares.json").path]))
        // exclusive создаёт persistence lock; он должен присутствовать в обоих
        // fsync-поколениях настоящей транзакции, как и в этой crash-фикстуре.
        try put("", profile.appendingPathComponent(".persistence.lock"))
        try put("", retained.appendingPathComponent(".persistence.lock"))
        let ready = try InstalledRuntimeMaintenance.inventory(profile)
        let readyJournal = InstalledRuntimeMaintenance.Journal(version: 1, domain: "ares", before: ready, after: ready, retained: retained.path)
        try JSONEncoder().encode(readyJournal).write(to: journal)
        try InstalledRuntimeMaintenance.recover(domain: "ares", profile: profile)
        XCTAssertFalse(fm.fileExists(atPath: journal.path))
        try InstalledRuntimeBootstrap.prepare(domain: "ares", application: old, profile: profile)
    }
    func testColdSnapshotIncludesCommittedWALWithoutModifyingOriginal() throws {
        let (_, profile) = try setup()
        let database = profile.appendingPathComponent("ares-state/domain.sqlite")
        try fm.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let writer = Process(); writer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        writer.arguments = ["-c", "import os,sqlite3,sys; os.umask(0o077); c=sqlite3.connect(sys.argv[1]); c.execute('PRAGMA journal_mode=WAL'); c.execute('CREATE TABLE example(value TEXT)'); c.execute(\"INSERT INTO example VALUES ('committed-Ω')\"); c.commit(); os._exit(0)", database.path]
        try writer.run(); writer.waitUntilExit(); XCTAssertEqual(writer.terminationStatus, 0)
        XCTAssertTrue(fm.fileExists(atPath: database.path + "-wal"))
        let before = try dataEntries(profile, "ares")
        let checkpoint = try InstalledRuntimeMaintenance.backup(domain: "ares", profile: profile)
        XCTAssertEqual(try dataEntries(profile, "ares"), before)
        XCTAssertEqual(try dataEntries(checkpoint.appendingPathComponent("profile"), "ares"), before)
        var db: OpaquePointer?; defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_open_v2(checkpoint.appendingPathComponent("profile/ares-state/domain.sqlite").path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var statement: OpaquePointer?; defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT value FROM example", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "committed-Ω")
    }
    func testNewQueueOwnerOrWorkPreventsDataLosingRollback() async throws {
        let (_, profile) = try setup()
        try await seed("ares", profile: profile)
        let checkpoint = try InstalledRuntimeMaintenance.upgrade(domain: "ares", application: app("ares", generation: "new"), profile: profile)
        // Даже один запуск меняет fencing epoch; старый snapshot не должен
        // возвращать lease/token в прошлое. Дополнительно меняем все задачи.
        var queue: DurableTaskQueue? = try DurableTaskQueue(directory: profile.appendingPathComponent("ares-state/queue"), agentID: .ares)
        try await queue!.emergencyStop()
        queue = nil
        let before = try dataEntries(profile, "ares")
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.rollback(domain: "ares", profile: profile, checkpoint: checkpoint))
        XCTAssertEqual(try dataEntries(profile, "ares"), before)
    }
    func testLanguageChangeAfterUpgradeRefusesDataLosingRollback() async throws {
        let (_, profile) = try setup()
        try await seed("ares", profile: profile)
        let checkpoint = try InstalledRuntimeMaintenance.upgrade(domain: "ares", application: app("ares", generation: "language-new"), profile: profile)
        let language = try LocalLanguagePreferences(directory: profile.appendingPathComponent("ares-state"), domain: "ares")
        _ = try await language.set(.ru)
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.rollback(domain: "ares", profile: profile, checkpoint: checkpoint))
        let retained = await language.status(); XCTAssertEqual(retained.preference, .ru)
    }

    func testOptInChangeCannotBeRestoredByCodeRollback() throws {
        let (_, profile) = try setup()
        let markerURL = profile.appendingPathComponent("profile.json")
        var marker = try InstalledRuntimeBootstrap.readObject(markerURL)
        marker["persistent"] = ["ares": "/private/previous-opt-in"]
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
        let checkpoint = try InstalledRuntimeMaintenance.upgrade(domain: "ares", application: app("ares", generation: "new"), profile: profile)
        let updated = try InstalledRuntimeBootstrap.readObject(markerURL)
        XCTAssertEqual(updated["persistent"] as? [String: String], ["ares": "/private/previous-opt-in"])
        marker = updated; marker["persistent"] = [String: String]()
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.rollback(domain: "ares", profile: profile, checkpoint: checkpoint))
    }
    func testRealExchangeRecoversBeforeAndAfterAtomicRename() throws {
        struct Injected: Error {}
        for (domain, crashAfterSwap) in [("ares", false), ("athena", true)] {
            let (application, profile) = try setup(domain)
            try put("", profile.appendingPathComponent(".persistence.lock"))
            let before = try InstalledRuntimeMaintenance.inventory(profile)
            let stage = profile.deletingLastPathComponent().appendingPathComponent(".stage-test")
            try fm.copyItem(at: profile, to: stage)
            let markerURL = stage.appendingPathComponent("profile.json")
            var marker = try InstalledRuntimeBootstrap.readObject(markerURL)
            marker["testGeneration"] = 2
            try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
            let after = try InstalledRuntimeMaintenance.inventory(stage)
            XCTAssertThrowsError(try InstalledRuntimeMaintenance.exchange(domain: domain, profile: profile, stage: stage,
                before: before, after: after, fault: { swapped in if swapped == crashAfterSwap { throw Injected() } }))
            XCTAssertEqual(try InstalledRuntimeMaintenance.inventory(profile), crashAfterSwap ? after : before)
            XCTAssertThrowsError(try InstalledRuntimeBootstrap.prepare(domain: domain, application: application, profile: profile))
            try InstalledRuntimeMaintenance.recover(domain: domain, profile: profile)
            try InstalledRuntimeBootstrap.prepare(domain: domain, application: application, profile: profile)
        }
    }
    func testUnknownQueueSchemaDoesNotProduceUsableBackup() async throws {
        let (_, profile) = try setup()
        try await seed("ares", profile: profile)
        let database = profile.appendingPathComponent("ares-state/queue/tasks-v1.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let before = try dataEntries(profile, "ares")
        XCTAssertThrowsError(try InstalledRuntimeMaintenance.backup(domain: "ares", profile: profile))
        XCTAssertEqual(try dataEntries(profile, "ares"), before)
    }

}
