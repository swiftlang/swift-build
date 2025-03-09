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

import Testing

import SWBUtil
import enum SWBProtocol.ExternalToolResult
import SWBCore
import SWBTaskConstruction
import SWBTestSupport

@Suite
fileprivate struct SignatureCollectionTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func basicSignatureCollection() async throws {

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("File.c"),
                    TestFile("Object.o"),
                    TestFile("Framework.framework"),
                    TestFile("libAnotherStatic.a"),
                    TestFile("Goodies.xcframework"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "ARCHS": "x86_64",
                    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator macosx",
                    "SUPPORTS_MACCATALYST": "YES",
                    "LIBTOOL": libtoolPath.str,
                ]),
            ],
            targets: [
                // Test building a tool target which links a static library.
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["File.c"]),
                        TestFrameworksBuildPhase(["libStaticLib1.a", "Goodies.xcframework"]),
                    ],
                    dependencies: ["StaticLib1"]
                ),
                // Test building a static library from several components.
                TestStandardTarget(
                    "StaticLib1",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["File.c"]),
                        TestFrameworksBuildPhase([
                            "Object.o",
                            TestBuildFile(.auto("libStaticLib2.a"), shouldLinkWeakly: true),
                            TestBuildFile(.auto("libAnotherStatic.a"), shouldLinkWeakly: false),
                            TestBuildFile("Framework.framework", shouldLinkWeakly: true),
                            TestBuildFile("Goodies.xcframework"),
                        ]),
                    ],
                    dependencies: ["StaticLib2"]

                ),
                TestStandardTarget(
                    "StaticLib2",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["File.c"]),
                        TestFrameworksBuildPhase([
                            // Link the same framework another library links...
                            TestBuildFile("Framework.framework", shouldLinkWeakly: true),
                        ]),
                    ]
                ),
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        try fs.createDirectory(Path(SRCROOT), recursive: true)
        try fs.write(Path(SRCROOT).join("file.c"), contents: "int f() { return 0; }")

        let goodiesXCFramework = try XCFramework(version: Version(1, 0), libraries: [
            XCFramework.Library(libraryIdentifier: "x86_64-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", supportedPlatform: "macos", supportedArchitectures: ["x86_64"], platformVariant: nil, libraryPath: Path("Goodies.framework"), binaryPath: Path("Goodies.framework/Versions/A/Goodies"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "arm64-apple-iphoneos\(core.loadSDK(.iOS).defaultDeploymentTarget)", supportedPlatform: "ios", supportedArchitectures: ["arm64", "arm64e"], platformVariant: nil, libraryPath: Path("Goodies.framework"), binaryPath: Path("Goodies.framework/Goodies"), headersPath: nil),
            XCFramework.Library(libraryIdentifier: "x86_64-apple-ios\(core.loadSDK(.iOS).defaultDeploymentTarget)-maccatalyst", supportedPlatform: "ios", supportedArchitectures: ["x86_64"], platformVariant: "macabi", libraryPath: Path("Goodies.framework"), binaryPath: Path("Goodies.framework/Goodies"), headersPath: nil),
        ])
        let goodiesXCFrameworkPath = Path(SRCROOT).join("Goodies.xcframework")
        try fs.createDirectory(goodiesXCFrameworkPath, recursive: true)
        let infoLookup = try await getCore()
        try await XCFrameworkTestSupport.writeXCFramework(goodiesXCFramework, fs: fs, path: goodiesXCFrameworkPath, infoLookup: infoLookup)

        try await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ENABLE_SIGNATURE_AGGREGATION": "YES"]), runDestination: .macOS, fs: fs) { results in
            // NOTE: The signature collection pulls out the framework signature information **NOT** the xcframework signature info.
            try results.checkTask(.matchRuleType("SignatureCollection"), .matchRuleItemPattern(.contains("Goodies.xcframework"))) { task in
                task.checkInputs(contain: [.pathPattern(.suffix("Goodies.xcframework"))])
                task.checkCommandLineContains(["--info", "platform", "macos"])
                task.checkCommandLineContains(["--info", "library", "Goodies.framework"])
                task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug/Goodies.xcframework-macos.signature")])
                try task.checkTaskAction(toolIdentifier: "signature-collection")
            }

            results.checkTarget("Tool") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("SignatureCollection"))
            }

            results.checkTarget("StaticLib1") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("SignatureCollection"))
            }

            results.checkTarget("StaticLib2") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("SignatureCollection"))
            }

            // Check that there are warnings about trying to weak-link libraries.
            results.checkWarning("Product libStaticLib1.a cannot weak-link static library libStaticLib2.a (in target 'StaticLib1' from project 'aProject')")
            results.checkWarning("Product libStaticLib1.a cannot weak-link framework Framework.framework (in target 'StaticLib1' from project 'aProject')")
            results.checkWarning("Product libStaticLib2.a cannot weak-link framework Framework.framework (in target 'StaticLib2' from project 'aProject')")

            // Check that there are no other diagnostics.
            results.checkNoDiagnostics()
        }

        try await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ENABLE_SIGNATURE_AGGREGATION": "YES"]), runDestination: .macCatalyst, fs: fs) { results in
            // NOTE: The signature collection pulls out the framework signature information **NOT** the xcframework signature info.
            try results.checkTask(.matchRuleType("SignatureCollection"), .matchRuleItemPattern(.contains("Goodies.xcframework"))) { task in
                task.checkInputs(contain: [.pathPattern(.suffix("Goodies.xcframework"))])
                task.checkCommandLineContains(["--info", "platform", "ios"])
                task.checkCommandLineContains(["--info", "library", "Goodies.framework"])
                task.checkCommandLineContains(["--info", "platformVariant", "macabi"])
                task.checkOutputs(contain: [.path("\(SRCROOT)/build/Debug-maccatalyst/Goodies.xcframework-ios-macabi.signature")])
                try task.checkTaskAction(toolIdentifier: "signature-collection")
            }

            results.checkTarget("Tool") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("SignatureCollection"))
            }

            results.checkTarget("StaticLib1") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("SignatureCollection"))
            }

            results.checkTarget("StaticLib2") { target in
                results.checkNoTask(.matchTarget(target), .matchRuleType("SignatureCollection"))
            }

            // Check that there are warnings about trying to weak-link libraries.
            results.checkWarning("Product libStaticLib1.a cannot weak-link static library libStaticLib2.a (in target 'StaticLib1' from project 'aProject')")
            results.checkWarning("Product libStaticLib1.a cannot weak-link framework Framework.framework (in target 'StaticLib1' from project 'aProject')")
            results.checkWarning("Product libStaticLib2.a cannot weak-link framework Framework.framework (in target 'StaticLib2' from project 'aProject')")

            // Check that there are no other diagnostics.
            results.checkNoDiagnostics()
        }
    }
}
