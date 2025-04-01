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
import SWBProtocol
@_spi(Testing) import SWBUtil
import SWBTestSupport

@Suite(.userDefaults(["EnableBuildBacktraceRecording": "true"]))
fileprivate struct BuildBacktraceTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func LLBuildBacktraceRecording() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("foo.c"),
                                TestFile("bar.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetFoo",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ]),
                            TestStandardTarget(
                                "TargetBar",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "bar.c",
                                    ]),
                                    TestFrameworksBuildPhase([
                                        "TargetFoo.framework"
                                    ])
                                ], dependencies: ["TargetFoo"]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/foo.c")) { file in
                file <<<
                    """
                    int foo(void) {
                        return 1;
                    }
                    """
            }
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/bar.c")) { file in
                file <<<
                    """
                    int bar(void) {
                        return 2;
                    }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("CompileC")) { task in
                    results.checkBacktrace(task, ["<category='ruleNeverBuilt' description=''Compile foo.c (x86_64)' had never run'>"])
                }
                results.checkTask(.matchTargetName("TargetBar"), .matchRuleType("Ld")) { task in
                    results.checkBacktrace(task, ["<category='ruleNeverBuilt' description=''Link TargetBar (x86_64)' had never run'>"])
                }
            }

            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true)

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/foo.c")) { file in
                file <<<
                    """
                    int foo2(void) {
                        return 42;
                    }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("CompileC")) { task in
                    results.checkBacktrace(task, [
                        "<category='ruleInputRebuilt' description='an input of 'Compile foo.c (x86_64)' changed'>",
                        "<category='ruleHadInvalidValue' description='file '\(SRCROOT.join("Sources/foo.c").str)' changed'>"
                    ])
                }
                results.checkTask(.matchTargetName("TargetBar"), .matchRuleType("Ld")) { task in
                    results.checkBacktrace(task, [
                        "<category='ruleInputRebuilt' description='an input of 'Link TargetBar (x86_64)' changed'>",
                        "<category='ruleInputRebuilt' description='the producer of file '\(SRCROOT.str)/build/EagerLinkingTBDs/Debug/TargetFoo.framework/Versions/A/TargetFoo.tbd' ran'>",
                        "<category='ruleInputRebuilt' description='an input of 'Generate TBD TargetFoo' changed'>",
                        "<category='ruleInputRebuilt' description='the producer of file '\(SRCROOT.str)/build/Debug/TargetFoo.framework/Versions/A/TargetFoo' ran'>",
                        "<category='ruleInputRebuilt' description='an input of 'Link TargetFoo (x86_64)' changed'>",
                        "<category='ruleInputRebuilt' description='the producer of file '\(SRCROOT.str)/build/aProject.build/Debug/TargetFoo.build/Objects-normal/x86_64/foo.o' ran'>",
                        "<category='ruleInputRebuilt' description='an input of 'Compile foo.c (x86_64)' changed'>",
                        "<category='ruleHadInvalidValue' description='file '\(SRCROOT.str)/Sources/foo.c' changed'>"
                    ])
                }
            }

            let modifiedParameters = BuildParameters(configuration: "Debug", overrides: ["GCC_PREPROCESSOR_DEFINITIONS": "MY_DEF",])
            let modifiedBuildRequest = BuildRequest(parameters: modifiedParameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: modifiedParameters, target: $0) }), dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            try await tester.checkBuild(runDestination: .macOS, buildRequest: modifiedBuildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("CompileC")) { task in
                    results.checkBacktrace(task, [
                        "<category='ruleInputRebuilt' description='an input of 'Compile foo.c (x86_64)' changed'>",
                        "<category='ruleInputRebuilt' description='the producer of file '\(SRCROOT.str)/build/aProject.build/Debug/TargetFoo.build/Objects-normal/x86_64/7187679823f38a2a940e0043cdf9d637-common-args.resp' ran'>",
                        "<category='ruleSignatureChanged' description='signature of 'Write 7187679823f38a2a940e0043cdf9d637-common-args.resp (x86_64)' changed'>"
                    ])
                }
                if tester.fs.fileSystemMode == .checksumOnly {
                    results.checkTask(.matchTargetName("TargetBar"), .matchRuleType("CompileC")) { task in
                        results.checkBacktrace(task, [
                            "<category='ruleSignatureChanged' description='signature of 'Compile bar.c (x86_64)' changed'>"
                        ])
                    }
                    // Ensure "Ld" is not executed, because contents of "bar.o" are unchanged
                    results.checkNoTask()
                } else {
                    results.checkTask(.matchTargetName("TargetBar"), .matchRuleType("Ld")) { task in
                        results.checkBacktrace(task, [
                            "<category='ruleInputRebuilt' description='an input of 'Link TargetBar (x86_64)' changed'>",
                            "<category='ruleInputRebuilt' description='the producer of file '\(SRCROOT.str)/build/aProject.build/Debug/TargetBar.build/Objects-normal/x86_64/bar.o' ran'>",
                            "<category='ruleInputRebuilt' description='an input of 'Compile bar.c (x86_64)' changed'>",
                            "<category='ruleInputRebuilt' description='the producer of file '\(SRCROOT.str)/build/aProject.build/Debug/TargetBar.build/Objects-normal/x86_64/7187679823f38a2a940e0043cdf9d637-common-args.resp' ran'>",
                            "<category='ruleSignatureChanged' description='signature of 'Write 7187679823f38a2a940e0043cdf9d637-common-args.resp (x86_64)' changed'>"
                        ])
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .flaky("Single-use task backtraces need rework"))
    func singleUseTaskBacktraceRecording() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = try await TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("foo.swift"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "SWIFT_VERSION": swiftVersion
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetFoo",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.swift",
                                    ]),
                                ])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/foo.swift")) { file in
                file <<<
                    """
                    func foo() {}
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("SwiftEmitModule")) { task in
                    results.checkBacktrace(task, [
                        "<category='dynamicTaskRegistration' description=''>",
                        "<category='dynamicTaskRequest' description='task was scheduled by the Swift driver'>",
                        "<category='ruleNeverBuilt' description=''Compile TargetFoo (x86_64)' had never run'>"
                    ])
                }
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("SwiftCompile")) { task in
                    results.checkBacktrace(task, [
                        "<category='dynamicTaskRegistration' description=''>",
                        "<category='dynamicTaskRequest' description='task was scheduled by the Swift driver'>",
                        "<category='ruleNeverBuilt' description=''Compile TargetFoo (x86_64)' had never run'>"
                    ])
                }
            }

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/foo.swift")) { file in
                file <<<
                    """
                    func foo() {}
                    
                    func bar() {}
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("SwiftEmitModule")) { task in
                    results.checkBacktrace(task, [
                        "<category='dynamicTaskRegistration' description=''>",
                        "<category='dynamicTaskRequest' description='task was scheduled by the Swift driver'>",
                        "<category='ruleInputRebuilt' description='an input of 'Compile TargetFoo (x86_64)' changed'>",
                        "<category='ruleHadInvalidValue' description='file '\(tmpDirPath.str)/Test/aProject/Sources/foo.swift' changed'>"
                    ])
                }
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("SwiftCompile")) { task in
                    results.checkBacktrace(task, [
                        "<category='dynamicTaskRegistration' description=''>",
                        "<category='dynamicTaskRequest' description='task was scheduled by the Swift driver'>",
                        "<category='ruleInputRebuilt' description='an input of 'Compile TargetFoo (x86_64)' changed'>",
                        "<category='ruleHadInvalidValue' description='file '\(tmpDirPath.str)/Test/aProject/Sources/foo.swift' changed'>"
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func backtracesForDeletedOutputs() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("foo.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetFoo",
                                type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/foo.c")) { file in
                file <<<
                    """
                    int foo(void) { return 42; }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
            }

            try tester.fs.remove(SRCROOT.join("build/aProject.build/Debug/TargetFoo.build/Objects-normal/x86_64/foo.o"))

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("CompileC")) { task in
                    results.checkBacktrace(task, [
                        "<category='ruleHadInvalidValue' description=''Compile foo.c (x86_64)' did not have up-to-date outputs'>",
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func backtraceOfAlwaysExecutingTasks() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: []),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetFoo",
                                type: .framework,
                                buildPhases: [
                                    TestShellScriptBuildPhase(name: "Script", originalObjectID: "X", contents: "true", alwaysOutOfDate: true),
                                ])
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("PhaseScriptExecution")) { task in
                    results.checkBacktrace(task, [
                        "<category='ruleNeverBuilt' description=''Run custom shell script 'Script'' had never run'>"
                    ])
                }
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("PhaseScriptExecution")) { task in
                    results.checkBacktrace(task, [
                        "<category='ruleHadInvalidValue' description=''Run custom shell script 'Script'' is configured to run in every incremental build'>"
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func mutatingTaskBacktraceRecording() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources",
                            path: "Sources",
                            children: [
                                TestFile("foo.c"),
                            ]),
                        buildConfigurations: [
                            TestBuildConfiguration(
                                "Debug",
                                buildSettings: [
                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                    "CODE_SIGN_IDENTITY": "-",
                                    "AD_HOC_CODE_SIGNING_ALLOWED": "YES",
                                    "GENERATE_INFOPLIST_FILE": "YES",
                                    "INSTALL_GROUP": "",
                                    "INSTALL_OWNER": "",
                                    "DSTROOT": tmpDirPath.join("DSTROOT").str
                                ])
                        ],
                        targets: [
                            TestStandardTarget(
                                "TargetFoo",
                                type: .application,
                                buildPhases: [
                                    TestSourcesBuildPhase([
                                        "foo.c",
                                    ]),
                                ]),
                        ])
                ])

            let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false, fileSystem: localFS)
            let parameters = BuildParameters(action: .install, configuration: "Debug")
            let provisioningInputs = ["TargetFoo": ProvisioningTaskInputs(identityHash: "-", signedEntitlements: .plDict([:]), simulatedEntitlements: .plDict([:]))]
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            let SRCROOT = testWorkspace.sourceRoot.join("aProject")

            // Create the source files.
            try await tester.fs.writeFileContents(SRCROOT.join("Sources/foo.c")) { file in
                file <<<
                    """
                    int main() {}
                    int foo(void) {
                        return 1;
                    }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()
            }

            try await tester.checkNullBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs)

            try await tester.fs.writeFileContents(SRCROOT.join("Sources/foo.c")) { file in
                file <<<
                    """
                    int main() {}
                    int foo2(void) {
                        return 42;
                    }
                    """
            }

            try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true, signableTargets: Set(provisioningInputs.keys), signableTargetInputs: provisioningInputs) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("TargetFoo"), .matchRuleType("RegisterWithLaunchServices")) { task in
                    results.checkBacktrace(task, [
                        "<category='ruleInputRebuilt' description='an input of 'Register TargetFoo.app' changed'>",
                        "<category='ruleInputRebuilt' description=''Validate TargetFoo.app' mutated '\(tmpDirPath.join("DSTROOT").str)/Applications/TargetFoo.app''>",
                        "<category='ruleInputRebuilt' description='an input of 'Validate TargetFoo.app' changed'>",
                        "<category='ruleInputRebuilt' description=''Sign TargetFoo.app' mutated '\(tmpDirPath.join("DSTROOT").str)/Applications/TargetFoo.app' and '\(tmpDirPath.join("DSTROOT").str)/Applications/TargetFoo.app/Contents/MacOS/TargetFoo''>",
                        "<category='ruleInputRebuilt' description='an input of 'Sign TargetFoo.app' changed'>",
                        "<category='ruleInputRebuilt' description='an input of file '\(SRCROOT.str)/Sources/foo.c/' changed'>",
                        "<category='ruleInputRebuilt' description='an input of signature of directory tree at '\(SRCROOT.str)/Sources/foo.c' changed'>",
                        "<category='ruleHadInvalidValue' description='contents of '\(SRCROOT.str)/Sources/foo.c' changed'>"
                    ])
                }
            }
        }
    }
}
