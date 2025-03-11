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

import SWBBuildSystem
import SWBCore
import SWBTaskExecution
import SWBTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct EmbeddedBinaryValidationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS, .iOS))
    func validateEmbeddedBinary() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("AppSource.m"),
                        TestFile("AppExSource.m"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration( "Debug", buildSettings: [
                        "COPY_PHASE_STRIP": "NO",
                        "DEBUG_INFORMATION_FORMAT": "dwarf",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "CODE_SIGN_IDENTITY": "-",
                        "CODE_SIGN_ENTITLEMENTS": "Entitlements.entitlements",
                        "SDKROOT": "iphoneos",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                        "SUPPORTS_MACCATALYST": "YES",
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "AppSource.m",
                            ]),
                            TestCopyFilesBuildPhase([
                                TestBuildFile("Extending.appex", codeSignOnCopy: true),
                            ], destinationSubfolder: .plugins, onlyForDeployment: false),
                        ],
                        dependencies: ["Extending"]
                    ),
                    TestStandardTarget(
                        "Extending",
                        type: .applicationExtension,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "AppExSource.m",
                            ]),
                        ]
                    ),
                ]
            )

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try tester.fs.write(Path(SRCROOT).join("Sources/AppSource.m"), contents: "int main() { return 0; }")
            try tester.fs.write(Path(SRCROOT).join("Sources/AppExSource.m"), contents: "int main() { return 0; }")
            try await tester.fs.writePlist(Path(SRCROOT).join("Entitlements.entitlements"), .plDict([:]))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true, signableTargets: ["AppTarget", "Extending"]) { results in
                results.checkTask(.matchTargetName("Extending"), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/Extending.appex")) { _ in }

                // For the appex, there should be a copy task, no signing task, and a validation task.
                results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/Extending.appex"), .matchRuleItem("\(SRCROOT)/build/Debug/Extending.appex")) { _ in }

                results.checkNoTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/Extending.appex"))

                results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("ValidateEmbeddedBinary"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app/Contents/PlugIns/Extending.appex")) { _ in }

                // There should be a codesign task for the app.
                results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug/AppTarget.app")) { _ in }

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macCatalyst, persistent: true, signableTargets: ["AppTarget", "Extending"]) { results in
                results.checkTask(.matchTargetName("Extending"), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Extending.appex")) { _ in }

                // For the appex, there should be a copy task, no signing task, and a validation task.
                results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/PlugIns/Extending.appex"), .matchRuleItem("\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/Extending.appex")) { _ in }

                results.checkNoTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/PlugIns/Extending.appex"))

                results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("ValidateEmbeddedBinary"), .matchRuleItem("\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app/Contents/PlugIns/Extending.appex")) { _ in }

                // There should be a codesign task for the app.
                results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug\(MacCatalystInfo.publicSDKBuiltProductsDirSuffix)/AppTarget.app")) { _ in }

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["AD_HOC_CODE_SIGNING_ALLOWED": "YES"]), runDestination: .iOS, persistent: true, signableTargets: ["AppTarget", "Extending"]) { results in
                results.checkTask(.matchTargetName("Extending"), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug-iphoneos/Extending.appex")) { _ in }

                // For the appex, there should be a copy task, no signing task, and a validation task.
                results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/PlugIns/Extending.appex"), .matchRuleItem("\(SRCROOT)/build/Debug-iphoneos/Extending.appex")) { _ in }

                results.checkNoTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/PlugIns/Extending.appex"))

                results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("ValidateEmbeddedBinary"), .matchRuleItem("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app/PlugIns/Extending.appex")) { _ in }

                // There should be a codesign task for the app.
                results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItem("\(SRCROOT)/build/Debug-iphoneos/AppTarget.app")) { _ in }

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }
        }
    }
}
