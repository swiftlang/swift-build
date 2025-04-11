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

@_spi(Testing) import SWBUtil
import SWBTestSupport

import SWBCore
@_spi(Testing) import SWBTaskConstruction
import SWBProtocol

@Suite
fileprivate struct ObjectiveCSymbolExtractorTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func skipsDocumentationWhenTargetHasPlusPlusHeader() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            try await checkBuildWithPlusPlusHeader(targetType: .framework, withHeaderBuildPhase: true, plusPlusHeaderVisibility: .public, shouldSkip: true) // Public headers are processed for all target types
            try await checkBuildWithPlusPlusHeader(targetType: .application, withHeaderBuildPhase: true, plusPlusHeaderVisibility: .public, shouldSkip: true)
            try await checkBuildWithPlusPlusHeader(targetType: .framework, withHeaderBuildPhase: true, plusPlusHeaderVisibility: .private, shouldSkip: false) // Private headers aren't processed for frameworks
            try await checkBuildWithPlusPlusHeader(targetType: .application, withHeaderBuildPhase: true, plusPlusHeaderVisibility: .private, shouldSkip: true) // Private headers are processed for applications
            try await checkBuildWithPlusPlusHeader(targetType: .framework, withHeaderBuildPhase: true, plusPlusHeaderVisibility: .private, extraBuildSettings: ["DOCC_EXTRACT_SPI_DOCUMENTATION": "YES"], shouldSkip: true) // The private plus plus header is now configured to be processed.
            try await checkBuildWithPlusPlusHeader(targetType: .application, withHeaderBuildPhase: false, plusPlusHeaderVisibility: .private, shouldSkip: true) // Private headers are processed for applications
        }
    }

    private func checkBuildWithPlusPlusHeader(
        targetType: TestStandardTarget.TargetType,
        withHeaderBuildPhase: Bool,
        plusPlusHeaderVisibility: TestBuildFile.HeaderVisibility,
        extraBuildSettings: [String: String] = [:],
        shouldSkip: Bool
    ) async throws {
        let core = try await getCore()
        let clangFeatures = try await self.clangFeatures

        for withPlusPlusFile in [false, true] {
            var headerBuildPhaseFiles = [
                TestBuildFile("ObjCHeaderFilePublic.h", headerVisibility: .public),
            ]
            if withPlusPlusFile {
                headerBuildPhaseFiles.append(
                    TestBuildFile("ObjCXXHeaderFilePublic.hpp", headerVisibility: plusPlusHeaderVisibility)
                )
            }

            var buildPhases: [any TestBuildPhase] = [
                TestSourcesBuildPhase([
                    TestBuildFile("ObjCXXSourceFile.cpp")
                ])
            ]
            if withHeaderBuildPhase {
                buildPhases.insert(TestHeadersBuildPhase(headerBuildPhaseFiles), at: 0)
            }

            let toolchainPath = core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain")
            let testProject = try await TestProject(
                "aProject",
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Info.plist"),
                        TestFile("ObjCHeaderFilePublic.h"),
                        TestFile("ObjCXXHeaderFilePublic.hpp"),
                        TestFile("ObjCXXSourceFile.cpp"),
                    ]
                ),

                targets: [
                    TestStandardTarget(
                        "Framework",
                        type: targetType,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "ARCHS": "x86_64 arm64",
                                    "ONLY_ACTIVE_ARCH": "NO",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    "SWIFT_VERSION": "5.0",
                                    // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                    "TAPI_EXEC": tapiToolPath.str,
                                    "DOCC_EXEC": doccToolPath.str,
                                    "INFOPLIST_FILE":"SomeFiles/Info.plist",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.identifier",
                                    "CURRENT_PROJECT_VERSION": "0.0.1",
                                    "TOOLCHAIN_DIR": toolchainPath.str,
                                    "CLANG_CXX_LANGUAGE_STANDARD": "c++23",
                                    "OTHER_CPLUSPLUSFLAGS": "-fchar8_t",
                                ].merging(extraBuildSettings, uniquingKeysWith: { _, new in new }).compactMapValues({ $0 })
                            )
                        ],
                        buildPhases: buildPhases
                    )
                ]
            )

            let tester = try TaskConstructionTester(core, testProject)

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()

            // Create a fake clang executable in the pseudo file system, so ClangCompilerSpec can
            // find and parse the actual clang's features.json from the real file system.
            let clangFolder = Path(SRCROOT).join(toolchainPath).join("usr/bin")
            try fs.createDirectory(clangFolder, recursive: true)
            try fs.write(clangFolder.join("clang"), contents: "This is not a real compiler")

            let folder = Path(SRCROOT).join("SomeFiles")
            try fs.createDirectory(folder, recursive: true)

            try fs.write(folder.join("ObjCSourceFilePublic.h"), contents: "/* Some Objective-C content */\n")
            if withPlusPlusFile {
                try fs.write(folder.join("ObjCXXSourceFilePublic.h"), contents: "/* Some Objective-C++ content */\n")
            }
            try fs.write(folder.join("Info.plist"), contents: "Test")

            await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
                results.checkNoDiagnostics()

                results.checkTarget("Framework") { target in

                    // Does this build support extract-api for C++?
                    // - Clang supports C++ extract-api
                    // - AND the IDEDocumentationEnableClangExtractAPI feature flag is enabled.
                    let supportsPlusPlus = clangFeatures.has(.extractAPISupportsCPlusPlus) && SWBFeatureFlag.enableClangExtractAPI.value

                    // Should this build skip the extract-api task? It should if:
                    // - shouldSkip is not false (this build is not using private C++ headers from a framework)
                    // - AND clang does not support extract-api for C++
                    // - AND there is a C++ header file OR there is no header build phase
                    if shouldSkip && !supportsPlusPlus && (withPlusPlusFile || !withHeaderBuildPhase) {

                        // Check the extract-api related tasks are not generated:

                        results.checkNoTask(.matchTarget(target), .matchRuleItem("ExtractAPI"))
                        results.checkNoTask(.matchTarget(target), .matchRuleItem("ConvertSDKDBToSymbolGraph"))
                        // Since no symbol information is extracted no documentation should be built.
                        results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
                    } else {

                        // Check the extract-api related tasks are generated:

                        for arch in ["x86_64", "arm64"] {
                            let sdkdbFile = "/tmp/Test/aProject/build/aProject.build/Debug/Framework.build/symbol-graph/clang/\(arch)-apple-macos\(core.loadSDK(.macOS).version)/Framework.sdkdb"
                            let symbolGraphFile = "/tmp/Test/aProject/build/aProject.build/Debug/Framework.build/symbol-graph/clang/\(arch)-apple-macos\(core.loadSDK(.macOS).version)/Framework.symbols.json"

                            results.checkTask(
                                .matchTarget(target),
                                .matchRule([ "ExtractAPI", SWBFeatureFlag.enableClangExtractAPI.value ? symbolGraphFile : sdkdbFile ])
                            ) { task in
                                // For testing clang extract-api, also check the proper
                                // -x command line option is passed to clang
                                if SWBFeatureFlag.enableClangExtractAPI.value {
                                    if shouldSkip && (withPlusPlusFile || !withHeaderBuildPhase) {
                                        task.checkCommandLineContainsUninterrupted(["-x", "objective-c++-header"])
                                        task.checkCommandLineContains(["-std=c++23", "-fchar8_t"])
                                    } else {
                                        task.checkCommandLineContainsUninterrupted(["-x", "objective-c-header"])
                                    }
                                }
                            }

                            if !SWBFeatureFlag.enableClangExtractAPI.value {
                                results.checkTaskExists(.matchTarget(target), .matchRule(["ConvertSDKDBToSymbolGraph", sdkdbFile]))
                            }
                        }

                        // Since symbol information is extracted, there should also be a documentation built task.
                        results.checkTaskExists(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func documentationWithoutHeaderMembership() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            // Apps and other executables include all headers that are siblings to their source files in their documentation builds
            try await checkBuildWithoutHeaderMembership(targetType: .application, withSourcesBuildFiles: true, shouldSkip: false)
            try await checkBuildWithoutHeaderMembership(targetType: .commandLineTool, withSourcesBuildFiles: true, shouldSkip: false)

            // ... but other types of target's don't
            try await checkBuildWithoutHeaderMembership(targetType: .framework, withSourcesBuildFiles: true, shouldSkip: true)
            try await checkBuildWithoutHeaderMembership(targetType: .unitTest, withSourcesBuildFiles: true, shouldSkip: true)
            try await checkBuildWithoutHeaderMembership(targetType: .staticLibrary, withSourcesBuildFiles: true, shouldSkip: true)

            // When the executable has no source files, it finds no headers to extract symbol information from
            try await checkBuildWithoutHeaderMembership(targetType: .application, withSourcesBuildFiles: false, shouldSkip: true)
            try await checkBuildWithoutHeaderMembership(targetType: .commandLineTool, withSourcesBuildFiles: false, shouldSkip: true)
        }
    }

    private func checkBuildWithoutHeaderMembership(
        targetType: TestStandardTarget.TargetType,
        withSourcesBuildFiles: Bool,
        extraBuildSettings: [String: String] = [:],
        shouldSkip: Bool
    ) async throws {
        let core = try await getCore()

        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Info.plist"),
                    TestFile("ObjCHeaderFilePublic.h"),
                    TestFile("ObjCHeaderFilePublic.m"),
                ]
            ),

            targets: [
                TestStandardTarget(
                    "Framework",
                    type: targetType,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "ARCHS": "x86_64 arm64",
                                "ONLY_ACTIVE_ARCH": "NO",
                                "SWIFT_EXEC": swiftCompilerPath.str,
                                "SWIFT_VERSION": "5.0",
                                // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                "TAPI_EXEC": tapiToolPath.str,
                                "DOCC_EXEC": doccToolPath.str,
                                "LIBTOOL": libtoolPath.str,
                                "INFOPLIST_FILE":"SomeFiles/Info.plist",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.identifier",
                                "CURRENT_PROJECT_VERSION": "0.0.1",
                                "TOOLCHAIN_DIR": core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain").str,
                            ].merging(extraBuildSettings, uniquingKeysWith: { _, new in new }).compactMapValues({ $0 })
                        )
                    ],
                    buildPhases: [
                        // No header build phase
                        TestSourcesBuildPhase(withSourcesBuildFiles ? ["ObjCHeaderFilePublic.m"] : [])
                    ]
                )
            ]
        )

        let tester = try TaskConstructionTester(core, testProject)

        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()
        let folder = Path(SRCROOT).join("SomeFiles")
        try fs.createDirectory(folder, recursive: true)

        try fs.write(folder.join("ObjCSourceFilePublic.h"), contents: "/* Some Objective-C header content */\n")
        try fs.write(folder.join("ObjCSourceFilePublic.m"), contents: "/* Some Objective-C source content */\n")

        try fs.write(folder.join("Info.plist"), contents: "Test")

        await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, fs: fs) { results in
            results.checkNoDiagnostics()

            results.checkTarget("Framework") { target in
                if shouldSkip {
                    // Since there target has a C++ header, no symbol information should be extracted
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("ExtractAPI"))
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("ConvertSDKDBToSymbolGraph"))
                    // Since no symbol information is extracted and the target doesn't have a DocC catalog or Swift code, no documentation should be built.
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
                } else {
                    for arch in ["x86_64", "arm64"] {
                        let sdkdbFile = "/tmp/Test/aProject/build/aProject.build/Debug/Framework.build/symbol-graph/clang/\(arch)-apple-macos\(core.loadSDK(.macOS).version)/Framework.sdkdb"
                        let symbolGraphFile = "/tmp/Test/aProject/build/aProject.build/Debug/Framework.build/symbol-graph/clang/\(arch)-apple-macos\(core.loadSDK(.macOS).version)/Framework.symbols.json"

                        results.checkTaskExists(
                            .matchTarget(target),
                            .matchRule([
                                "ExtractAPI",
                                SWBFeatureFlag.enableClangExtractAPI.value ? symbolGraphFile : sdkdbFile
                            ])
                        )

                        if !SWBFeatureFlag.enableClangExtractAPI.value {
                            results.checkTaskExists(.matchTarget(target), .matchRule(["ConvertSDKDBToSymbolGraph", sdkdbFile]))
                        }
                    }
                    // Since symbol information is extracted, there should also be a documentation built task.
                    results.checkTaskExists(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS, .macOS))
    func objectiveCAppDocumentationHeaderHeuristic() async throws {
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            let core = try await getCore()

            let testProject = try await TestProject(
                "aProject",
                // This is meant to represent a small but well organized cross platform app target
                groupTree:
                    TestGroup("Project", children: [
                        TestGroup("iOS", children: [
                            TestGroup("Feature 1", children: [
                                TestFile("FeatureOneExtraInterfaceFile.h", guid: "FR_iOS_FeatureOneExtraInterfaceFile.h"),
                                TestFile("FeatureOneSomething.h", guid: "FR_iOS_FeatureOneSomething.h"),
                                TestFile("FeatureOneSomething.m", guid: "FR_iOS_FeatureOneSomething.m"),
                            ]),
                            TestGroup("Feature 2", children: [
                                TestFile("FeatureTwoViewController.h", guid: "FR_iOS_FeatureTwoViewController.h"),
                                TestFile("FeatureTwoViewController_Private.h", guid: "FR_iOS_FeatureTwoViewController_Private.h"),
                                TestFile("FeatureTwoViewController.m", guid: "FR_iOS_FeatureTwoViewController.m"),
                            ]),
                            TestGroup("Feature 3", children: [
                                TestFile("FeatureThreeSomething.h", guid: "FR_iOS_FeatureThreeSomething.h"),
                                TestFile("FeatureThreeSomething.m", guid: "FR_iOS_FeatureThreeSomething.m"),
                                TestFile("FeatureThreeSomething+Other.h", guid: "FR_iOS_FeatureThreeSomething+Other.h"),
                                TestFile("FeatureThreeSomething+Other.m", guid: "FR_iOS_FeatureThreeSomething+Other.m"),
                            ]),
                            TestFile("Info.plist", guid: "FR_iOS_Info.plist"),
                        ]),
                        TestGroup("macOS", children: [
                            TestGroup("Feature 1", children: [
                                TestFile("FeatureOneExtraInterfaceFile.h", guid: "FR_macOS_FeatureOneExtraInterfaceFile.h"),
                                TestFile("FeatureOneSomething.h", guid: "FR_macOS_FeatureOneSomething.h"),
                                TestFile("FeatureOneSomething.m", guid: "FR_macOS_FeatureOneSomething.m"),
                            ]),
                            TestGroup("Feature 2", children: [
                                TestFile("FeatureTwoViewController.h", guid: "FR_macOS_FeatureTwoViewController.h"),
                                TestFile("FeatureTwoViewController_Private.h", guid: "FR_macOS_FeatureTwoViewController_Private.h"),
                                TestFile("FeatureTwoViewController.m", guid: "FR_macOS_FeatureTwoViewController.m"),
                            ]),
                            TestGroup("Feature 3", children: [
                                TestFile("FeatureThreeSomething.h", guid: "FR_macOS_FeatureThreeSomething.h"),
                                TestFile("FeatureThreeSomething.m", guid: "FR_macOS_FeatureThreeSomething.m"),
                                TestFile("FeatureThreeSomething+Other.h", guid: "FR_macOS_FeatureThreeSomething+Other.h"),
                                TestFile("FeatureThreeSomething+Other.m", guid: "FR_macOS_FeatureThreeSomething+Other.m"),
                            ]),
                            TestFile("Info.plist", guid: "FR_macOS_Info.plist"),
                        ]),
                        TestGroup("Common", children: [
                            TestGroup("Feature 1", children: [
                                TestFile("FeatureOneSomethingCommon.h", guid: "FR_Common_FeatureOneSomethingCommon.h"),
                                TestFile("FeatureOneSomethingCommon.m", guid: "FR_Common_FeatureOneSomethingCommon.m"),
                            ]),
                        ]),
                    ]),
                targets: [
                    TestStandardTarget(
                        "iOS App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "SDKROOT": "iphoneos",
                                    "ARCHS": "arm64 x86_64",
                                    "ONLY_ACTIVE_ARCH": "NO",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                    "TAPI_EXEC": tapiToolPath.str,
                                    "DOCC_EXEC": doccToolPath.str,
                                    "INFOPLIST_FILE":"iOS/Info.plist",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.identifier",
                                    "CURRENT_PROJECT_VERSION": "0.0.1",
                                    "TOOLCHAIN_DIR": core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain").str,
                                ]
                            )
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile(TestFile("FeatureOneSomething.m", guid: "FR_iOS_FeatureOneSomething.m")),
                                TestBuildFile(TestFile("FeatureTwoViewController.m", guid: "FR_iOS_FeatureTwoViewController.m")),
                                TestBuildFile(TestFile("FeatureThreeSomething.m", guid: "FR_iOS_FeatureThreeSomething.m")),
                                TestBuildFile(TestFile("FeatureThreeSomething+Other.m", guid: "FR_iOS_FeatureThreeSomething+Other.m")),
                                TestBuildFile(TestFile("FeatureOneSomethingCommon.m", guid: "FR_Common_FeatureOneSomethingCommon.m")),
                            ])
                        ]
                    ),
                    TestStandardTarget(
                        "macOS App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [

                                    "ARCHS": "x86_64 arm64",
                                    "ONLY_ACTIVE_ARCH": "NO",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                    "TAPI_EXEC": tapiToolPath.str,
                                    "DOCC_EXEC": doccToolPath.str,
                                    "INFOPLIST_FILE":"macOS/Info.plist",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.identifier",
                                    "CURRENT_PROJECT_VERSION": "0.0.1",
                                    "TOOLCHAIN_DIR": core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain").str,
                                ]
                            )
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile(TestFile("FeatureOneSomething.m", guid: "FR_macOS_FeatureOneSomething.m")),
                                TestBuildFile(TestFile("FeatureTwoViewController.m", guid: "FR_macOS_FeatureTwoViewController.m")),
                                TestBuildFile(TestFile("FeatureThreeSomething.m", guid: "FR_macOS_FeatureThreeSomething.m")),
                                TestBuildFile(TestFile("FeatureThreeSomething+Other.m", guid: "FR_macOS_FeatureThreeSomething+Other.m")),
                                TestBuildFile(TestFile("FeatureOneSomethingCommon.m", guid: "FR_Common_FeatureOneSomethingCommon.m")),
                            ])
                        ]
                    )
                ]
            )

            let tester = try TaskConstructionTester(core, testProject)

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()
            let projectFolder = Path(SRCROOT)
            try fs.createDirectory(projectFolder, recursive: true)

            // iOS files and folders

            let iosFolder = projectFolder.join("iOS")
            try fs.createDirectory(iosFolder)

            try fs.write(iosFolder.join("iOS-App-Bridging.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(iosFolder.join("Info.plist"), contents: "Test")

            let iosFeature1Folder = iosFolder.join("Feature 1")
            try fs.createDirectory(iosFeature1Folder)

            try fs.write(iosFeature1Folder.join("FeatureOneExtraInterfaceFile.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(iosFeature1Folder.join("FeatureOneSomething.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(iosFeature1Folder.join("FeatureOneSomething.m"), contents: "/* Some Objective-C source content */\n")

            let iosFeature2Folder = iosFolder.join("Feature 2")
            try fs.createDirectory(iosFeature2Folder)

            try fs.write(iosFeature2Folder.join("FeatureTwoViewController.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(iosFeature2Folder.join("FeatureTwoViewController_Private.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(iosFeature2Folder.join("FeatureTwoViewController.m"), contents: "/* Some Objective-C source content */\n")

            let iosFeature3Folder = iosFolder.join("Feature 3")
            try fs.createDirectory(iosFeature3Folder)

            try fs.write(iosFeature3Folder.join("FeatureThreeSomething.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(iosFeature3Folder.join("FeatureThreeSomething.m"), contents: "/* Some Objective-C source content */\n")
            try fs.write(iosFeature3Folder.join("FeatureThreeSomething+Other.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(iosFeature3Folder.join("FeatureThreeSomething+Other.m"), contents: "/* Some Objective-C source content */\n")

            // macOS files and folders

            let macFolder = projectFolder.join("macOS")
            try fs.createDirectory(macFolder)

            try fs.write(macFolder.join("macOS-App-Bridging.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(macFolder.join("Info.plist"), contents: "Test")

            let macFeature1Folder = macFolder.join("Feature 1")
            try fs.createDirectory(macFeature1Folder)

            try fs.write(macFeature1Folder.join("FeatureOneExtraInterfaceFile.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(macFeature1Folder.join("FeatureOneSomething.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(macFeature1Folder.join("FeatureOneSomething.m"), contents: "/* Some Objective-C source content */\n")

            let macFeature2Folder = macFolder.join("Feature 2")
            try fs.createDirectory(macFeature2Folder)

            try fs.write(macFeature2Folder.join("FeatureTwoViewController.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(macFeature2Folder.join("FeatureTwoViewController_Private.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(macFeature2Folder.join("FeatureTwoViewController.m"), contents: "/* Some Objective-C source content */\n")

            let macFeature3Folder = macFolder.join("Feature 3")
            try fs.createDirectory(macFeature3Folder)

            try fs.write(macFeature3Folder.join("FeatureThreeSomething.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(macFeature3Folder.join("FeatureThreeSomething.m"), contents: "/* Some Objective-C source content */\n")
            try fs.write(macFeature3Folder.join("FeatureThreeSomething+Other.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(macFeature3Folder.join("FeatureThreeSomething+Other.m"), contents: "/* Some Objective-C source content */\n")

            // Common files and folders

            let commonFolder = projectFolder.join("Common")
            try fs.createDirectory(commonFolder)

            let commonFeature1Folder = commonFolder.join("Feature 1")
            try fs.createDirectory(commonFeature1Folder)

            try fs.write(commonFeature1Folder.join("FeatureOneSomethingCommon.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(commonFeature1Folder.join("FeatureOneSomethingCommon.m"), contents: "/* Some Objective-C source content */\n")

            // Check the build

            await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, targetName: "macOS App", fs: fs) { results in
                results.checkNoDiagnostics()

                results.checkTarget("macOS App") { target in
                    for arch in ["x86_64", "arm64"] {
                        let sdkdbFile = "/tmp/Test/aProject/build/aProject.build/Debug/macOS App.build/symbol-graph/clang/\(arch)-apple-macos\(core.loadSDK(.macOS).version)/macOS App.sdkdb"
                        let symbolGraphFile = "/tmp/Test/aProject/build/aProject.build/Debug/macOS App.build/symbol-graph/clang/\(arch)-apple-macos\(core.loadSDK(.macOS).version)/macOS_App.symbols.json"
                        results.checkTask(
                            .matchTarget(target),
                            .matchRule([
                                "ExtractAPI",
                                SWBFeatureFlag.enableClangExtractAPI.value ? symbolGraphFile : sdkdbFile
                            ])
                        ) { task in
                            let headerTaskOrderingInputPaths = task.inputs
                                .filter { $0.path.fileExtension == "h" }
                                .map { $0.path.str }

                            #expect(headerTaskOrderingInputPaths == [
                                "/tmp/Test/aProject/macOS/Feature 1/FeatureOneExtraInterfaceFile.h",
                                "/tmp/Test/aProject/macOS/Feature 1/FeatureOneSomething.h",
                                "/tmp/Test/aProject/macOS/Feature 2/FeatureTwoViewController.h",
                                "/tmp/Test/aProject/macOS/Feature 2/FeatureTwoViewController_Private.h",
                                "/tmp/Test/aProject/macOS/Feature 3/FeatureThreeSomething.h",
                                "/tmp/Test/aProject/macOS/Feature 3/FeatureThreeSomething+Other.h",
                                "/tmp/Test/aProject/Common/Feature 1/FeatureOneSomethingCommon.h",
                            ])
                        }
                    }
                    // Since symbol information is extracted, there should also be a documentation built task.
                    results.checkTaskExists(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
                }
            }

            await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyiOSSimulator, targetName: "iOS App", fs: fs) { results in
                results.checkNoDiagnostics()

                results.checkTarget("iOS App") { target in
                    for arch in ["x86_64", "arm64"] {
                        let sdkdbFile = "/tmp/Test/aProject/build/aProject.build/Debug-iphonesimulator/iOS App.build/symbol-graph/clang/\(arch)-apple-ios\(results.runDestinationSDK.version)-simulator/iOS App.sdkdb"
                        let symbolGraphFile = "/tmp/Test/aProject/build/aProject.build/Debug-iphonesimulator/iOS App.build/symbol-graph/clang/\(arch)-apple-ios\(results.runDestinationSDK.version)-simulator/iOS_App.symbols.json"

                        results.checkTask(
                            .matchTarget(target),
                            .matchRule([
                                "ExtractAPI",
                                SWBFeatureFlag.enableClangExtractAPI.value ? symbolGraphFile : sdkdbFile
                            ])
                        ) { task in
                            let headerTaskOrderingInputPaths = task.inputs
                                .filter { $0.path.fileExtension == "h" }
                                .map { $0.path.str }

                            #expect(headerTaskOrderingInputPaths == [
                                "/tmp/Test/aProject/iOS/Feature 1/FeatureOneExtraInterfaceFile.h",
                                "/tmp/Test/aProject/iOS/Feature 1/FeatureOneSomething.h",
                                "/tmp/Test/aProject/iOS/Feature 2/FeatureTwoViewController.h",
                                "/tmp/Test/aProject/iOS/Feature 2/FeatureTwoViewController_Private.h",
                                "/tmp/Test/aProject/iOS/Feature 3/FeatureThreeSomething.h",
                                "/tmp/Test/aProject/iOS/Feature 3/FeatureThreeSomething+Other.h",
                                "/tmp/Test/aProject/Common/Feature 1/FeatureOneSomethingCommon.h",
                            ])
                        }

                        if !SWBFeatureFlag.enableClangExtractAPI.value {
                            results.checkTaskExists(.matchTarget(target), .matchRule(["ConvertSDKDBToSymbolGraph", sdkdbFile]))
                        }
                    }
                    // Since symbol information is extracted, there should also be a documentation built task.
                    results.checkTaskExists(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func dependencyModuleMapsArePassedToExtractAPI() async throws {
        let clangFeatures = try await self.clangFeatures
        try await ObjectiveCSymbolExtractorImplementationSelector.runWithAllImplementations {
            let core = try await getCore()
            let testProject = try await TestProject(
                "aProject",
                // This is meant to represent a small but well organized cross platform app target
                groupTree:
                    TestGroup("Project", children: [
                        TestGroup("Objective-C App", children: [
                            TestFile("Something.h"),
                            TestFile("Something.m"),
                            TestFile("Info.plist"),
                        ]),
                        TestGroup("Swift Dependency", children: [
                            TestFile("Dependency.swift"),
                        ]),
                        TestGroup("Swift Sub-Dependency", children: [
                            TestFile("Sub-Dependency.swift"),
                        ]),
                    ]),
                targets: [
                    TestStandardTarget(
                        "SwiftSubDependency",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "ARCHS": "arm64 x86_64",
                                    "ONLY_ACTIVE_ARCH": "NO",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    "SWIFT_VERSION": "5.2",
                                    // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                    "TAPI_EXEC": tapiToolPath.str,
                                    "DOCC_EXEC": doccToolPath.str,
                                    "INFOPLIST_FILE":"Swift Sub-Dependency/Info.plist",
                                    "DEFINES_MODULE": "YES",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.sub-dependency",
                                    "CURRENT_PROJECT_VERSION": "0.0.1",
                                    "TOOLCHAIN_DIR": core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain").str,
                                ]
                            )
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile(TestFile("Dependency.swift")),
                            ])
                        ]
                    ),
                    TestStandardTarget(
                        "SwiftDependency",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "ARCHS": "arm64 x86_64",
                                    "ONLY_ACTIVE_ARCH": "NO",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    "SWIFT_VERSION": "5.2",
                                    // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                    "TAPI_EXEC": tapiToolPath.str,
                                    "DOCC_EXEC": doccToolPath.str,
                                    "INFOPLIST_FILE":"Swift Dependency/Info.plist",
                                    "DEFINES_MODULE": "YES",
                                    "MODULEMAP_PATH": "dependency_custom_module_map_file_path",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.dependency",
                                    "CURRENT_PROJECT_VERSION": "0.0.1",
                                    "TOOLCHAIN_DIR": core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain").str,
                                ]
                            )
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile(TestFile("Dependency.swift")),
                            ])
                        ],
                        dependencies: [
                            TestTargetDependency("SwiftSubDependency")
                        ]
                    ),
                    TestStandardTarget(
                        "Objective-C App",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "ARCHS": "arm64 x86_64",
                                    "ONLY_ACTIVE_ARCH": "NO",
                                    // Set the real TAPI tool path so that we can check its version to determine what version of the "headers info" JSON file to pass to `tapi extractapi`.
                                    "TAPI_EXEC": tapiToolPath.str,
                                    "DOCC_EXEC": doccToolPath.str,
                                    "INFOPLIST_FILE":"Objective-C App/Info.plist",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.app",
                                    "CURRENT_PROJECT_VERSION": "0.0.1",
                                    "TOOLCHAIN_DIR": core.developerPath.path.join("Toolchains/XcodeDefault.xctoolchain").str,
                                    // Set the real swift compiler path so we can determine the location of compatibility headers ignores file
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    // Set the real clang tool path so that we can check it's features.json file
                                    "CC": clangCompilerPath.str,
                                ]
                            )
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase([
                                TestBuildFile(TestFile("Something.m")),
                            ])
                        ],
                        dependencies: [
                            TestTargetDependency("SwiftDependency")
                        ]
                    )
                ]
            )

            let tester = try TaskConstructionTester(core, testProject)

            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            let fs = PseudoFS()
            let projectFolder = Path(SRCROOT)
            try fs.createDirectory(projectFolder, recursive: true)

            // App files and folders

            let appFolder = projectFolder.join("Objective-C App")
            try fs.createDirectory(appFolder)

            try fs.write(appFolder.join("Something.h"), contents: "/* Some Objective-C header content */\n")
            try fs.write(appFolder.join("Something.m"), contents: "/* Some Objective-C source content */\n")
            try fs.write(appFolder.join("Info.plist"), contents: "Test")

            // Dependency files and folders

            let dependencyFolder = projectFolder.join("Swift Dependency")
            try fs.createDirectory(dependencyFolder)
            try fs.write(dependencyFolder.join("Dependency.swift"), contents: "/* Some Swift content */\n")
            try fs.write(dependencyFolder.join("Info.plist"), contents: "Test")

            let subDependencyFolder = projectFolder.join("Swift Sub-Dependency")
            try fs.createDirectory(subDependencyFolder)
            try fs.write(subDependencyFolder.join("Sub-Dependency.swift"), contents: "/* Some Swift content */\n")
            try fs.write(subDependencyFolder.join("Info.plist"), contents: "Test")

            // Check the build

            try await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, targetName: "Objective-C App", fs: fs) { results in
                results.checkNoDiagnostics()
                let compatibilitySymbolsFile = try await swiftCompilerPath.dirname.dirname.join("share").join("swift").join("compatibility-symbols")

                results.checkTarget("Objective-C App") { target in
                    for arch in ["x86_64", "arm64"] {
                        let sdkdbFile = "/tmp/Test/aProject/build/aProject.build/Debug/Objective-C App.build/symbol-graph/clang/\(arch)-apple-macos\(core.loadSDK(.macOS).version)/Objective-C App.sdkdb"
                        let symbolGraphFile = "/tmp/Test/aProject/build/aProject.build/Debug/Objective-C App.build/symbol-graph/clang/\(arch)-apple-macos\(core.loadSDK(.macOS).version)/Objective_C_App.symbols.json"

                        results.checkTask(
                            .matchTarget(target),
                            .matchRule([
                                "ExtractAPI",
                                SWBFeatureFlag.enableClangExtractAPI.value ? symbolGraphFile : sdkdbFile
                            ])) { task in
                                task.checkCommandLineContains([
                                    // Check custom MODULEMAP_PATH values. This would for example be the generated module map.
                                    "-fmodule-map-file=/tmp/Test/aProject/dependency_custom_module_map_file_path",
                                    // Check that module maps from dependencies' dependencies are also passed.
                                    "-fmodule-map-file=/tmp/Test/aProject/build/Debug/SwiftSubDependency.framework/Versions/A/Modules/module.modulemap"
                                ])

                                if SWBFeatureFlag.enableClangExtractAPI.value && clangFeatures.has(.extractAPIIgnores) {
                                    task.checkCommandLineContains(["--extract-api-ignores=\(compatibilitySymbolsFile.str)"])
                                }
                            }

                        if !SWBFeatureFlag.enableClangExtractAPI.value {
                            results.checkTaskExists(.matchTarget(target), .matchRule(["ConvertSDKDBToSymbolGraph", sdkdbFile]))
                        }
                    }

                    // Since symbol information is extracted, there should also be a documentation built task.
                    results.checkTaskExists(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .enabled(if: SWBFeatureFlag.enableClangExtractAPI.value))
    func cXXFilesAreIgnoredWhenCXXSupportIsDisabled() async throws {
        // This test only applies to clang base symbol graph generation
        try await withTemporaryDirectory { sourceRoot in
            let core = try await getCore()

            let testProject = try await TestProject(
                "aProject",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("Info.plist"),
                        TestFile("ObjCHeaderFilePublic.h"),
                        TestFile("ObjCXXHeaderFilePublic.hpp"),
                        TestFile("ObjCXXSourceFile.cpp"),
                    ]
                ),
                targets: [
                    TestStandardTarget(
                        "Framework",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "ARCHS": "x86_64 arm64",
                                    "ONLY_ACTIVE_ARCH": "NO",
                                    "SWIFT_VERSION": "5.0",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    "CC": clangCompilerPath.str,
                                    "TAPI_EXEC": tapiToolPath.str,
                                    "DOCC_EXEC": doccToolPath.str,
                                    "INFOPLIST_FILE":"Info.plist",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.identifier",
                                    "CURRENT_PROJECT_VERSION": "0.0.1",
                                    "CLANG_CXX_LANGUAGE_STANDARD": "c++23",
                                    "OTHER_CPLUSPLUSFLAGS": "-fchar8_t",
                                    "DOCC_ENABLE_CXX_SUPPORT": "NO" // Disable C++ symbol graph generation
                                ]
                            )
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("ObjCHeaderFilePublic.h", headerVisibility: .public),
                                TestBuildFile("ObjCXXHeaderFilePublic.hpp", headerVisibility: .public)
                            ]),
                            TestSourcesBuildPhase([
                                TestBuildFile("ObjCXXSourceFile.cpp")
                            ])
                        ]
                    ),
                    TestStandardTarget(
                        "CXXOnlyFramework",
                        type: .framework,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "ARCHS": "x86_64 arm64",
                                    "ONLY_ACTIVE_ARCH": "NO",
                                    "SWIFT_VERSION": "5.0",
                                    "SWIFT_EXEC": swiftCompilerPath.str,
                                    "CC": clangCompilerPath.str,
                                    "TAPI_EXEC": tapiToolPath.str,
                                    "DOCC_EXEC": doccToolPath.str,
                                    "INFOPLIST_FILE":"Info.plist",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "PRODUCT_BUNDLE_IDENTIFIER": "test.bundle.identifier",
                                    "CURRENT_PROJECT_VERSION": "0.0.1",
                                    "CLANG_CXX_LANGUAGE_STANDARD": "c++23",
                                    "OTHER_CPLUSPLUSFLAGS": "-fchar8_t",
                                    "DOCC_ENABLE_CXX_SUPPORT": "NO" // Disable C++ symbol graph generation
                                ]
                            )
                        ],
                        buildPhases: [
                            TestHeadersBuildPhase([
                                TestBuildFile("ObjCXXHeaderFilePublic.hpp", headerVisibility: .public)
                            ]),
                            TestSourcesBuildPhase([
                                TestBuildFile("ObjCXXSourceFile.cpp")
                            ])
                        ]
                    )
                ]
            )

            let tester = try TaskConstructionTester(core, testProject)

            let projectFolder = tester.workspace.projects[0].sourceRoot
            let fs = PseudoFS()

            try fs.createDirectory(projectFolder, recursive: true)

            try fs.write(projectFolder.join("ObjCHeaderFilePublic.h"), contents: "/* Some Objective-C content */\n")
            try fs.write(projectFolder.join("ObjCXXHeaderFilePublic.h"), contents: "/* Some Objective-C++ content */\n")
            try fs.write(projectFolder.join("Info.plist"), contents: "Test")

            await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, targetName: "Framework", fs: fs) { results in
                results.checkNoDiagnostics()

                results.checkTarget("Framework") { target in
                    // Check the extract-api related tasks are generated:
                    for arch in ["x86_64", "arm64"] {
                        let symbolGraphFile = projectFolder.join(
                            "build/aProject.build/Debug/Framework.build/symbol-graph/clang/\(arch)-apple-macos\(core.loadSDK(.macOS).version)/Framework.symbols.json"
                        )

                        results.checkTask(
                            .matchTarget(target),
                            .matchRule([ "ExtractAPI", symbolGraphFile.str])
                        ) { task in
                            task.checkCommandLineContainsUninterrupted(["-x", "objective-c-header"])
                            task.checkCommandLineMatches([.contains("ObjCHeaderFilePublic.h")])
                            task.checkCommandLineNoMatch([.contains("ObjCXXHeaderFilePublic.h")])
                        }
                    }

                    // Since symbol information is extracted, there should also be a documentation built task.
                    results.checkTaskExists(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
                }
            }

            await tester.checkBuild(BuildParameters(action: .docBuild, configuration: "Debug"), runDestination: .anyMac, targetName: "CXXOnlyFramework", fs: fs) { results in
                // Ensure we don't generate any documentation tasks for C++ only framework with C++ documentation support disabled.
                results.checkTarget("CXXOnlyFramework") { target in
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("ExtractAPI"))
                    results.checkNoTask(.matchTarget(target), .matchRuleItem("CompileDocumentation"))
                }
            }
        }
    }
}

struct ObjectiveCSymbolExtractorImplementationSelector {
    static func runWithTapi(test: () async throws -> Void) async throws {
        try await UserDefaults.withEnvironment(["IDEDocumentationEnableClangExtractAPI": "0"]) {
            #expect(!SWBFeatureFlag.enableClangExtractAPI.value, "Feature flag was not properly set!")
            try await test()
        }
    }

    static func runWithClang(test: () async throws -> Void) async throws {
        try await UserDefaults.withEnvironment(["IDEDocumentationEnableClangExtractAPI": "1"]) {
            #expect(SWBFeatureFlag.enableClangExtractAPI.value, "Feature flag was not properly set!")
            try await test()
        }
    }

    static func runWithAllImplementations(test: () async throws -> Void) async throws {
        try await runWithTapi(test: test)
        try await runWithClang(test: test)
    }
}
