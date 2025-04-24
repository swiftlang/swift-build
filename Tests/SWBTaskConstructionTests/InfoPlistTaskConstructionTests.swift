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

import SWBCore
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction
import SWBProtocol

@Suite
fileprivate struct InfoPlistTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func infoPlistPreprocessing() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("infoplist-prefix.h"),
                    TestFile("SourceFile.m"),
                    TestFile("Tool.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
                    "INFOPLIST_FILE": "Tool.plist",
                    "INFOPLIST_PREPROCESS": "YES",

                    // These should be ignored for plist preprocessing
                    "GCC_PREPROCESSOR_DEFINITIONS": "FOO=GCC_PREPROCESSOR_DEFINITIONS BAR=GCC_PREPROCESSOR_DEFINITIONS",
                    "CPP_OTHER_PREPROCESSOR_FLAGS": "-CPP_OTHER_PREPROCESSOR_FLAGS1 -CPP_OTHER_PREPROCESSOR_FLAGS2",
                    "CPP_PREFIX_HEADER": "cpp-prefix.h",
                ]),
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES",
                    "INFOPLIST_FILE": "Tool.plist",
                    "INFOPLIST_PREPROCESS": "YES",

                    // These should be ignored for plist preprocessing
                    "GCC_PREPROCESSOR_DEFINITIONS": "FOO=GCC_PREPROCESSOR_DEFINITIONS BAR=GCC_PREPROCESSOR_DEFINITIONS",
                    "CPP_OTHER_PREPROCESSOR_FLAGS": "-CPP_OTHER_PREPROCESSOR_FLAGS1 -CPP_OTHER_PREPROCESSOR_FLAGS2",
                    "CPP_PREFIX_HEADER": "cpp-prefix.h",

                    // These should take effect for plist preprocessing
                    "INFOPLIST_PREPROCESSOR_DEFINITIONS": "FOO=INFOPLIST_PREPROCESSOR_DEFINITIONS BAR=INFOPLIST_PREPROCESSOR_DEFINITIONS",
                    "INFOPLIST_OTHER_PREPROCESSOR_FLAGS": "-INFOPLIST_OTHER_PREPROCESSOR_FLAGS1 -INFOPLIST_OTHER_PREPROCESSOR_FLAGS2",
                    "INFOPLIST_PREFIX_HEADER": "$(PROJECT_DIR)/infoplist-prefix.h",
                ]),
            ],
            targets: [
                TestAggregateTarget("All", dependencies: ["Tool", "App"]),
                TestStandardTarget(
                    "Tool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile.m",
                        ]),
                    ]
                ),
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                        TestBuildConfiguration("Release"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceFile.m",
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Tool") { target in
                // There should be an Info.plist processing task, and associated Preprocess (we explicitly enable it).
                results.checkTask(.matchTarget(target), .matchRuleType("Preprocess")) { task in
                    task.checkRuleInfo(["Preprocess", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/normal/\(results.runDestinationTargetArchitecture)/Preprocessed-Info.plist", "\(SRCROOT)/Tool.plist"])
                    task.checkCommandLine(["cc", "-E", "-P", "-x", "c", "-Wno-trigraphs", "\(SRCROOT)/Tool.plist", "-F\(SRCROOT)/build/Debug", "-target", "\(results.runDestinationTargetArchitecture)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-o", "\(SRCROOT)/build/aProject.build/Debug/Tool.build/normal/\(results.runDestinationTargetArchitecture)/Preprocessed-Info.plist"])
                    task.checkInputs([
                        .path("\(SRCROOT)/Tool.plist"),
                        .namePattern(.and(.prefix("target-Tool-T-Tool-"), .suffix("--ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-Tool-T-Tool-"), .suffix("--entry"))),
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Debug/Tool.build/normal/\(results.runDestinationTargetArchitecture)/Preprocessed-Info.plist")
                    ])
                }
            }
        }

        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .anyMac) { results in
            results.checkNoDiagnostics()
            results.checkTarget("Tool") { target in
                for arch in ["arm64", "x86_64"] {
                    // There should be an Info.plist processing task, and associated Preprocess (we explicitly enable it).
                    results.checkTask(.matchTarget(target), .matchRule(["Preprocess", "\(SRCROOT)/build/aProject.build/Release/Tool.build/normal/\(arch)/Preprocessed-Info.plist", "\(SRCROOT)/Tool.plist"])) { task in
                        task.checkCommandLine(["cc", "-E", "-P", "-x", "c", "-Wno-trigraphs", "\(SRCROOT)/Tool.plist", "-F\(SRCROOT)/build/Release", "-target", "\(arch)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-DFOO=INFOPLIST_PREPROCESSOR_DEFINITIONS", "-DBAR=INFOPLIST_PREPROCESSOR_DEFINITIONS", "-include", "\(SRCROOT)/infoplist-prefix.h", "-INFOPLIST_OTHER_PREPROCESSOR_FLAGS1", "-INFOPLIST_OTHER_PREPROCESSOR_FLAGS2", "-o", "\(SRCROOT)/build/aProject.build/Release/Tool.build/normal/\(arch)/Preprocessed-Info.plist"])
                        task.checkInputs([
                            .path("\(SRCROOT)/Tool.plist"),
                            .path("\(SRCROOT)/infoplist-prefix.h"),
                            .namePattern(.and(.prefix("target-Tool-T-Tool-"), .suffix("--ModuleVerifierTaskProducer"))),
                            .namePattern(.and(.prefix("target-Tool-T-Tool-"), .suffix("--entry"))),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Release/Tool.build/normal/\(arch)/Preprocessed-Info.plist")
                        ])
                    }
                }
            }

            results.checkTarget("App") { target in
                for arch in ["arm64", "x86_64"] {
                    // There should be an Info.plist processing task, and associated Preprocess (we explicitly enable it).
                    results.checkTask(.matchTarget(target), .matchRule(["Preprocess", "\(SRCROOT)/build/aProject.build/Release/App.build/normal/\(arch)/Preprocessed-Info.plist", "\(SRCROOT)/Tool.plist"])) { task in
                        task.checkCommandLine(["cc", "-E", "-P", "-x", "c", "-Wno-trigraphs", "\(SRCROOT)/Tool.plist", "-F\(SRCROOT)/build/Release", "-target", "\(arch)-apple-macos\(core.loadSDK(.macOS).defaultDeploymentTarget)", "-isysroot", core.loadSDK(.macOS).path.str, "-DFOO=INFOPLIST_PREPROCESSOR_DEFINITIONS", "-DBAR=INFOPLIST_PREPROCESSOR_DEFINITIONS", "-include", "\(SRCROOT)/infoplist-prefix.h", "-INFOPLIST_OTHER_PREPROCESSOR_FLAGS1", "-INFOPLIST_OTHER_PREPROCESSOR_FLAGS2", "-o", "\(SRCROOT)/build/aProject.build/Release/App.build/normal/\(arch)/Preprocessed-Info.plist"])
                        task.checkInputs([
                            .path("\(SRCROOT)/Tool.plist"),
                            .path("\(SRCROOT)/infoplist-prefix.h"),
                            .namePattern(.and(.prefix("target-App-T-App-"), .suffix("--ModuleVerifierTaskProducer"))),
                            .namePattern(.and(.prefix("target-App-T-App-"), .suffix("--entry"))),
                        ])
                        task.checkOutputs([
                            .path("\(SRCROOT)/build/aProject.build/Release/App.build/normal/\(arch)/Preprocessed-Info.plist")
                        ])
                    }
                }

                results.checkTask(.matchTarget(target), .matchRuleType("MergeInfoPlistFile")) { task in
                    task.checkCommandLine([
                        "builtin-mergeInfoPlist",
                        "\(SRCROOT)/build/aProject.build/Release/App.build/Preprocessed-Info.plist",
                        "\(SRCROOT)/build/aProject.build/Release/App.build/normal/arm64/Preprocessed-Info.plist",
                        "\(SRCROOT)/build/aProject.build/Release/App.build/normal/x86_64/Preprocessed-Info.plist"])
                    task.checkInputs([
                        .path("\(SRCROOT)/build/aProject.build/Release/App.build/normal/arm64/Preprocessed-Info.plist"),
                        .path("\(SRCROOT)/build/aProject.build/Release/App.build/normal/x86_64/Preprocessed-Info.plist"),
                        .namePattern(.and(.prefix("target-App-T-App-"), .suffix("--ModuleVerifierTaskProducer"))),
                        .namePattern(.and(.prefix("target-App-T-App-"), .suffix("--entry"))),
                    ])
                    task.checkOutputs([
                        .path("\(SRCROOT)/build/aProject.build/Release/App.build/Preprocessed-Info.plist")
                    ])
                }
            }
        }
    }
}
