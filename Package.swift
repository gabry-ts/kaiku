// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Kaiku",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "KaikuCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Kaiku",
            dependencies: [
                "KaikuCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KaikuCoreTests",
            dependencies: ["KaikuCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
