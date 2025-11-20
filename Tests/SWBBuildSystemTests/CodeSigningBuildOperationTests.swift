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
fileprivate struct CodeSigningBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func entitlementsModificationInvalidatesBuildDescription() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "SomeFiles",
                    path: "Sources",
                    children: [
                        TestFile("AppSource.m")
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "COPY_PHASE_STRIP": "NO",
                            "DEBUG_INFORMATION_FORMAT": "dwarf",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGN_IDENTITY": "-",
                            "CODE_SIGN_ENTITLEMENTS": "Entitlements.entitlements",
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]
                    )
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "AppSource.m"
                            ])
                        ],
                    )
                ]
            )

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try tester.fs.write(Path(SRCROOT).join("Sources/AppSource.m"), contents: "int main() { return 0; }")
            try await tester.fs.writePlist(Path(SRCROOT).join("Entitlements.entitlements"), .plDict([:]))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true, signableTargets: ["AppTarget"]) { results in
                results.checkNoDiagnostics()
            }

            // Modify the entitlements in between builds, but make no other changes which would invalidate the build description.
            try tester.fs.touch(Path(SRCROOT).join("Entitlements.entitlements"))

            // A subsequent build should succeed, and should NOT diagnose entitlements modification during the build.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true, signableTargets: ["AppTarget"]) { results in
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func entitlementsProcessingNotInvalidatedByUnrelatedSettingsChange() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "SomeFiles",
                    path: "Sources",
                    children: [
                        TestFile("AppSource.m")
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "COPY_PHASE_STRIP": "NO",
                            "DEBUG_INFORMATION_FORMAT": "dwarf",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "CODE_SIGN_IDENTITY": "-",
                            "CODE_SIGN_ENTITLEMENTS": "Entitlements.entitlements",
                            "SDKROOT": "macosx",
                            "SUPPORTED_PLATFORMS": "macosx",
                        ]
                    )
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase([
                                "AppSource.m"
                            ])
                        ],
                    )
                ]
            )

            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot.str

            try tester.fs.createDirectory(Path(SRCROOT).join("Sources"), recursive: true)
            try tester.fs.write(Path(SRCROOT).join("Sources/AppSource.m"), contents: "int main() { return 0; }")
            try await tester.fs.writePlist(Path(SRCROOT).join("Entitlements.entitlements"), .plDict([:]))

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, persistent: true, signableTargets: ["AppTarget"]) { results in
                results.checkNoDiagnostics()
            }

            // After changing irrelevant settings, we should not see CodeSign/ProcessProductPackaging tasks.
            // We may still see a task to process Info.plist since that supports build settings interpolation.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["Foo": "Bar"]), runDestination: .macOS, persistent: true, signableTargets: ["AppTarget"]) { results in
                results.checkNoTask(.matchRuleType("CodeSign"))
                results.checkNoTask(.matchRuleType("ProcessProductPackaging"))
                results.checkNoDiagnostics()
            }

            // Changing CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION should force them to re-run.
            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug", overrides: ["CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION": "YES"]), runDestination: .macOS, persistent: true, signableTargets: ["AppTarget"]) { results in
                results.checkTaskExists(.matchRuleType("CodeSign"))
                results.checkTasks(.matchRuleType("ProcessProductPackaging")) { #expect(!$0.isEmpty) }
                results.checkNoDiagnostics()
            }
        }
    }
}
