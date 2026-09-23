// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "McRofone",
    platforms: [.macOS("14.2")],
    targets: [
        .target(
            name: "McRofoneCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "McRofone",
            dependencies: ["McRofoneCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "McRofoneCoreTests",
            dependencies: ["McRofoneCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
