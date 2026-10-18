// swift-tools-version: 5.9
//
// Общие зависимости закрепляются соседним EcosystemKit; Yams 6.2.2 используется
// его адаптером Harness, чтобы не разбирать YAML небезопасным поиском подстрок.
import PackageDescription

let package = Package(
    name: "FileOrganizer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
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
        .target(name: "FileOrganizerCore", dependencies: [
            .product(name: "EcosystemContracts", package: "EcosystemKit"),
            .product(name: "EcosystemLocalIPC", package: "EcosystemKit"),
            .product(name: "EcosystemClientAdapters", package: "EcosystemKit"),
            .product(name: "EcosystemRuntimeSupport", package: "EcosystemKit")
        ]),
        .executableTarget(
            name: "FileOrganizer",
            dependencies: ["FileOrganizerCore", .product(name: "EcosystemUI", package: "EcosystemKit")],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "FileOrganizerMCP",
            dependencies: ["FileOrganizerCore"]
        ),
        .executableTarget(name: "AresRuntime", dependencies: ["FileOrganizerCore"]),
        .executableTarget(name: "AresStoreTool", dependencies: ["FileOrganizerCore"]),
        .executableTarget(name: "FileOrganizerRulesWorker", dependencies: ["FileOrganizerCore"]),
        .testTarget(
            name: "FileOrganizerCoreTests",
            dependencies: ["FileOrganizerCore"]
        )
    ]
)
