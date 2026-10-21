import Darwin
import Foundation
import EcosystemLocalIPC

// Диагностический продукт используется только в изолированных smoke-профилях.
// Полномочий GUI он не получает: реальные listener проверяют собственный CDHash.
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["home"] {
        print(FileManager.default.homeDirectoryForCurrentUser.path)
    } else if arguments.count == 3, ["backup", "recover", "fixture-login"].contains(arguments[0]) {
        let profile = URL(fileURLWithPath: arguments[2])
        if arguments[0] == "fixture-login" {
            // Только интеграционный home под private/tmp: не выдаёт согласие
            // настоящему профилю и не доступно в упакованных пользовательских CLI.
            // Foundation может сокращать /private/tmp до /tmp даже после
            // resolvingSymlinksInPath. Проверяем POSIX realpath, как bootstrap.
            guard let pointer = realpath(FileManager.default.homeDirectoryForCurrentUser.path, nil) else { exit(64) }
            let home = String(cString: pointer); free(pointer)
            guard home.hasPrefix("/private/tmp/ecosystem-standalone-"),
                  profile.path.hasPrefix(home + "/Library/Application Support/") else { exit(64) }
            _ = try LocalLoginRegistration(profile: profile, domain: arguments[1]).setEnabled(true)
            print("fixture-login-configured")
        } else if arguments[0] == "backup" {
            print(try InstalledRuntimeMaintenance.backup(domain: arguments[1], profile: profile).path)
        } else {
            try InstalledRuntimeMaintenance.recover(domain: arguments[1], profile: profile)
            print("verified")
        }
    } else if arguments.count == 4, arguments[0] == "rollback" {
        try InstalledRuntimeMaintenance.rollback(domain: arguments[1], profile: URL(fileURLWithPath: arguments[2]), checkpoint: URL(fileURLWithPath: arguments[3]))
        print("rolledBack")
    } else if arguments.count == 4, ["prepare", "start", "upgrade"].contains(arguments[0]) {
        let profile = URL(fileURLWithPath: arguments[3])
        if arguments[0] == "prepare" {
            print(try InstalledRuntimeBootstrap.prepare(domain: arguments[1], application: URL(fileURLWithPath: arguments[2]), profile: profile).path)
        } else if arguments[0] == "upgrade" {
            print(try InstalledRuntimeMaintenance.upgrade(domain: arguments[1], application: URL(fileURLWithPath: arguments[2]), profile: profile).path)
        } else {
            try InstalledRuntimeBootstrap.start(domain: arguments[1], profile: profile)
            print("registered")
        }
    } else { exit(64) }
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(78)
}
