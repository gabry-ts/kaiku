// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Kaiku",
    platforms: [.macOS("14.2")],
    targets: [
        .target(
            name: "KaikuCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Kaiku",
            dependencies: ["KaikuCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KaikuCoreTests",
            dependencies: ["KaikuCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
