import Darwin
import Foundation
import FileOrganizerCore

/// Offline validator работает только с явной копией. Не знает пути исходной
/// пользовательской БД, не открывает bookmarks и не исполняет правила.
@main struct AresStoreTool {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 2, args[0] == "--validate-copy", args[1].hasPrefix("/") else { exit(64) }
            let file = URL(fileURLWithPath: args[1])
            // Валидатор может изменять схему, поэтому принимает только приватную
            // копию с marker того же inode/device, созданным prepare. Ошибочный
            // путь к исходной БД без marker отклоняется до первого SQLite open.
            var info = stat(), markerInfo = stat(), parentInfo = stat()
            let marker = file.deletingLastPathComponent().appendingPathComponent("copy-marker.json")
            guard file.lastPathComponent == "candidate.sqlite", lstat(file.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
                  lstat(marker.path, &markerInfo) == 0, markerInfo.st_mode & S_IFMT == S_IFREG,
                  markerInfo.st_uid == geteuid(), markerInfo.st_nlink == 1, markerInfo.st_mode & 0o077 == 0,
                  markerInfo.st_size > 0, markerInfo.st_size < 4096,
                  lstat(file.deletingLastPathComponent().path, &parentInfo) == 0,
                  parentInfo.st_mode & S_IFMT == S_IFDIR, parentInfo.st_uid == geteuid(), parentInfo.st_mode & 0o077 == 0,
                  let value = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: NSNumber],
                  value["version"]?.intValue == 1, value["inode"]?.uint64Value == UInt64(info.st_ino),
                  value["device"]?.uint64Value == UInt64(info.st_dev) else { exit(64) }
            let container = AppContainer(databaseURL: file, allowLocalClient: false)
            try container.preparePersistentStore()
            let roots = try await container.fileRepository.fetchRoots()
            let rules = try await container.fileRepository.ruleObjects(AutomationRule.self, table: .rules)
            _ = try await container.fileRepository.ruleObjects(RuleObservation.self, table: .observations)
            _ = try await container.fileRepository.ruleObjects(RuleRun.self, table: .runs)
            _ = try await container.fileRepository.ruleObjects(String.self, table: .receipts)
            // Декодируем каждую строку правил, чтобы невозможный JSON не был
            // обнаружен только после включения runtime.
            let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": try container.migrations.appliedVersion(), "roots": roots.count, "rules": rules.count])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        } catch { fputs("STORE_COPY_VALIDATION_FAILED\n", stderr); exit(65) }
    }
}
