// swift-tools-version: 5.9
//
// Общие зависимости закрепляются соседним EcosystemKit; Yams 6.2.2 используется
// его адаптером Harness, чтобы не разбирать YAML небезопасным поиском подстрок.
import PackageDescription

let package = Package(
    name: "FileOrganizer",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AresMaintenance", targets: ["AresMaintenance"]),
        .library(name: "FileOrganizerCore", targets: ["FileOrganizerCore"]),
        .executable(name: "FileOrganizer", targets: ["FileOrganizer"]),
        // MCP вынесен в отдельный процесс, чтобы будущий внешний клиент не
        // разделял память и жизненный цикл с графическим приложением.
        .executable(name: "FileOrganizerMCP", targets: ["FileOrganizerMCP"]),
        .executable(name: "FileOrganizerRulesWorker", targets: ["FileOrganizerRulesWorker"]),
        .executable(name: "AresRuntime", targets: ["AresRuntime"]),
        .executable(name: "AresStoreTool", targets: ["AresStoreTool"])
    ],
    // Общий пакет версионируется в соседнем репозитории Athena.
    dependencies: [.package(path: "Packages/EcosystemKit")],
    targets: [
        .executableTarget(name: "AresMaintenance", dependencies: [.product(name: "EcosystemLocalIPC", package: "EcosystemKit")]),
        .target(name: "FileOrganizerCore", dependencies: [
            .product(name: "EcosystemLocalization", package: "EcosystemKit"),
            .product(name: "EcosystemContracts", package: "EcosystemKit"),
            .product(name: "EcosystemLocalIPC", package: "EcosystemKit"),
            .product(name: "EcosystemClientAdapters", package: "EcosystemKit"),
            .product(name: "EcosystemRuntimeSupport", package: "EcosystemKit")
        ]),
        .executableTarget(
            name: "FileOrganizer",
            dependencies: ["FileOrganizerCore", .product(name: "EcosystemUI", package: "EcosystemKit"), .product(name: "EcosystemLocalization", package: "EcosystemKit")],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "FileOrganizerMCP",
            dependencies: ["FileOrganizerCore", .product(name: "EcosystemLocalization", package: "EcosystemKit")]
        ),
        .executableTarget(name: "AresRuntime", dependencies: [.product(name: "EcosystemLocalization", package: "EcosystemKit"), "FileOrganizerCore"]),
        .executableTarget(name: "AresStoreTool", dependencies: ["FileOrganizerCore", .product(name: "EcosystemLocalization", package: "EcosystemKit")]),
        .executableTarget(name: "FileOrganizerRulesWorker", dependencies: ["FileOrganizerCore", .product(name: "EcosystemLocalization", package: "EcosystemKit")]),
        .testTarget(name: "FileOrganizerUITests", dependencies: ["FileOrganizer"]),
        .testTarget(
            name: "FileOrganizerCoreTests",
            dependencies: ["FileOrganizerCore", .product(name: "EcosystemLocalization", package: "EcosystemKit")]
        )
    ]
)
