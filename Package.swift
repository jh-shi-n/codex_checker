// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexQuotaMonitor",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CodexQuotaMonitorKit",
            targets: ["CodexQuotaMonitorKit"]
        ),
        .executable(
            name: "CodexQuotaMonitor",
            targets: ["CodexQuotaMonitor"]
        ),
    ],
    targets: [
        .target(
            name: "CodexQuotaMonitorKit",
            path: "Sources/CodexQuotaMonitorKit",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "CodexQuotaMonitor",
            dependencies: ["CodexQuotaMonitorKit"],
            path: "Sources/CodexQuotaMonitorApp"
        ),
        .testTarget(
            name: "CodexQuotaMonitorTests",
            dependencies: ["CodexQuotaMonitorKit"],
            path: "Tests/CodexQuotaMonitorTests",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
