// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PlatformFilterRepro",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
    products: [
        .library(name: "App", targets: ["App"]),
    ],
    targets: [
        .target(
            name: "App",
            dependencies: [
                // Multi-platform conditions produce Set<PlatformFilter> with >1 element.
                // Set iteration order varies per-process due to hash seed randomization.
                .target(name: "PlatformSpecific", condition: .when(platforms: [.iOS, .macOS, .tvOS, .watchOS, .visionOS])),
                .target(name: "Common"),
            ]
        ),
        .target(
            name: "PlatformSpecific",
            dependencies: [
                .target(name: "Common", condition: .when(platforms: [.iOS, .macOS, .tvOS])),
            ]
        ),
        .target(name: "Common"),
    ]
)
