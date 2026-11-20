// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwitchKho",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "KhoCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "SwitchKho",
            dependencies: ["KhoCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KhoCoreTests",
            dependencies: ["KhoCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
