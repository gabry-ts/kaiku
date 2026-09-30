// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Kaiku",
    platforms: [.macOS("14.2")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
        .package(url: "https://github.com/gabry-ts/partiti-ui", from: "0.3.0"),
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
                .product(name: "PartitiUI", package: "partiti-ui"),
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
