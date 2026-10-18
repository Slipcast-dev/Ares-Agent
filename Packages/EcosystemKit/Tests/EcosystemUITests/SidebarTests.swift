import AppKit
import SwiftUI
import XCTest
@testable import EcosystemUI

@MainActor
final class SidebarTests: XCTestCase {
    private let ares = [
        EcosystemSidebarItem(id: "overview", title: "Обзор", symbol: "rectangle.grid.2x2"),
        .init(id: "files", title: "Файлы", symbol: "folder"),
        .init(id: "duplicates", title: "Дубликаты", symbol: "rectangle.on.rectangle"),
        .init(id: "rules", title: "Правила", symbol: "arrow.triangle.branch"),
        .init(id: "history", title: "Задачи и история", symbol: "clock.arrow.circlepath"),
        .init(id: "settings", title: "Настройки", symbol: "gearshape")
    ]
    private let athena = [
        EcosystemSidebarItem(id: "dashboard", title: "Обзор", symbol: "square.grid.2x2"),
        .init(id: "diagnostics", title: "Диагностика", symbol: "stethoscope"),
        .init(id: "storage", title: "Накопитель", symbol: "internaldrive"),
        .init(id: "settings", title: "Настройки", symbol: "gearshape")
    ]

    func testSharedNavigationKeepsBoundariesAndEmptyLists() {
        XCTAssertNil(EcosystemSidebar.destination(in: [], from: nil, direction: .down))
        XCTAssertEqual(EcosystemSidebar.destination(in: ["a", "b"], from: "a", direction: .up), "a")
        XCTAssertEqual(EcosystemSidebar.destination(in: ["a", "b"], from: "b", direction: .down), "b")
        XCTAssertNil(EcosystemSidebar.destination(in: ["a"], from: "a", direction: .left))
    }

    func testBothAgentsRenderAllSelectionsInBothThemes() async throws {
        for (brand, items) in [("Ares", ares), ("Athena", athena)] {
            for item in items {
                for theme in [ColorScheme.light, .dark] {
                    for width in [CGFloat(200), 280] {
                        let root = EcosystemSidebar(title: brand, items: items, selection: .constant(item.id))
                            .environment(\.colorScheme, theme).environment(\.controlActiveState, .active)
                            .frame(width: width, height: 400)
                        let host = NSHostingView(rootView: root)
                        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
                        let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
                        window.contentView = host
                        defer { window.close() }
                        // List материализует строки только после включения в окно.
                        try await Task.sleep(for: .milliseconds(60))
                        host.layoutSubtreeIfNeeded()
                        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
                        XCTAssertGreaterThanOrEqual(table.numberOfRows, items.count)
                        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        var blue = 0
                        var total = 0
                        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                                total += 1
                                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                                   color.blueComponent > 0.7, color.blueComponent - color.redComponent > 0.4,
                                   color.blueComponent - color.greenComponent > 0.2, color.greenComponent > 0.15 {
                                    blue += 1
                                }
                            }
                        }
                        // Наличие PNG не доказывает видимость: проверяем площадь
                        // выделенной строки, а не только тонких синих значков.
                        XCTAssertGreaterThan(Double(blue) / Double(total), 0.03)
                        if let output = ProcessInfo.processInfo.environment["ECOSYSTEM_UI_SNAPSHOTS_DIR"],
                           width == 280, item.id == items.first?.id {
                            try save(bitmap, appearance: window.effectiveAppearance,
                                     path: URL(fileURLWithPath: output, isDirectory: true)
                                        .appendingPathComponent("E2-\(brand.lowercased())-\(theme == .light ? "light" : "dark").png"))
                        }
                    }
                }
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func save(_ bitmap: NSBitmapImageRep, appearance: NSAppearance, path: URL) throws {
        // Матовый фон сохраняет читаемость текста в любом просмотрщике PNG.
        let output = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: output))
        let rect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        appearance.performAsCurrentDrawingAppearance {
            graphics.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
            graphics.cgContext.fill(rect)
        }
        graphics.cgContext.draw(try XCTUnwrap(bitmap.cgImage), in: rect)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(output.representation(using: .png, properties: [:])).write(to: path)
    }
}
