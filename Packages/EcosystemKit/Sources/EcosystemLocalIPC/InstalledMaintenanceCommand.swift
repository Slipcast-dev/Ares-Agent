import Darwin
import Foundation

/// Общий CLI обслуживания входит в каждое приложение. Он не зависит от Python,
/// исходников, доступа к другой роли или выбранной модели клиента.
public enum InstalledMaintenanceCommand {
    public static func run(domain: String) -> Int32 {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let usage = "Usage: maintenance uninstall PROFILE --confirm | backup PROFILE | upgrade PROFILE --confirm | rollback PROFILE CHECKPOINT --confirm | recover PROFILE --confirm\nStop this profile's launchd job first; do not interrupt active operations.\n"
            if args == ["--help"] { print(usage); return 0 }
            guard args.count >= 2, args[1].hasPrefix("/"), !args[1].split(separator: "/").contains("..") else {
                fputs(usage, stderr); return 64
            }
            let profile = URL(fileURLWithPath: args[1])
            switch args[0] {
            case "uninstall" where args.count == 3 && args[2] == "--confirm":
                let backup = try InstalledRuntimeMaintenance.prepareUninstall(domain: domain, profile: profile)
                print("Ready to remove this application's .app after quitting its GUI. Profile retained. Backup: " + backup.path)
            case "backup" where args.count == 2:
                print(try InstalledRuntimeMaintenance.backup(domain: domain, profile: profile).path)
            case "upgrade" where args.count == 3 && args[2] == "--confirm":
                let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                guard app.pathExtension == "app" else { fputs(usage, stderr); return 64 }
                print(try InstalledRuntimeMaintenance.upgrade(domain: domain, application: app, profile: profile).path)
            case "rollback" where args.count == 4 && args[3] == "--confirm":
                guard args[2].hasPrefix("/") else { fputs(usage, stderr); return 64 }
                try InstalledRuntimeMaintenance.rollback(domain: domain, profile: profile, checkpoint: URL(fileURLWithPath: args[2]))
                print("rolledBack")
            case "recover" where args.count == 3 && args[2] == "--confirm":
                try InstalledRuntimeMaintenance.recover(domain: domain, profile: profile)
                print("verified")
            default: fputs(usage, stderr); return 64
            }
            return 0
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
            return 78
        }
    }
}
