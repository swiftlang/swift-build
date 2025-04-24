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

import SWBTestSupport

import SWBCore
import SWBProtocol
import SWBUtil
import SWBTaskExecution


@Suite
fileprivate struct UnitTestBuildOperationTests: CoreBasedTests {

    // MARK: Support methods

    /// Configure and perform a build with the given build operation tester and other parameters.
    private func performBuild(makeTester: (Path) async throws -> BuildOperationTester, parameters: BuildParameters, signableTargets: Set<String>? = nil, provisioningInputs: [String: ProvisioningTaskInputs]? = nil, userInfo: UserInfo? = nil, sourceLocation: SourceLocation = #_sourceLocation, check: (BuildOperationTester.BuildResults) -> Void) async throws {
        // Use a separate temporary directory for each build.
        try await withTemporaryDirectory { tmpDirPath in

            // Make the build operation tester.
            let tester = try await makeTester(tmpDirPath)
            if let userInfo {
                tester.userInfo = userInfo
            }

            // Resolve the signable target info.
            let signableTargets: Set<String> = {
                if let signableTargets { return signableTargets }
                if let provisioningInputs {
                    return Set(provisioningInputs.keys)
                }
                else {
                    return Set<String>()
                }
            }()
            let provisioningInputs = provisioningInputs ?? [:]

            // Perform the build and check the result.
            var overrides = parameters.overrides
            if parameters.action == .install && overrides["DSTROOT"] == nil {
                overrides["DSTROOT"] = tmpDirPath.join("dst").str
            }
            let parameters = BuildParameters(action: parameters.action, configuration: parameters.configuration, activeRunDestination: parameters.activeRunDestination, activeArchitecture: parameters.activeArchitecture, overrides: overrides)
            try await tester.checkBuild(parameters: parameters, runDestination: nil, persistent: true, signableTargets: signableTargets, signableTargetInputs: provisioningInputs, sourceLocation: sourceLocation) { results in
                check(results)
            }
        }
    }


    // MARK: Application-hosted test targets

    /// Test building an application and its test target - which uses TEST_HOST - for macOS.
    @Test(.requireSDKs(.macOS))
    func appHostedTestTarget_macOS() async throws {
        /// Creates and returns a `BuildOperationTester` for this test.
        func makeTester(_ tmpDir: Path) async throws -> BuildOperationTester {
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                // App sources
                                TestFile("main.c"),
                                TestFile("ClassOne.swift"),

                                // Test target sources
                                TestFile("TestOne.swift"),
                                TestFile("TestTwo.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CODE_SIGN_IDENTITY": "-",
                                    // Surprisingly, this appears to get set in projects rather than being implicitly used when copying the testing frameworks.
                                    "COPY_PHASE_STRIP": "NO",
                                    "SDKROOT": "macosx",
                                    "SWIFT_VERSION": swiftVersion,
                                ]),
                        ],
                        targets: [
                            TestAggregateTarget(
                                "All",
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                dependencies: ["UnitTestTargetOne", "UnitTestTargetTwo"]
                            ),
                            TestStandardTarget(
                                "UnitTestTargetOne",
                                type: .unitTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "INFOPLIST_FILE": "UnitTestTargetOne-Info.plist",
                                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                                            "BUNDLE_LOADER": "$(TEST_HOST)",
                                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "TestOne.swift",
                                    ]),
                                ],
                                dependencies: ["AppTarget"]
                            ),
                            TestStandardTarget(
                                "UnitTestTargetTwo",
                                type: .unitTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "INFOPLIST_FILE": "UnitTestTargetTwo-Info.plist",
                                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                                            "BUNDLE_LOADER": "$(TEST_HOST)",
                                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "TestTwo.swift",
                                    ]),
                                ],
                                dependencies: ["AppTarget"]
                            ),
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings:["INFOPLIST_FILE": "AppTarget-Info.plist"]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.c",
                                        "ClassOne.swift",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ClassOne.swift")) { stream in
                stream <<< "func foo(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestOne.swift")) { stream in
                stream <<< "func testFoo(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestTwo.swift")) { stream in
                stream <<< "func testBar(){}"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/AppTarget-Info.plist"), .plDict([:]))
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/UnitTestTargetOne-Info.plist"), .plDict([:]))
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/UnitTestTargetTwo-Info.plist"), .plDict([:]))

            return tester
        }

        let signableTargets: Set<String> = ["UnitTestTargetOne", "UnitTestTargetTwo", "AppTarget"]

        // Perform a debug build.
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .build, configuration: "Debug"), signableTargets: signableTargets) { results in
            // Look for the sign task for the app - there should be exactly one across all targets, since we no longer have the test targets re-sign the app.
            guard let appSignTask = results.getTask(.matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app")) else {
                return
            }

            // Look for the end gate tasks for the app target and the first test target.
            guard let appGateTask = results.getTask(.matchRuleType("Gate"), .matchRuleItemPattern(.and(.prefix("target-AppTarget-"), .suffix("-end")))) else {
                return
            }
            guard let testOneGateTask = results.getTask(.matchRuleType("Gate"), .matchRuleItemPattern(.and(.prefix("target-UnitTestTargetOne-"), .suffix("-end")))) else {
                return
            }
            guard let testTwoGateTask = results.getTask(.matchRuleType("Gate"), .matchRuleItemPattern(.and(.prefix("target-UnitTestTargetTwo-"), .suffix("-end")))) else {
                return
            }

            // Check that the app sign task runs after the test targets' end gate tasks.
            results.check(event: .taskHadEvent(testOneGateTask, event: .completed), precedes: .taskHadEvent(appSignTask, event: .started))
            results.check(event: .taskHadEvent(testTwoGateTask, event: .completed), precedes: .taskHadEvent(appSignTask, event: .started))

            // Get the commands to copy the test frameworks and make sure they all run before the app is re-signed.
            results.checkTasks(.matchTargetName("AppTarget"), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".framework"))) { copyFrameworksTasks in
                for copyFrameworkTask in copyFrameworksTasks {
                    results.check(event: .taskHadEvent(copyFrameworkTask, event: .completed), precedes: .taskHadEvent(appSignTask, event: .started))
                    results.check(event: .taskHadEvent(copyFrameworkTask, event: .completed), precedes: .taskHadEvent(appGateTask, event: .started))
                }
            }

            // Check that the app target's end task runs after the earlier tasks.
            results.check(event: .taskHadEvent(testOneGateTask, event: .completed), precedes: .taskHadEvent(appGateTask, event: .started))
            results.check(event: .taskHadEvent(testTwoGateTask, event: .completed), precedes: .taskHadEvent(appGateTask, event: .started))
            results.check(event: .taskHadEvent(appSignTask, event: .completed), precedes: .taskHadEvent(appGateTask, event: .started))
        }

        // Perform an install build.
        guard let userInfo = BuildOperationTester.userInfoForCurrentUser() else {
            return
        }
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .install, configuration: "Debug"), signableTargets: signableTargets, userInfo: userInfo) { results in
            // Make sure the app target is signing its product.
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign")) { _ in }
            // But note that we *don't* re-sign the app target when doing an install build, because the test targets' products don't get embedded in it.
            results.checkNoTask(.matchTargetName("UnitTestTargetOne"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app"))
            results.checkNoTask(.matchTargetName("UnitTestTargetTwo"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app"))
        }
    }

    /// Test building an application and its test target - which uses TEST_HOST - for iOS for both the device and the simulator.
    @Test(.requireSDKs(.iOS))
    func appHostedTestTarget_iOS() async throws {
        /// Creates and returns a `BuildOperationTester` for this test.
        func makeTester(_ tmpDir: Path) async throws -> BuildOperationTester {
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                // App sources
                                TestFile("main.c"),
                                TestFile("ClassOne.swift"),

                                // Test target sources
                                TestFile("TestOne.swift"),
                                TestFile("TestTwo.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CODE_SIGN_IDENTITY": "-",
                                    "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                    // Surprisingly, this appears to get set in projects rather than being implicitly used when copying the testing frameworks.
                                    "COPY_PHASE_STRIP": "NO",
                                    "SDKROOT": "iphoneos",
                                    "SWIFT_VERSION": swiftVersion,
                                ]),
                        ],
                        targets: [
                            TestAggregateTarget(
                                "All",
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                dependencies: ["UnitTestTargetOne", "UnitTestTargetTwo"]
                            ),
                            TestStandardTarget(
                                "UnitTestTargetOne",
                                type: .unitTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "INFOPLIST_FILE": "UnitTestTargetOne-Info.plist",
                                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/AppTarget",
                                            "BUNDLE_LOADER": "$(TEST_HOST)",
                                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "TestOne.swift",
                                    ]),
                                ],
                                dependencies: ["AppTarget"]
                            ),
                            TestStandardTarget(
                                "UnitTestTargetTwo",
                                type: .unitTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "INFOPLIST_FILE": "UnitTestTargetTwo-Info.plist",
                                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/AppTarget",
                                            "BUNDLE_LOADER": "$(TEST_HOST)",
                                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "TestTwo.swift",
                                    ]),
                                ],
                                dependencies: ["AppTarget"]
                            ),
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings:["INFOPLIST_FILE": "AppTarget-Info.plist"]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.c",
                                        "ClassOne.swift",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ClassOne.swift")) { stream in
                stream <<< "func foo(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestOne.swift")) { stream in
                stream <<< "func testFoo(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestTwo.swift")) { stream in
                stream <<< "func testBar(){}"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/AppTarget-Info.plist"), .plDict([:]))
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/UnitTestTargetOne-Info.plist"), .plDict([:]))
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/UnitTestTargetTwo-Info.plist"), .plDict([:]))

            return tester
        }

        // Set up signing inputs.  When building for the device, entitlements are required for the app.
        let appIdentifierPrefix = "F154D0C"
        let teamIdentifierPrefix = appIdentifierPrefix
        let appIdentifier = "\(appIdentifierPrefix).com.apple.dt.AppTarget"
        let appMergedEntitlements: PropertyListItem = [
            "application-identifier": appIdentifier,
            "com.apple.developer.team-identifier": teamIdentifierPrefix,
            "get-task-allow": 1,
            "keychain-access-groups": [
                appIdentifier
            ],
        ]
        let provisioningInputs = [
            "UnitTestTargetOne": ProvisioningTaskInputs(identityHash: "-", identityName: "Ad-Hoc Signing"),
            "UnitTestTargetTwo": ProvisioningTaskInputs(identityHash: "-", identityName: "Ad-Hoc Signing"),
            "AppTarget": ProvisioningTaskInputs(identityHash: "-", identityName: "Ad-Hoc Signing", signedEntitlements: appMergedEntitlements, simulatedEntitlements: [:]),
        ]

        // Perform a debug build for the device.
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .iOS), provisioningInputs: provisioningInputs) { results in
            // Look for the sign task for the app.
            guard let appSignTask = results.getTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app")) else {
                return
            }

            // Look for the dSYM gate tasks for the app target and the first test target.
            guard let appDsymGateTask = results.getTask(.matchRuleType("Gate"), .matchRuleItemPattern(.contains("AppTarget.app.dSYM"))) else {
                return
            }
            guard let testOneDsymGateTask = results.getTask(.matchRuleType("Gate"), .matchRuleItemPattern(.contains("UnitTestTargetOne.xctest.dSYM"))) else {
                return
            }
            guard let testTwoDsymGateTask = results.getTask(.matchRuleType("Gate"), .matchRuleItemPattern(.contains("UnitTestTargetTwo.xctest.dSYM"))) else {
                return
            }

            // Make sure the app sign task runs after the the dSYM tasks.
            results.check(event: .taskHadEvent(appDsymGateTask, event: .completed), precedes: .taskHadEvent(appSignTask, event: .started))
            results.check(event: .taskHadEvent(testOneDsymGateTask, event: .completed), precedes: .taskHadEvent(appSignTask, event: .started))
            results.check(event: .taskHadEvent(testTwoDsymGateTask, event: .completed), precedes: .taskHadEvent(appSignTask, event: .started))

            // Get the commands to copy the test frameworks and make sure they all run before the app is signed.
            results.checkTasks(.matchTargetName("UnitTestTargetTwo"), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".framework"))) { copyFrameworksTasks in
                for copyFrameworkTask in copyFrameworksTasks {
                    results.check(event: .taskHadEvent(copyFrameworkTask, event: .completed), precedes: .taskHadEvent(appSignTask, event: .started))
                    results.check(event: .taskHadEvent(copyFrameworkTask, event: .completed), precedes: .taskHadEvent(appDsymGateTask, event: .started))
                }
            }
        }

        // Perform an install build for the device.
        guard let userInfo = BuildOperationTester.userInfoForCurrentUser() else {
            return
        }
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .install, configuration: "Debug", activeRunDestination: .iOS), provisioningInputs: provisioningInputs, userInfo: userInfo) { results in
            // Make sure the app target is signing its product.
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign")) { _ in }
            // But note that we *don't* re-sign the app target when doing an install build, because the test targets' products don't get embedded in it.
            results.checkNoTask(.matchTargetName("UnitTestTargetOne"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app"))
            results.checkNoTask(.matchTargetName("UnitTestTargetTwo"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app"))
        }

        // Perform a debug build for the simulator.
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .iOSSimulator), provisioningInputs: provisioningInputs) { results in
            // Make sure the app target is signing its product.
            results.checkTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign")) { _ in }
            // But note that we *don't* re-sign the app target when building for the simulator (which is not a 'deployment platform').
            results.checkNoTask(.matchTargetName("UnitTestTargetOne"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app"))
            results.checkNoTask(.matchTargetName("UnitTestTargetTwo"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app"))
        }
    }

    /// This test is to exercise the changes for <rdar://problem/59162343> App not re-signed on resource update causing signature to break
    @Test(.requireSDKs(.macOS))
    func incrementalCodesignForCopyFileChangesWithAppHostedTests() async throws {
        let core = try await getCore()
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                // App sources
                                TestFile("App.swift"),
                                TestFile("Resource.txt"),
                                TestFile("AppTarget-Info.plist"),

                                // Test target sources
                                TestFile("TestOne.swift"),
                                TestFile("ResourceOne.txt"),
                                TestFile("UnitTestTargetOne-Info.plist"),
                                TestFile("TestTwo.swift"),
                                TestFile("ResourceTwo.txt"),
                                TestFile("UnitTestTargetTwo-Info.plist"),

                                // Lib sources
                                TestFile("Lib.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CODE_SIGN_IDENTITY": "-",
                                    "CODESIGN": "/usr/bin/true",
                                    "COPY_PHASE_STRIP": "NO",
                                    "SDKROOT": "macosx",
                                    "SWIFT_VERSION": swiftVersion,
                                    "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
                                ]),
                        ],
                        targets: [
                            TestAggregateTarget(
                                "All",
                                buildConfigurations: [TestBuildConfiguration("Debug")],
                                dependencies: ["UnitTestTargetOne", "UnitTestTargetTwo"]
                            ),
                            TestStandardTarget(
                                "UnitTestTargetOne",
                                type: .unitTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "INFOPLIST_FILE": "UnitTestTargetOne-Info.plist",
                                            "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
                                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                                            "BUNDLE_LOADER": "$(TEST_HOST)",
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "TestOne.swift",
                                    ]),
                                    TestCopyFilesBuildPhase(["ResourceOne.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                ],
                                dependencies: ["AppTarget"]
                            ),
                            TestStandardTarget(
                                "UnitTestTargetTwo",
                                type: .unitTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "INFOPLIST_FILE": "UnitTestTargetTwo-Info.plist",
                                            "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
                                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                                            "BUNDLE_LOADER": "$(TEST_HOST)",
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "TestTwo.swift",
                                    ]),
                                    TestCopyFilesBuildPhase([TestBuildFile("Lib.framework", codeSignOnCopy: true)], destinationSubfolder: .frameworks),
                                    TestCopyFilesBuildPhase(["ResourceTwo.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestShellScriptBuildPhase(name: "OutputTwo", shellPath: "/bin/bash", originalObjectID: "OutputTwo", contents: "touch $SCRIPT_OUTPUT_FILE_0", inputs: [], outputs: ["$(TARGET_BUILD_DIR)/nocycle.txt"])
                                ],
                                dependencies: ["AppTarget"]
                            ),
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "AppTarget-Info.plist"]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "App.swift",
                                    ]),
                                    TestFrameworksBuildPhase([]),
                                    TestCopyFilesBuildPhase(["Resource.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                                    TestShellScriptBuildPhase(name: "Output", shellPath: "/bin/bash", originalObjectID: "Output", contents: "echo $SCRIPT_OUTPUT_FILE_0", inputs: [], outputs: ["$(TARGET_BUILD_DIR)/nocycle.txt"])
                                ]
                            ),
                            TestStandardTarget(
                                "Lib",
                                type: .framework,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings: ["INFOPLIST_FILE": "Lib-Info.plist"]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "Lib.swift",
                                    ]),
                                ]
                            ),
                        ])])

            let tester = try await BuildOperationTester(core, testWorkspace, simulated: false)

            let SRCROOT = testWorkspace.sourceRoot.str
            let buildDirectory = testWorkspace.sourceRoot.join("aProject/build").str

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/App.swift")) { stream in
                stream <<<
                """
                import Cocoa
                @main
                class AppDelegate: NSObject, NSApplicationDelegate {}
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestOne.swift")) { stream in
                stream <<< "func test1() {} \n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestTwo.swift")) { stream in
                stream <<< "func test2() {} \n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Lib.swift")) { stream in
                stream <<<
                """
                func mylib() -> Int { return 12 }
                """
            }

            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Resource.txt")) { stream in
                stream <<< "hello\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ResourceOne.txt")) { stream in
                stream <<< "sweet\n"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ResourceTwo.txt")) { stream in
                stream <<< "world\n"
            }

            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/AppTarget-Info.plist"), .plDict(["key": .plString("value")]))
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/UnitTestTargetOne-Info.plist"), .plDict(["key": .plString("value")]))
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/UnitTestTargetTwo-Info.plist"), .plDict(["key": .plString("value")]))

            let excludedTasks: Set<String> = ["CreateBuildDirectory", "MkDir", "WriteAuxiliaryFile", "ProcessInfoPlistFile", "Validate", "RegisterWithLaunchServices", "Touch", "Gate", "RegisterExecutionPolicyException", "ClangStatCache"]

            let signableTargets: Set<String> = ["AppTarget", "UnitTestTargetOne", "UnitTestTargetTwo"]

            let params = BuildParameters(action: .build, configuration: "Debug", overrides: [
                // NOTE: THIS IS THE IMPORTANT SETTING! Ensure that opt-in is on, regardless of the default value.
                "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING": "YES",
                "ENABLE_ADDITIONAL_CODESIGN_INPUT_TRACKING_FOR_SCRIPT_OUTPUTS": "YES",
            ])

            try await tester.checkBuild(parameters: params, runDestination: .macOS, schemeCommand: .test, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                results.checkTasks { tasks in
                    // The number of tasks and the details of the tasks really does not matter.
                    #expect(tasks.count > 0)
                }

                results.checkNoDiagnostics()
            }

            // Validate a null build.
            try await tester.checkBuild(parameters: params, runDestination: .macOS, schemeCommand: .test, persistent: true, signableTargets: signableTargets) { results in
                // Check that no tasks ran.
                if SWBFeatureFlag.performOwnershipAnalysis.value {
                    results.consumeTasksMatchingRuleTypes(["ClangStatCache"])
                    results.checkNoTask()
                } else {
                    // FIXME: <rdar://problem/72202200> We're working around this issue by expecting a few tasks to run that shouldn't.
                    results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/AppTarget.app"])) { _ in }
                    results.checkTask(.matchRule(["Validate", "\(buildDirectory)/Debug/AppTarget.app"])) { _ in }
                    results.checkTask(.matchRule(["RegisterWithLaunchServices", "\(buildDirectory)/Debug/AppTarget.app"])) { _ in }
                }
            }

            // Test that updating the resource properly copies the file in place and performs a new codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/Resource.txt")) { stream in
                stream <<< "goodbye\n"
            }
            try await tester.checkBuild(parameters: params, runDestination: .macOS, schemeCommand: .test, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/AppTarget.app/Contents/Resources/Resource.txt", "\(SRCROOT)/aProject/Resource.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/AppTarget.app"])) { _ in }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }

            // Test that updating the resource from a test bundle properly copies the file in place and performs a new codesign.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ResourceTwo.txt")) { stream in
                stream <<< "yeah baby!\n"
            }
            try await tester.checkBuild(parameters: params, runDestination: .macOS, schemeCommand: .test, persistent: true, signableTargets: signableTargets) { results in
                results.consumeTasksMatchingRuleTypes(excludedTasks)

                results.checkTask(.matchRule(["Copy", "\(buildDirectory)/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetTwo.xctest/Contents/Resources/ResourceTwo.txt", "\(SRCROOT)/aProject/ResourceTwo.txt"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/AppTarget.app/Contents/PlugIns/UnitTestTargetTwo.xctest"])) { _ in }
                results.checkTask(.matchRule(["CodeSign", "\(buildDirectory)/Debug/AppTarget.app"])) { _ in }

                results.checkNoTask()
                results.checkNoDiagnostics()
            }
        }
    }

    /// Test that rebuilds of an app-hosted test target don't cause the code sign task to fail when the test target fails to build.
    ///
    /// The strategy for this test is:
    /// - Build the app - which succeeds - and then test - which fails because of a syntax error.
    /// - Fix the build failure in the test, *but also* touch a source file in the app to force it to rebuild.
    /// - On rebuild, everything should succeed.
    ///
    /// Prior to the fix for rdar://problem/47322098, the rebuild would fail because it would rebuild the app, but signing the app would fail because of the incomplete, unsigned test bundle embedded in it. After the first, we don't try to sign the app until the test bundle rebuilds, so there's no failure.
    @Test(.requireSDKs(.macOS), .bug("rdar://72202535"))
    func appHostedTestTargetRebuild() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                // App sources
                                TestFile("main.c"),
                                TestFile("ClassOne.swift"),

                                // Test target sources
                                TestFile("TestOne.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CODE_SIGN_IDENTITY": "-",
                                    // Surprisingly, this appears to get set in projects rather than being implicitly used when copying the testing frameworks.
                                    "COPY_PHASE_STRIP": "NO",
                                    "SDKROOT": "macosx",
                                    "SWIFT_VERSION": swiftVersion,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "UnitTestTarget",
                                type: .unitTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "INFOPLIST_FILE": "UnitTestTarget-Info.plist",
                                            "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/AppTarget.app/Contents/MacOS/AppTarget",
                                            "BUNDLE_LOADER": "$(TEST_HOST)",
                                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "TestOne.swift",
                                    ]),
                                ],
                                dependencies: ["AppTarget"]
                            ),
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings:[
                                        "INFOPLIST_FILE": "AppTarget-Info.plist",
                                    ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.c",
                                        "ClassOne.swift",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ClassOne.swift")) { stream in
                stream <<< "func foo(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestOne.swift")) { stream in
                // This file contains a syntax error.
                stream <<< "func testFoo(){ foo }"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/AppTarget-Info.plist"), .plDict([:]))
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/UnitTestTarget-Info.plist"), .plDict([:]))

            let buildParameters = BuildParameters(action: .build, configuration: "Debug")
            let signableTargets: Set<String> = ["UnitTestTarget", "AppTarget"]

            // Perform the initial build, which should fail due to the syntax error in the test target's source file.
            try await tester.checkBuild(parameters: buildParameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                withKnownIssue("fails due to rdar://72202535") {
                    // Check that the app target's compile task ran.  (The link command may or may not run, so we don't check it here.)
                    if let task = results.getTask(.matchTargetName("AppTarget"), .matchRuleType("SwiftDriver")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }

                    // Check that the build failed because of compilation of the error in the test source file.
                    if let task = results.getTask(.matchTargetName("UnitTestTarget"), .matchRuleType("SwiftCompile")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                        results.check(contains: .taskHadEvent(task, event: .exit(.exit(exitStatus: .exit(256), metrics: nil))))
                    }

                    // Check that tasks of the failing compile task didn't run.
                    if let task = results.getTask(.matchTargetName("UnitTestTarget"), .matchRuleType("Ld")) {
                        results.check(notContains: .taskHadEvent(task, event: .started))
                    }
                    if let task = results.getTask(.matchTargetName("UnitTestTarget"), .matchRuleType("CodeSign")) {
                        results.check(notContains: .taskHadEvent(task, event: .started))
                    }
                    if let task = results.getTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app")) {
                        results.check(notContains: .taskHadEvent(task, event: .started))
                    }

                    // Check expected errors.
                    results.checkErrors([
                        .contains("cannot find \'foo\' in scope"),
                        .prefix("Command SwiftDriver failed."),
                    ])
                }
            }

            // Fix the syntax error, but also touch a source file in the app to make sure it rebuilds.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ClassOne.swift")) { stream in
                stream <<< "func foo(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestOne.swift")) { stream in
                stream <<< "func testFoo(){}"
            }
            try await tester.checkBuild(parameters: buildParameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                withKnownIssue("fails due to rdar://72202535") {
                    // Check that the app target's compile and link tasks ran.
                    if let task = results.getTask(.matchTargetName("AppTarget"), .matchRuleType("SwiftDriver")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }
                    if let task = results.getTask(.matchTargetName("AppTarget"), .matchRuleType("Ld")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }

                    // Check that the test target's compile and link tasks ran.
                    if let task = results.getTask(.matchTargetName("UnitTestTarget"), .matchRuleType("SwiftDriver")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }
                    if let task = results.getTask(.matchTargetName("UnitTestTarget"), .matchRuleType("Ld")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }

                    // Check that the test and app's code sign tasks both ran.
                    if let task = results.getTask(.matchTargetName("UnitTestTarget"), .matchRuleType("CodeSign")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }
                    if let task = results.getTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }

                    // Check that there are no errors.
                    results.checkNoDiagnostics()
                }
            }

            // For good measure, touch a file in the test target again to make sure the app gets re-signed.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestOne.swift")) { stream in
                stream <<< "func testFoo(){  }"
            }
            try await tester.checkBuild(parameters: buildParameters, runDestination: .macOS, persistent: true, signableTargets: signableTargets) { results in
                withKnownIssue("fails due to rdar://72202535") {
                    // Check that the app target's compile and link tasks did not run.
                    if let task = results.getTask(.matchTargetName("AppTarget"), .matchRuleType("SwiftDriver")) {
                        results.check(notContains: .taskHadEvent(task, event: .started))
                    }
                    if let task = results.getTask(.matchTargetName("AppTarget"), .matchRuleType("Ld")) {
                        results.check(notContains: .taskHadEvent(task, event: .started))
                    }
                    
                    // Check that the test target's compile and link tasks ran.
                    if let task = results.getTask(.matchTargetName("UnitTestTarget"), .matchRuleType("SwiftDriver")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }
                    if let task = results.getTask(.matchTargetName("UnitTestTarget"), .matchRuleType("Ld")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }
                    
                    // Check that the test and app's code sign tasks both ran.
                    if let task = results.getTask(.matchTargetName("UnitTestTarget"), .matchRuleType("CodeSign")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }
                    if let task = results.getTask(.matchTargetName("AppTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("AppTarget.app")) {
                        results.check(contains: .taskHadEvent(task, event: .started))
                    }
                    
                    // Check that there are no errors.
                    results.checkNoDiagnostics()
                }
            }
        }
    }


    // MARK: UI test targets

    /// Test building an application and a UI test target for macOS.
    @Test(.requireSDKs(.macOS))
    func uITestTarget_macOS() async throws {
        // Creates and returns a tester for a given test.
        func makeTester(_ tmpDir: Path) async throws -> BuildOperationTester {
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                // App sources
                                TestFile("main.c"),
                                TestFile("ClassOne.swift"),

                                // Test target sources
                                TestFile("TestOne.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CODE_SIGN_IDENTITY": "-",
                                    // Surprisingly, this appears to get set in projects rather than being implicitly used when copying the testing frameworks.
                                    "COPY_PHASE_STRIP": "NO",
                                    "SDKROOT": "macosx",
                                    "SWIFT_VERSION": swiftVersion,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "UITestTarget",
                                type: .uiTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "PRODUCT_NAME": "UITestTarget-1",
                                            "INFOPLIST_FILE": "UITestTarget-Info.plist",
                                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                                            "TEST_TARGET_NAME": "AppTarget",
                                            "PRODUCT_BUNDLE_IDENTIFIER": "com.apple.dt.UITestTarget-1",
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "TestOne.swift",
                                    ]),
                                ],
                                dependencies: ["AppTarget"]
                            ),
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings:["INFOPLIST_FILE": "AppTarget-Info.plist"]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.c",
                                        "ClassOne.swift",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ClassOne.swift")) { stream in
                stream <<< "func foo(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestOne.swift")) { stream in
                stream <<< "func testFoo(){}"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/AppTarget-Info.plist"), .plDict([:]))
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/UITestTarget-Info.plist"), .plDict([:]))

            return tester
        }

        // Set up signing inputs.
        let entitlements: PropertyListItem = [
            "com.apple.application-identifier": "59GAB85EFG.com.apple.dt.UITestTarget-1",
            "com.apple.security.app-sandbox": 1,
            "com.apple.security.network.client": 1,
            // This is a truncated dictionary of what gets actually used in a UI test target's entitlements.
        ]
        let provisioningInputs = [
            "UITestTarget": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: entitlements, simulatedEntitlements: [:]),
            "AppTarget": ProvisioningTaskInputs(identityHash: "-"),
        ]

        // Perform a debug build.
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .build, configuration: "Debug"), provisioningInputs: provisioningInputs) { results in
            results.checkNoDiagnostics()

            // Look for the sign tasks in the test target, one for the test bundle and one for the runner.
            guard let xctestBundleSignTask = results.getTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget-1.xctest")) else {
                return
            }
            guard let runnerSignTask = results.getTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget-1-Runner.app")) else {
                return
            }

            // Make sure the runner sign task runs after the test bundle sign task.
            results.check(event: .taskHadEvent(xctestBundleSignTask, event: .completed), precedes: .taskHadEvent(runnerSignTask, event: .started))

            // Get the commands to copy the test frameworks and make sure they all run before the runner app is signed.
            results.checkTasks(.matchTargetName("UITestTarget"), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".framework"))) { copyFrameworksTasks in
                for copyFrameworkTask in copyFrameworksTasks {
                    results.check(event: .taskHadEvent(copyFrameworkTask, event: .completed), precedes: .taskHadEvent(runnerSignTask, event: .started))
                }
            }

            // Check that the runner app's Info.plist had values for certain keys preprocessed to the desired value.
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("CopyPlistFile"), .matchRuleItemPattern(.suffix("UITestTarget-1-Runner.app/Contents/Info.plist"))) { task in
                if task.ruleInfo.count > 1 {
                    let infoPlistPath = Path(task.ruleInfo[1])
                    if results.fs.exists(infoPlistPath) {
                        if let infoPlist = try? PropertyList.fromPath(infoPlistPath, fs: results.fs), let infoDict = infoPlist.dictValue {
                            #expect(infoDict["CFBundleExecutable"]?.stringValue == "UITestTarget-1-Runner")
                            #expect(infoDict["CFBundleIdentifier"]?.stringValue == "com.apple.dt.UITestTarget-1.xctrunner")
                            #expect(infoDict["CFBundleName"]?.stringValue == "UITestTarget-1-Runner")
                            #expect(infoDict["UIDeviceFamily"] == nil)
                        }
                        else {
                            Issue.record("Could not read Info.plist for XCTRunner.app at path: \(infoPlistPath.str)")
                        }
                    }
                    else {
                        Issue.record("Info.plist for XCTRunner.app does not exist at path: \(infoPlistPath.str)")
                    }
                }
                else {
                    Issue.record("Could not get path to Info.plist for XCTRunner.app from rule: \(task.ruleInfo)")
                }
            }
        }

        // Perform an install build.
        guard let userInfo = BuildOperationTester.userInfoForCurrentUser() else {
            return
        }
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .install, configuration: "Debug"), provisioningInputs: provisioningInputs, userInfo: userInfo) { results in
            results.checkNoDiagnostics()

            // Make sure we have the expected postprocessing tasks for the runner.
            // FIXME: I understand why SetOwner and SetMode are performed on the runner, but shouldn't Strip be performed on the .xctest bundle's binary?
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("Strip")) { task in
                results.check(contains: .taskHadEvent(task, event: .completed))
            }
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("SetOwner")) { task in
                results.check(contains: .taskHadEvent(task, event: .completed))
            }
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("SetMode")) { task in
                results.check(contains: .taskHadEvent(task, event: .completed))
            }

            // Look for the sign tasks in the test target, one for the test bundle and one for the runner.
            guard let xctestBundleSignTask = results.getTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget-1.xctest")) else {
                return
            }
            guard let runnerSignTask = results.getTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget-1-Runner.app")) else {
                return
            }

            // Make sure the runner sign task runs after the test bundle sign task.
            results.check(event: .taskHadEvent(xctestBundleSignTask, event: .completed), precedes: .taskHadEvent(runnerSignTask, event: .started))

            // Get the commands to copy the test frameworks and make sure they all run before the runner app is signed.
            results.checkTasks(.matchTargetName("UITestTarget"), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".framework"))) { copyFrameworksTasks in
                for copyFrameworkTask in copyFrameworksTasks {
                    results.check(event: .taskHadEvent(copyFrameworkTask, event: .completed), precedes: .taskHadEvent(runnerSignTask, event: .started))
                }
            }
        }
    }

    /// Test building an application and a UI test target for iOS for both the device and the simulator.
    @Test(.requireSDKs(.iOS))
    func uITestTarget_iOS() async throws {
        // Creates and returns a tester for a given test.
        func makeTester(_ tmpDir: Path) async throws -> BuildOperationTester {
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDir.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "SomeFiles",
                            children: [
                                // App sources
                                TestFile("main.c"),
                                TestFile("ClassOne.swift"),

                                // Test target sources
                                TestFile("TestOne.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CODE_SIGN_IDENTITY": "-",
                                    "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                    // Surprisingly, this appears to get set in projects rather than being implicitly used when copying the testing frameworks.
                                    "COPY_PHASE_STRIP": "NO",
                                    "SDKROOT": "iphoneos",
                                    "SWIFT_VERSION": swiftVersion,
                                ]),
                        ],
                        targets: [
                            TestStandardTarget(
                                "UITestTarget",
                                type: .uiTest,
                                buildConfigurations: [
                                    TestBuildConfiguration(
                                        "Debug",
                                        buildSettings: [
                                            "INFOPLIST_FILE": "UITestTarget-Info.plist",
                                            "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
                                            "TEST_TARGET_NAME": "AppTarget",
                                            "PRODUCT_BUNDLE_IDENTIFIER": "com.apple.dt.UITestTarget",
                                        ]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "TestOne.swift",
                                    ]),
                                ],
                                dependencies: ["AppTarget"]
                            ),
                            TestStandardTarget(
                                "AppTarget",
                                type: .application,
                                buildConfigurations: [
                                    TestBuildConfiguration("Debug", buildSettings:["INFOPLIST_FILE": "AppTarget-Info.plist"]),
                                ],
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "main.c",
                                        "ClassOne.swift",
                                    ]),
                                ]
                            ),
                        ])
                ])
            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

            // Write the file data.
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/main.c")) { stream in
                stream <<< "int main(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/ClassOne.swift")) { stream in
                stream <<< "func foo(){}"
            }
            try await tester.fs.writeFileContents(testWorkspace.sourceRoot.join("aProject/TestOne.swift")) { stream in
                stream <<< "func testFoo(){}"
            }
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/AppTarget-Info.plist"), .plDict([:]))
            try await tester.fs.writePlist(testWorkspace.sourceRoot.join("aProject/UITestTarget-Info.plist"), .plDict([:]))

            return tester
        }

        // Set up signing inputs.  When building for the device, entitlements are required for the app.
        let appIdentifierPrefix = "F154D0C"
        let teamIdentifierPrefix = appIdentifierPrefix
        let appIdentifier = "\(appIdentifierPrefix).com.apple.dt.AppTarget"
        let appMergedEntitlements: PropertyListItem = [
            "application-identifier": appIdentifier,
            "com.apple.developer.team-identifier": teamIdentifierPrefix,
            "get-task-allow": 1,
            "keychain-access-groups": [
                appIdentifier
            ],
        ]
        let testEntitlements: PropertyListItem = [
            "com.apple.application-identifier": "59GAB85EFG.com.apple.dt.UITestTarget",
            "com.apple.security.app-sandbox": 1,
            "com.apple.security.network.client": 1,
            // This is a truncated dictionary of what gets actually used in a UI test target's entitlements.
        ]
        let provisioningInputs = [
            "UITestTarget": ProvisioningTaskInputs(identityHash: "-", identityName: "Ad-Hoc Signing", signedEntitlements: testEntitlements, simulatedEntitlements: [:]),
            "AppTarget": ProvisioningTaskInputs(identityHash: "-", identityName: "Ad-Hoc Signing", signedEntitlements: appMergedEntitlements, simulatedEntitlements: [:]),
        ]

        // Perform a debug build for the device.
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .iOS), provisioningInputs: provisioningInputs) { results in
            results.checkNoDiagnostics()

            // Look for the sign tasks in the test target, one for the test bundle and one for the runner.
            guard let xctestBundleSignTask = results.getTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget.xctest")) else {
                return
            }
            guard let runnerSignTask = results.getTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget-Runner.app")) else {
                return
            }

            // Make sure the runner sign task runs after the test bundle sign task.
            results.check(event: .taskHadEvent(xctestBundleSignTask, event: .completed), precedes: .taskHadEvent(runnerSignTask, event: .started))

            // Get the commands to copy the test frameworks and make sure they all run before the runner app is signed.
            results.checkTasks(.matchTargetName("UITestTarget"), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".framework"))) { copyFrameworksTasks in
                for copyFrameworkTask in copyFrameworksTasks {
                    results.check(event: .taskHadEvent(copyFrameworkTask, event: .completed), precedes: .taskHadEvent(runnerSignTask, event: .started))
                }
            }

            // Check that the runner app's Info.plist had values for certain keys preprocessed to the desired value.
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("CopyPlistFile"), .matchRuleItemPattern(.suffix("UITestTarget-Runner.app/Info.plist"))) { task in
                if task.ruleInfo.count > 1 {
                    let infoPlistPath = Path(task.ruleInfo[1])
                    if results.fs.exists(infoPlistPath) {
                        if let infoPlist = try? PropertyList.fromPath(infoPlistPath, fs: results.fs), let infoDict = infoPlist.dictValue {
                            #expect(infoDict["CFBundleExecutable"]?.stringValue == "UITestTarget-Runner")
                            #expect(infoDict["CFBundleIdentifier"]?.stringValue == "com.apple.dt.UITestTarget.xctrunner")
                            #expect(infoDict["CFBundleName"]?.stringValue == "UITestTarget-Runner")
                            #expect(infoDict["UIDeviceFamily"]?.intArrayValue == [1])
                        }
                        else {
                            Issue.record("Could not read Info.plist for XCTRunner.app at path: \(infoPlistPath.str)")
                        }
                    }
                    else {
                        Issue.record("Info.plist for XCTRunner.app does not exist at path: \(infoPlistPath.str)")
                    }
                }
                else {
                    Issue.record("Could not get path to Info.plist for XCTRunner.app from rule: \(task.ruleInfo)")
                }
            }
        }

        // Perform an install build for the device.
        guard let userInfo = BuildOperationTester.userInfoForCurrentUser() else {
            return
        }
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .install, configuration: "Debug", activeRunDestination: .iOS), provisioningInputs: provisioningInputs, userInfo: userInfo) { results in
            results.checkNoDiagnostics()

            // Make sure we have the expected postprocessing tasks for the runner.
            // FIXME: I understand why SetOwner and SetMode are performed on the runner, but shouldn't Strip be performed on the .xctest bundle's binary?
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("Strip")) { task in
                results.check(contains: .taskHadEvent(task, event: .completed))
            }
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("SetOwner")) { task in
                results.check(contains: .taskHadEvent(task, event: .completed))
            }
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("SetMode")) { task in
                results.check(contains: .taskHadEvent(task, event: .completed))
            }

            // Look for the sign tasks in the test target, one for the test bundle and one for the runner.
            guard let xctestBundleSignTask = results.getTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget.xctest")) else {
                return
            }
            guard let runnerSignTask = results.getTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget-Runner.app")) else {
                return
            }

            // Make sure the runner sign task runs after the test bundle sign task.
            results.check(event: .taskHadEvent(xctestBundleSignTask, event: .completed), precedes: .taskHadEvent(runnerSignTask, event: .started))

            // Get the commands to copy the test frameworks and make sure they all run before the runner app is signed.
            results.checkTasks(.matchTargetName("UITestTarget"), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix(".framework"))) { copyFrameworksTasks in
                for copyFrameworkTask in copyFrameworksTasks {
                    results.check(event: .taskHadEvent(copyFrameworkTask, event: .completed), precedes: .taskHadEvent(runnerSignTask, event: .started))
                }
            }
        }

        // Perform a debug build for the simulator.
        try await performBuild(makeTester: makeTester, parameters: BuildParameters(action: .build, configuration: "Debug", activeRunDestination: .iOSSimulator), provisioningInputs: provisioningInputs) { results in
            results.checkNoDiagnostics()

            // Make sure the test target is signing its product.
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget.xctest")) { _ in }
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("CodeSign"), .matchRuleItemBasename("UITestTarget-Runner.app")) { _ in }

            // Check that the runner app's Info.plist had values for certain keys preprocessed to the desired value.
            results.checkTask(.matchTargetName("UITestTarget"), .matchRuleType("CopyPlistFile"), .matchRuleItemPattern(.suffix("UITestTarget-Runner.app/Info.plist"))) { task in
                if task.ruleInfo.count > 1 {
                    let infoPlistPath = Path(task.ruleInfo[1])
                    if results.fs.exists(infoPlistPath) {
                        if let infoPlist = try? PropertyList.fromPath(infoPlistPath, fs: results.fs), let infoDict = infoPlist.dictValue {
                            #expect(infoDict["CFBundleExecutable"]?.stringValue == "UITestTarget-Runner")
                            #expect(infoDict["CFBundleIdentifier"]?.stringValue == "com.apple.dt.UITestTarget.xctrunner")
                            #expect(infoDict["CFBundleName"]?.stringValue == "UITestTarget-Runner")
                        }
                        else {
                            Issue.record("Could not read Info.plist for XCTRunner.app at path: \(infoPlistPath.str)")
                        }
                    }
                    else {
                        Issue.record("Info.plist for XCTRunner.app does not exist at path: \(infoPlistPath.str)")
                    }
                }
                else {
                    Issue.record("Could not get path to Info.plist for XCTRunner.app from rule: \(task.ruleInfo)")
                }
            }
        }
    }
}
