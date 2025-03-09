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

import SWBTaskConstruction
import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct ExportLocTaskConstructionTests: CoreBasedTests {
    func getTestProject() async throws -> TestProject {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("test.swift"),
                    TestFile("AppTarget/Info.plist")
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CURRENT_PROJECT_VERSION": "3.1",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ]
                )
            ],
            targets: [
                TestStandardTarget(
                    "AppTarget",
                    type: .application,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "AppTarget/Info.plist"])
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "test.swift"
                        ])
                    ]
                )
            ]
        )
        return testProject
    }

    @Test(.requireSDKs(.macOS), .requireLocalizedStringExtraction)
    func exportLocBasics() async throws {
        let testProject = try await getTestProject()
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let localizedStringsPath = "/tmp/StringsPath"
        let swiftFeatures = try await self.swiftFeatures
        await tester.checkBuild(BuildParameters(action: .exportLoc, configuration: "Debug", overrides: ["SWIFT_EMIT_LOC_STRINGS": "YES", "STRINGSDATA_DIR": localizedStringsPath]), runDestination: .macOS) { results in
            results.checkTarget("AppTarget") { target in
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("Ld")) { _ in }
                results.checkTasks(.matchRuleType("Copy")) { _ in }
                results.checkTask(.matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchRuleType("Touch")) { _ in }
                // There should be flags related to localized strings emitted when exportLoc action is executed.
                let targetArchitecture = results.runDestinationTargetArchitecture
                if swiftFeatures.has(.emitLocalizedStrings) {
                    results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation", "AppTarget", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkCommandLineContains(["-emit-localized-strings", "-emit-localized-strings-path", localizedStringsPath])
                        task.checkOutputs(contain: [.path("/tmp/StringsPath/test.stringsdata")])
                    }
                } else {
                    results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver", "AppTarget", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkCommandLineNoMatch([.anySequence, .equal("-emit-localized-strings"), .anySequence, .equal("-emit-localized-strings-path"), .anySequence])
                    }
                }

                // App Intents metadata extraction should also run here
                results.checkTask(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
            }

            results.consumeTasksMatchingRuleTypes(["SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders"])

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildActionNotEmittingLocStrings() async throws {
        let testProject = try await getTestProject()
        let tester = try await TaskConstructionTester(getCore(), testProject)
        //Check normal build action and make sure that -emit-localized-strings and -emit-localized-strings-path flags aren't present
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS) { results in
            results.checkTarget("AppTarget") { target in
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTask(.matchRuleItem("ProcessInfoPlistFile")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("Touch")) { _ in }
                results.checkTasks(.matchRuleType("Copy")) { _ in }
                results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
                results.checkTasks(.matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTasks(.matchRuleType("ProcessProductPackaging")) { _ in }
                results.checkTasks(.matchRuleType("ProcessProductPackagingDER")) { _ in }
                results.checkTasks(.matchRuleType("Ld")) { _ in }
                results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
                results.checkTasks(.matchRuleType("Validate")) { _ in }
                results.checkTasks(.matchRuleType("CodeSign")) { _ in }
                results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
                results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }
                let targetArchitecture = results.runDestinationTargetArchitecture
                results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation", "AppTarget", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                    task.checkCommandLineNoMatch([.anySequence, .equal("-emit-localized-strings"), .anySequence, .equal("-emit-localized-strings-path"), .anySequence])
                }
            }

            results.consumeTasksMatchingRuleTypes(["SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders"])

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS), .requireLocalizedStringExtraction)
    func buildActionEmittingLocStrings() async throws {
        let testProject = try await getTestProject()
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let localizedStringsPath = "/tmp/StringsPath"
        let swiftFeatures = try await self.swiftFeatures
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: ["SWIFT_EMIT_LOC_STRINGS": "YES", "STRINGSDATA_DIR": localizedStringsPath]), runDestination: .macOS) { results in
            results.checkTarget("AppTarget") { target in
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTask(.matchRuleItem("ProcessInfoPlistFile")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("MkDir")) { _ in }
                results.checkTasks(.matchRuleType("Touch")) { _ in }
                results.checkTasks(.matchRuleType("Copy")) { _ in }
                results.checkTasks(.matchRuleType("RegisterWithLaunchServices")) { _ in }
                results.checkTasks(.matchRuleType("CopySwiftLibs")) { _ in }
                results.checkTasks(.matchRuleType("ProcessProductPackaging")) { _ in }
                results.checkTasks(.matchRuleType("ProcessProductPackagingDER")) { _ in }
                results.checkTasks(.matchRuleType("Ld")) { _ in }
                results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }
                results.checkTasks(.matchRuleType("Validate")) { _ in }
                results.checkTasks(.matchRuleType("CodeSign")) { _ in }
                results.checkTasks(.matchRuleType("ProcessInfoPlistFile")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("ExtractAppIntentsMetadata")) { _ in }
                results.checkTasks(.matchRuleType("AppIntentsSSUTraining")) { _ in }
                // There should be flgas related to localized strings emitted when SWIFT_EMIT_LOC_STRINGS is set to YES.
                let targetArchitecture = results.runDestinationTargetArchitecture
                if swiftFeatures.has(.emitLocalizedStrings) {
                    results.checkTask(.matchTarget(target), .matchRule(["SwiftDriver Compilation", "AppTarget", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkCommandLineContains(["-emit-localized-strings", "-emit-localized-strings-path", localizedStringsPath])
                        task.checkOutputs(contain: [.path("/tmp/StringsPath/test.stringsdata")])
                    }
                } else {
                    results.checkTask(.matchTarget(target), .matchRule(["CompileSwiftSources", "normal", targetArchitecture, "com.apple.xcode.tools.swift.compiler"])) { task in
                        task.checkCommandLineNoMatch([.anySequence, .equal("-emit-localized-strings"), .anySequence, .equal("-emit-localized-strings-path"), .anySequence])
                    }
                }
            }

            results.consumeTasksMatchingRuleTypes(["SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders"])

            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }
}
