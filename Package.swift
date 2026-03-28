// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OmniVoice",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "AppCore",
            targets: ["AppCore"]
        ),
        .executable(
            name: "OmniVoice",
            targets: ["OmniVoice"]
        ),
    ],
    targets: [
        .target(
            name: "AppCore"
        ),
        .executableTarget(
            name: "OmniVoice",
            dependencies: ["AppCore"],
            path: "Sources/Playground"
        ),
    ]
)
