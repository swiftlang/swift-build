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

import SWBTaskExecution

@Suite
fileprivate struct AppleScriptTests: CoreBasedTests {
    /// Test that there is no build warning emitted for AppleScript-only targets with no sources.
    ///
    /// Code signing relies on knowing whether a Mach-O binary is actually being linked.
    @Test(.requireSDKs(.macOS))
    func automatorActionBuilding() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            children: [
                                TestFile("Foo.applescript"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "CODE_SIGN_IDENTITY": "-",
                                    "INFOPLIST_FILE": "Info.plist",
                                    "INSTALL_PATH": "$(HOME)/Library/Automator",
                                    "OTHER_OSAFLAGS": "-x -t 0 -c 0",
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "WRAPPER_EXTENSION": "action"
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "App",
                                type: .bundle,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "Foo.applescript",
                                    ]),
                                ]
                            )
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            // Write the Info.plist file.
            try await tester.fs.writePlist(SRCROOT.join("Info.plist"), .plDict([
                "CFBundleDevelopmentRegion": .plString("en"),
                "CFBundleExecutable": .plString("$(EXECUTABLE_NAME)")
            ]))

            // Write the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Foo.applescript")) { contents in
                contents <<< "script Foo\n"
                contents <<< "end script\n"
            }

            let provisioningInputs = ["App": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:]))]

            try await tester.checkBuild(parameters: BuildParameters(configuration: "Debug"), runDestination: .macOS, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                // Check that the delegate was passed build started and build ended events in the right place.
                results.checkCapstoneEvents()
                results.checkTask(.matchRuleType("CodeSign")) { _ in }
                results.checkNoDiagnostics()
            }
        }
    }
}
