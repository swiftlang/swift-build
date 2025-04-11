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
import SWBProtocol

/// Test suite for tests specifically examining rebuilding projects in interesting scenarios.
@Suite
fileprivate struct RebuildTests: CoreBasedTests {
    /// Tests building a target switching between two different architectures.
    ///
    /// This is primarily to test the behavior for <rdar://problem/63196141>, which requires:
    /// - To alternate building for a different architecture for each build;
    /// - To only build for a single architecture for each build, and
    /// - For the binary to have mutating tasks, such as code signing.
    @Test(.requireSDKs(.iOS))
    func architectureSwitching() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("ClassOne.swift"),
                                TestFile("ClassTwo.swift"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "SDKROOT": "iphoneos",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "INFOPLIST_FILE": "Sources/Info.plist",
                                "SWIFT_VERSION": swiftVersion,
                                "CODE_SIGN_IDENTITY": "-",
                                "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                "EAGER_LINKING": "NO",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "Framework", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "ClassOne.swift",
                                        "ClassTwo.swift",
                                    ]),
                                    TestFrameworksBuildPhase(),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Write out the files we need.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/ClassOne.swift")) { contents in
                contents <<< "public class ClassOne {\n"
                contents <<< "    public init() {}\n"
                contents <<< "    public func printIt() { print(\"ClassOne\") }\n"
                contents <<< "}\n"
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/ClassTwo.swift")) { contents in
                contents <<< "public class ClassTwo {\n"
                contents <<< "    public init() {}\n"
                contents <<< "    public func printIt() { print(\"ClassTwo\") }\n"
                contents <<< "}\n"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/Sources/Info.plist"), .plDict(["CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")]))

            // Configure the provisioning inputs.
            let provisioningInputs = ["Framework": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:]))]

            // Check the initial build for arm64.
            var arch = "arm64"
            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: ["ARCHS": arch]), runDestination: .iOS, persistent: true, serial: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Copy", "Gate", "MkDir", "RegisterExecutionPolicyException", "WriteAuxiliaryFile", "Touch", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining", "ClangStatCache", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports"])
                results.checkTask(.matchRuleItem("ProcessInfoPlistFile")) { _ in }
                results.checkTasks(.matchRuleItem("SwiftCompile")) { #expect($0.count == 2) }
                results.checkTask(.matchRuleItem("SwiftEmitModule")) { _ in }
                results.checkTask(.matchRuleItem("Ld"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework/Framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateTAPI")) { _ in }
                results.checkTask(.matchRuleItem("CodeSign"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateDSYMFile"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework.dSYM")) { _ in }
                results.checkNoTask()
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkNoDiagnostics()
            }

            // Check the rebuild for arm64e.
            arch = "arm64e"
            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: ["ARCHS": arch]), runDestination: .iOS, persistent: true, serial: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Copy", "Gate", "MkDir", "RegisterExecutionPolicyException", "WriteAuxiliaryFile", "Touch", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining", "ClangStatCache", "SwiftExplicitDependencyCompileModuleFromInterface", "SwiftExplicitDependencyGeneratePcm", "ProcessSDKImports"])
                // I think the Info.plist gets reprocessed because we force it to re-run when certain build settings change to facilitate build setting expansion even if the source file doesn't change.
                results.checkTask(.matchRuleItem("ProcessInfoPlistFile")) { _ in }
                results.checkTasks(.matchRuleItem("SwiftCompile")) { #expect($0.count == 2) }
                results.checkTask(.matchRuleItem("SwiftEmitModule")) { _ in }
                results.checkTask(.matchRuleItem("Ld"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework/Framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateTAPI")) { _ in }
                results.checkTask(.matchRuleItem("CodeSign"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateDSYMFile"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework.dSYM")) { _ in }
                results.checkNoTask()
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkWarning(.contains("mismatching function effects"), failIfNotFound: false)
                results.checkNoDiagnostics()
            }

            // Now rebuild again for arm64 and make sure we re-link.
            arch = "arm64"
            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: ["ARCHS": arch]), runDestination: .iOS, persistent: true, serial: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Copy", "Gate", "MkDir", "RegisterExecutionPolicyException", "WriteAuxiliaryFile", "Touch", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining", "ClangStatCache", "ProcessSDKImports"])
                results.checkTask(.matchRuleItem("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchRuleItem("Ld"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework/Framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateTAPI")) { _ in }
                results.checkTask(.matchRuleItem("CodeSign"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateDSYMFile"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework.dSYM")) { _ in }
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // Now back to arm64e once more.
            arch = "arm64e"
            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: ["ARCHS": arch]), runDestination: .iOS, persistent: true, serial: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Copy", "Gate", "MkDir", "RegisterExecutionPolicyException", "WriteAuxiliaryFile", "Touch", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "SwiftMergeGeneratedHeaders", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining", "ClangStatCache", "ProcessSDKImports"])
                results.checkTask(.matchRuleItem("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchRuleItem("Ld"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework/Framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateTAPI")) { _ in }
                results.checkTask(.matchRuleItem("CodeSign"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateDSYMFile"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework.dSYM")) { _ in }
                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // And a second consecutive build for arm64e to make sure it's a null build.
            arch = "arm64e"
            try await tester.checkNullBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: ["ARCHS": arch]), runDestination: .iOS, persistent: true, serial: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs)

            // Finally, for good measure, do a multi-arch build.
            try await tester.checkBuild(parameters: BuildParameters(action: .build, configuration: "Debug", overrides: ["ARCHS": "arm64 arm64e"]), runDestination: .anyiOSDevice, persistent: true, serial: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.consumeTasksMatchingRuleTypes(["CreateBuildDirectory", "Copy", "Gate", "MkDir", "RegisterExecutionPolicyException", "SwiftMergeGeneratedHeaders", "WriteAuxiliaryFile", "Touch", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements", "ExtractAppIntentsMetadata", "AppIntentsSSUTraining", "ClangStatCache", "ProcessSDKImports"])
                results.checkTask(.matchRuleItem("ProcessInfoPlistFile")) { _ in }
                results.checkTask(.matchRuleItem("Ld"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-iphoneos/Framework.build/Objects-normal/arm64/Binary/Framework"), .matchRuleItem("arm64")) { _ in }
                results.checkTask(.matchRuleItem("Ld"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/aProject.build/Debug-iphoneos/Framework.build/Objects-normal/arm64e/Binary/Framework"), .matchRuleItem("arm64e")) { _ in }
                results.checkTask(.matchRuleItem("CreateUniversalBinary"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework/Framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateTAPI")) { _ in }
                results.checkTask(.matchRuleItem("CodeSign"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework")) { _ in }
                results.checkTask(.matchRuleItem("GenerateDSYMFile"), .matchRuleItem("\(tmpDirPath.str)/Test/aProject/build/Debug-iphoneos/Framework.framework.dSYM")) { _ in }
                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

}
