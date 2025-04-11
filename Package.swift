// swift-tools-version:6.0

//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import PackageDescription

#if canImport(Darwin)
let appleOS = true
#else
let appleOS = false
#endif

let useLocalDependencies = Context.environment["SWIFTCI_USE_LOCAL_DEPS"] != nil
let useLLBuildFramework = Context.environment["SWIFTBUILD_LLBUILD_FWK"] != nil

func swiftSettings(languageMode: SwiftLanguageMode) -> [SwiftSetting] {
    switch languageMode {
    case .v5:
        return [
            // Upcoming Swift 6.0 features
            .enableUpcomingFeature("ConciseMagicFile"),
            .enableUpcomingFeature("DeprecateApplicationMain"),
            .enableUpcomingFeature("DisableOutwardActorInference"),
            //.enableUpcomingFeature("DynamicActorIsolation"),
            .enableUpcomingFeature("ForwardTrailingClosures"),
            .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
            .enableUpcomingFeature("GlobalConcurrency"),
            .enableUpcomingFeature("ImplicitOpenExistentials"),
            .enableUpcomingFeature("ImportObjcForwardDeclarations"),
            .enableUpcomingFeature("InferSendableFromCaptures"),
            .enableUpcomingFeature("IsolatedDefaultValues"),
            .enableUpcomingFeature("NonfrozenEnumExhaustivity"),
            //.enableUpcomingFeature("RegionBasedIsolation"), // rdar://137809703

            // Future Swift features
            .enableUpcomingFeature("ExistentialAny"),
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("InternalImportsByDefault"),

            .swiftLanguageMode(.v5),

            .define("USE_STATIC_PLUGIN_INITIALIZATION"),
        ]
    case .v6:
        return [
            // Future Swift features
            .enableUpcomingFeature("ExistentialAny"),
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("InternalImportsByDefault"),

            .swiftLanguageMode(.v6),

            .define("USE_STATIC_PLUGIN_INITIALIZATION"),
        ]
    default:
        fatalError("unexpected language mode")
    }
}

let package = Package(
    name: "SwiftBuild",
    defaultLocalization: "en",
    platforms: [.macOS("13.0"), .iOS("17.0"), .macCatalyst("17.0")],
    products: [
        .executable(name: "swbuild", targets: ["swbuild"]),
        .executable(name: "SWBBuildServiceBundle", targets: ["SWBBuildServiceBundle"]),
        .library(name: "SwiftBuild", targets: ["SwiftBuild"]),
        .library(name: "SWBProtocol", targets: ["SWBProtocol"]),
        .library(name: "SWBUtil", targets: ["SWBUtil"]),
        .library(name: "SWBProjectModel", targets: ["SWBProjectModel"]),
        .library(name: "SWBBuildService", targets: ["SWBBuildService"]),
    ],
    targets: [
        // Executables
        .executableTarget(
            name: "swbuild",
            dependencies: [
                "SwiftBuild",
                "SWBBuildServiceBundle", // the CLI needs to launch the service bundle
            ],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .executableTarget(
            name: "SWBBuildServiceBundle",
            dependencies: [
                "SWBBuildService", "SWBBuildSystem", "SWBServiceCore", "SWBUtil", "SWBCore",
            ],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v6)),

        // Libraries
        .target(
            name: "SwiftBuild",
            dependencies: ["SWBCSupport", "SWBCore", "SWBProtocol", "SWBUtil", "SWBProjectModel"],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v5)),
        .target(
            name: "SWBBuildService",
            dependencies: [
                "SWBBuildSystem",
                "SWBServiceCore",
                "SWBTaskExecution",
                .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux, .android, .windows])),
            ],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v5)),
        .target(
            name: "SWBBuildSystem",
            dependencies: ["SWBCore", "SWBTaskConstruction", "SWBTaskExecution"],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v5)),
        .target(
            name: "SWBCore",
            dependencies: [
                "SWBMacro",
                "SWBProtocol",
                "SWBServiceCore",
                "SWBUtil",
                "SWBCAS",
                .product(name: "SwiftDriver", package: "swift-driver"),
                "SWBLLBuild",
            ],
            exclude: ["CMakeLists.txt"],
            resources: [.process("Specs")],
            swiftSettings: swiftSettings(languageMode: .v5)),
        .target(
            name: "SWBCSupport",
            publicHeadersPath: ".",
            cSettings: [
                .define("_CRT_SECURE_NO_WARNINGS", .when(platforms: [.windows])),
                .define("_CRT_NONSTDC_NO_WARNINGS", .when(platforms: [.windows])),
            ],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBCLibc",
            exclude: ["CMakeLists.txt", "README.md"],
            publicHeadersPath: ".",
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBLibc",
            dependencies: ["SWBCLibc"],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBLLBuild",
            dependencies: [
                "SWBUtil"
            ] + (useLLBuildFramework ? [] : [
                .product(name: "libllbuild", package: useLocalDependencies ? "llbuild" : "swift-llbuild"),
                .product(name: "llbuildSwift", package: useLocalDependencies ? "llbuild" : "swift-llbuild"),
            ]),
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBMacro",
            dependencies: [
                "SWBUtil",
                .product(name: "SwiftDriver", package: "swift-driver"),
            ],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBProjectModel",
            dependencies: ["SWBProtocol"],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBProtocol",
            dependencies: ["SWBUtil"],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBServiceCore",
            dependencies: ["SWBProtocol"],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBTaskConstruction",
            dependencies: ["SWBCore", "SWBUtil"],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v5)),
        .target(
            name: "SWBTaskExecution",
            dependencies: ["SWBCore", "SWBUtil", "SWBCAS", "SWBLLBuild", "SWBTaskConstruction"],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v5)),
        .target(
            name: "SWBUtil",
            dependencies: [
                "SWBCSupport",
                "SWBLibc",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "SystemPackage", package: "swift-system", condition: .when(platforms: [.linux, .android, .windows])),
            ],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v5)),
        .target(
            name: "SWBCAS",
            dependencies: ["SWBUtil", "SWBCSupport"],
            exclude: ["CMakeLists.txt"],
            swiftSettings: swiftSettings(languageMode: .v6)),

        .target(
            name: "SWBAndroidPlatform",
            dependencies: ["SWBCore", "SWBMacro", "SWBUtil"],
            exclude: ["CMakeLists.txt"],
            resources: [.process("Specs")],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBApplePlatform",
            dependencies: ["SWBCore", "SWBMacro", "SWBUtil", "SWBTaskConstruction"],
            exclude: ["CMakeLists.txt"],
            resources: [.process("Specs")],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBGenericUnixPlatform",
            dependencies: ["SWBCore", "SWBUtil"],
            exclude: ["CMakeLists.txt"],
            resources: [.process("Specs")],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBQNXPlatform",
            dependencies: ["SWBCore", "SWBMacro", "SWBUtil"],
            exclude: ["CMakeLists.txt"],
            resources: [.process("Specs")],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBUniversalPlatform",
            dependencies: [
                "SWBCore",
                "SWBMacro",
                "SWBUtil",
                "SWBTaskConstruction",
                "SWBTaskExecution",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["CMakeLists.txt"],
            resources: [.process("Specs")],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBWebAssemblyPlatform",
            dependencies: ["SWBCore", "SWBMacro", "SWBUtil"],
            exclude: ["CMakeLists.txt"],
            resources: [.process("Specs")],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBWindowsPlatform",
            dependencies: ["SWBCore", "SWBMacro", "SWBUtil"],
            exclude: ["CMakeLists.txt"],
            resources: [.process("Specs")],
            swiftSettings: swiftSettings(languageMode: .v6)),

        // Test support
        .target(
            name: "SwiftBuildTestSupport",
            dependencies: ["SwiftBuild", "SWBTestSupport", "SWBUtil"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .target(
            name: "SWBTestSupport",
            dependencies: ["SwiftBuild", "SWBBuildSystem", "SWBCore", "SWBTaskConstruction", "SWBTaskExecution", "SWBUtil", "SWBLLBuild", "SWBMacro"],
            swiftSettings: swiftSettings(languageMode: .v5)),

        // Tests
        .testTarget(
            name: "SWBAndroidPlatformTests",
            dependencies: ["SWBAndroidPlatform", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBApplePlatformTests",
            dependencies: ["SWBApplePlatform", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBGenericUnixPlatformTests",
            dependencies: ["SWBGenericUnixPlatform", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBQNXPlatformTests",
            dependencies: ["SWBQNXPlatform", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBUniversalPlatformTests",
            dependencies: ["SWBUniversalPlatform", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBWebAssemblyPlatformTests",
            dependencies: ["SWBWebAssemblyPlatform", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBWindowsPlatformTests",
            dependencies: ["SWBWindowsPlatform", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SwiftBuildTests",
            dependencies: ["SwiftBuild", "SWBBuildService", "SwiftBuildTestSupport"],
            resources: [
                .copy("TestData")
            ],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBProjectModelTests",
            dependencies: ["SWBProjectModel"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBProtocolTests",
            dependencies: ["SWBProtocol", "SWBUtil"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBUtilTests",
            dependencies: ["SWBTestSupport", "SWBUtil"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBCASTests",
            dependencies: ["SWBTestSupport", "SWBCAS", "SWBUtil"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBMacroTests",
            dependencies: ["SWBTestSupport", "SWBMacro"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBServiceCoreTests",
            dependencies: ["SWBServiceCore"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBCoreTests",
            dependencies: ["SWBCore", "SWBTestSupport", "SWBUtil", "SWBLLBuild"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBTaskConstructionTests",
            dependencies: ["SWBTaskConstruction", "SWBCore", "SWBTestSupport", "SWBProtocol", "SWBUtil"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBTaskExecutionTests",
            dependencies: ["SWBTaskExecution", "SWBTestSupport"],
            resources: [
                .copy("TestData")
            ],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBLLBuildTests",
            dependencies: ["SWBLLBuild", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBBuildSystemTests",
            dependencies: ["SWBBuildService", "SWBBuildSystem", "SwiftBuildTestSupport", "SWBTestSupport"],
            resources: [
                .copy("TestData")
            ],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBBuildServiceTests",
            dependencies: ["SwiftBuild", "SWBBuildService", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBTestSupportTests",
            dependencies: ["SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),

        // Perf tests
        .testTarget(
            name: "SWBBuildSystemPerfTests",
            dependencies: ["SWBBuildSystem", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBCASPerfTests",
            dependencies: ["SWBCAS", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBCorePerfTests",
            dependencies: ["SWBCore", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBTaskConstructionPerfTests",
            dependencies: ["SWBTaskConstruction", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SWBUtilPerfTests",
            dependencies: ["SWBUtil", "SWBTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),
        .testTarget(
            name: "SwiftBuildPerfTests",
            dependencies: ["SwiftBuild", "SWBTestSupport", "SwiftBuildTestSupport"],
            swiftSettings: swiftSettings(languageMode: .v6)),

        // Commands
        .plugin(
            name: "launch-xcode",
            capability: .command(intent: .custom(
                verb: "launch-xcode",
                description: "Launch the currently selected Xcode configured to use the just-built build service"
            ))
        ),
        .plugin(
            name: "run-xcodebuild",
            capability: .command(intent: .custom(
                verb: "run-xcodebuild",
                description: "Run xcodebuild from the currently selected Xcode configured to use the just-built build service"
            ))
        ),
        .plugin(
            name: "cmake-smoke-test",
            capability: .command(intent: .custom(
                verb: "cmake-smoke-test",
                description: "Build Swift Build using CMake for validation purposes"
            ))
        )
    ],
    swiftLanguageModes: [.v5, .v6],
    cxxLanguageStandard: .cxx20
)

let pluginTargetNames = [
    "SWBAndroidPlatform",
    "SWBApplePlatform",
    "SWBGenericUnixPlatform",
    "SWBQNXPlatform",
    "SWBUniversalPlatform",
    "SWBWebAssemblyPlatform",
    "SWBWindowsPlatform",
]

for target in package.targets {
    // Add dependencies on "plugins" so they can be loaded in the build service and in tests, as we don't have true plugin targets.
    if ["SWBBuildService", "SWBTestSupport"].contains(target.name) {
        target.dependencies += pluginTargetNames.map { .target(name: $0) }
    }
}

// `SWIFTCI_USE_LOCAL_DEPS` configures if dependencies are locally available to build
if useLocalDependencies {
    package.dependencies += [
        .package(path: "../swift-driver"),
        .package(path: "../swift-system"),
        .package(path: "../swift-argument-parser"),
    ]
    if !useLLBuildFramework {
        package.dependencies +=  [.package(path: "../llbuild"),]
    }
} else {
    package.dependencies += [
        .package(url: "https://github.com/swiftlang/swift-driver.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-system.git", .upToNextMajor(from: "1.4.1")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.3"),
    ]
    if !useLLBuildFramework {
        package.dependencies += [.package(url: "https://github.com/swiftlang/swift-llbuild.git", branch: "main"),]
    }
}
