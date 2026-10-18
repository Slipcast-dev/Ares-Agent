import AppKit
import Foundation

// Finder хранит пользовательскую иконку в resource fork/FinderInfo. Для pkg
// эти метаданные переносит файловая система внутри DMG, а не GitHub attachment.
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2,
      let image = NSImage(contentsOfFile: arguments[0]), image.isValid,
      NSWorkspace.shared.setIcon(image, forFile: arguments[1], options: []) else {
    fputs("Не удалось установить иконку Finder.\n", stderr)
    exit(1)
}
