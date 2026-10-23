// swift-tools-version: 5.9
import PackageDescription

// Foundation-контракты не зависят от UI, БД, MCP SDK и конкретного клиента.
let package = Package(name: "EcosystemKit", defaultLocalization: "en", platforms: [.macOS(.v14)], products: [
    .library(name: "EcosystemLocalization", targets: ["EcosystemLocalization"]),
    .library(name: "EcosystemContracts", targets: ["EcosystemContracts"]),
    .library(name: "EcosystemUI", targets: ["EcosystemUI"]),
    .library(name: "EcosystemRuntimeSupport", targets: ["EcosystemRuntimeSupport"]),
    .library(name: "EcosystemLocalIPC", targets: ["EcosystemLocalIPC"]),
    .library(name: "EcosystemClientAdapters", targets: ["EcosystemClientAdapters"]),
    .executable(name: "EcosystemInstalledProbe", targets: ["EcosystemInstalledProbe"]),
    .executable(name: "EcosystemQueueProbe", targets: ["EcosystemQueueProbe"])
], dependencies: [
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
], targets: [
    .target(name: "EcosystemLocalization", resources: [.process("Resources")]),
    .testTarget(name: "EcosystemLocalizationTests", dependencies: ["EcosystemLocalization"]),
    .target(name: "EcosystemClientAdapters", dependencies: ["EcosystemContracts", "EcosystemLocalization", .product(name: "Yams", package: "Yams")]),
    .testTarget(name: "EcosystemClientAdaptersTests", dependencies: ["EcosystemClientAdapters"]),
    .executableTarget(name: "EcosystemInstalledProbe", dependencies: ["EcosystemLocalIPC"]),
    .target(name: "EcosystemLocalIPC", dependencies: ["EcosystemRuntimeSupport", "EcosystemLocalization"]),
    .testTarget(name: "EcosystemLocalIPCTests", dependencies: ["EcosystemLocalIPC"]),
    .target(name: "EcosystemRuntimeSupport", dependencies: ["EcosystemContracts"],
            linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "EcosystemQueueProbe", dependencies: ["EcosystemRuntimeSupport"]),
    .testTarget(name: "EcosystemRuntimeSupportTests", dependencies: ["EcosystemRuntimeSupport"]),
    .target(name: "EcosystemUI", dependencies: ["EcosystemLocalIPC", "EcosystemLocalization"]),
    .testTarget(name: "EcosystemUITests", dependencies: ["EcosystemUI"]),
    .target(name: "EcosystemContracts", resources: [.copy("Resources")]),
    .testTarget(name: "EcosystemContractsTests", dependencies: ["EcosystemContracts"],
                resources: [.copy("Fixtures")])
])
