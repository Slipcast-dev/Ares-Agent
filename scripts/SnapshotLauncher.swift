import AppKit
import Foundation

// Launcher принадлежит app bundle, но не запускает Python с правами установщика.
// Частный профиль создаёт обычный пользователь после явного открытия приложения.
let script = Bundle.main.resourceURL!.appendingPathComponent("snapshot_entry.py")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
process.arguments = [script.path, "launch"]
do {
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        NSApplication.shared.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "Локальный агент не запущен"
        alert.informativeText = "Проверьте наличие Python 3 и документацию комплекта. Перед обновлением остановите профиль командой snapshot_entry.py stop. Системные разрешения выдаются вручную."
        alert.runModal()
        exit(process.terminationStatus)
    }
} catch {
    NSApplication.shared.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.messageText = "Не удалось запустить Python 3"
    alert.informativeText = "Для промежуточной сборки нужен /usr/bin/python3. Установите Python/Command Line Tools штатным способом."
    alert.runModal()
    exit(1)
}
