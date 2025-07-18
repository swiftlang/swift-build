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

import Foundation
import Testing
import SWBCore
import SWBProtocol
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil


@Suite
fileprivate struct EXUtilTaskConstructionTests: CoreBasedTests {

    @Test(.requireSDKs(.iOS), .requireMinimumSDKBuildVersion(sdkName: KnownSDK.iOS.sdkName, requiredVersion: "23A213"))
    func extractExtensionPoint() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "ExtensionPointTest",
                        type: .application,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "LM_ENABLE_LINK_GENERATION": "YES",
                                    "EX_ENABLE_EXTENSION_POINT_GENERATION" : "YES"
                                ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            await tester.checkBuild(runDestination: .iOS) { results in

                results.checkTask(.matchRuleType("ExtensionPointExtractor")) { task in
                    task.checkCommandLineMatches(["exutil", "extract-extension-points", .anySequence])
                    task.checkInputs(contain: [.name("source.swiftconstvalues")])
                    task.checkOutputs(contain: [.namePattern(.suffix("-generated.appexpt"))])
                    results.checkNoDiagnostics()

                }
                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-emit-const-values"])
                }
            }
        }
    }

    @Test(.requireSDKs(.iOS), .requireMinimumSDKBuildVersion(sdkName: KnownSDK.iOS.sdkName, requiredVersion: "23A213"))
    func generateExtensionPlist() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("source.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                            "ARCHS": "arm64",
                            "CODE_SIGN_IDENTITY": "-",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_BUNDLE_IDENTIFIER": "com.foo.bar",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "iphoneos",
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "SWIFT_VERSION": swiftVersion,
                            "VERSIONING_SYSTEM": "apple-generic",
                            "SWIFT_EMIT_CONST_VALUE_PROTOCOLS": "Foo Bar",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppExtensionPlistGeneratorTest",
                        type: .extensionKitExtension,
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["source.swift"]),
                        ]
                    )
                ])

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, testProject)
            try await tester.checkBuild(runDestination: .iOS) { results in

                let generatorTask = try #require(results.checkTask(.matchRuleType("AppExtensionPListGenerator")) { task in
                    task.checkCommandLineMatches(["exutil", "generate-appextension-plist", .anySequence])
                    task.checkInputs(contain: [.name("source.swiftconstvalues")])
                    task.checkOutputs(contain: [.namePattern(.suffix("appextension-generated-info.plist"))])
                    results.checkNoDiagnostics()
                    return task
                })

                results.checkTask(.matchRuleType("ProcessInfoPlistFile")) { task in
                    results.checkTaskFollows(task, antecedent: generatorTask)
                }

                results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-emit-const-values"])
                }
            }
        }
    }

}
