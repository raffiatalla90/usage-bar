// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "UsageBarKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "UsageBar", dependencies: ["UsageBarKit"]),
        .testTarget(name: "UsageBarKitTests", dependencies: ["UsageBarKit"]),
    ]
)
