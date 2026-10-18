// swift-tools-version: 5.9
import PackageDescription

// Foundation-контракты не зависят от UI, БД, MCP SDK и конкретного клиента.
let package = Package(name: "EcosystemKit", platforms: [.macOS(.v14)], products: [
    .library(name: "EcosystemContracts", targets: ["EcosystemContracts"]),
    .library(name: "EcosystemUI", targets: ["EcosystemUI"]),
    .library(name: "EcosystemRuntimeSupport", targets: ["EcosystemRuntimeSupport"]),
    .library(name: "EcosystemLocalIPC", targets: ["EcosystemLocalIPC"]),
    .library(name: "EcosystemClientAdapters", targets: ["EcosystemClientAdapters"]),
    .executable(name: "EcosystemQueueProbe", targets: ["EcosystemQueueProbe"])
], dependencies: [
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
], targets: [
    .target(name: "EcosystemClientAdapters", dependencies: [.product(name: "Yams", package: "Yams")]),
    .testTarget(name: "EcosystemClientAdaptersTests", dependencies: ["EcosystemClientAdapters"]),
    .target(name: "EcosystemLocalIPC", dependencies: ["EcosystemRuntimeSupport"]),
    .testTarget(name: "EcosystemLocalIPCTests", dependencies: ["EcosystemLocalIPC"]),
    .target(name: "EcosystemRuntimeSupport", dependencies: ["EcosystemContracts"],
            linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "EcosystemQueueProbe", dependencies: ["EcosystemRuntimeSupport"]),
    .testTarget(name: "EcosystemRuntimeSupportTests", dependencies: ["EcosystemRuntimeSupport"]),
    .target(name: "EcosystemUI", dependencies: ["EcosystemLocalIPC"]),
    .testTarget(name: "EcosystemUITests", dependencies: ["EcosystemUI"]),
    .target(name: "EcosystemContracts", resources: [.copy("Resources")]),
    .testTarget(name: "EcosystemContractsTests", dependencies: ["EcosystemContracts"],
                resources: [.copy("Fixtures")])
])
