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
import SWBTaskConstruction
import SWBTestSupport
import SWBUtil
import SWBProtocol

@Suite
fileprivate struct KernelExtensionTaskConstructionTests: CoreBasedTests {
    /// Tests that macOS kernel extensions build for arm64e rather than arm64, when using `ARCHS_STANDARD`.
    @Test(.requireSDKs(.macOS))
    func kernelExtensionStandardArchitectures() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File.c"),
                ]),
            targets: [
                TestStandardTarget(
                    "aTarget",
                    type: .kernelExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "GENERATE_KERNEL_MODULE_INFO_FILE": "NO",
                            "PRODUCT_NAME": "KextTest",

                            "MODULE_NAME": "com.apple.dt.KextTest",
                            "MODULE_START": "KextTest_start",
                            "MODULE_STOP": "KextTest_stop",
                            "MODULE_VERSION": "1.0.0d1",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File.c"),
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        for macro in ["$(ARCHS_STANDARD)", "$(ARCHS_STANDARD_64_BIT)", "$(ARCHS_STANDARD_INCLUDING_64_BIT)"] {
            await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ARCHS": macro]), runDestination: .anyMac) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItem("arm64e")) { task in }
                results.checkTask(.matchRuleType("CompileC"), .matchRuleItem("x86_64")) { task in }
                results.checkNoTask(.matchRuleType("CompileC"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func kernelExtensionModuleInfo() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File.c"),
                ]),
            targets: [
                TestStandardTarget(
                    "aTarget",
                    type: .kernelExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "KextTest",
                            "ARCHS": "x86_64 x86_64h",
                            "VALID_ARCHS": "$(inherited) x86_64h",

                            "MODULE_NAME": "com.apple.dt.KextTest",
                            "MODULE_START": "KextTest_start",
                            "MODULE_STOP": "KextTest_stop",
                            "MODULE_VERSION": "1.0.0d1",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("File.c"),
                        ]),
                    ])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        try await tester.checkBuild(runDestination: .anyMac) { results in
            results.checkNoDiagnostics()

            let writeTask: any PlannedTask = try results.checkTask(.matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/aTarget.build/DerivedSources/KextTest_info.c"])) { task in task }

            let compileRules = [
                ["CompileC", "/tmp/Test/aProject/build/aProject.build/Debug/aTarget.build/Objects-normal/x86_64/KextTest_info.o", "/tmp/Test/aProject/build/aProject.build/Debug/aTarget.build/DerivedSources/KextTest_info.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"],
                ["CompileC", "/tmp/Test/aProject/build/aProject.build/Debug/aTarget.build/Objects-normal/x86_64h/KextTest_info.o", "/tmp/Test/aProject/build/aProject.build/Debug/aTarget.build/DerivedSources/KextTest_info.c", "normal", "x86_64h", "c", "com.apple.compilers.llvm.clang.1_0.compiler"],
            ]
            for r in compileRules {
                results.checkTask(.matchRule(r)) { task in
                    results.checkTaskFollows(task, antecedent: writeTask)
                }
            }

            results.checkTask(.matchRuleType("Ld"), .matchRuleItem("x86_64")) { task in
                task.checkCommandLineContains(["-nostdlib"])
                task.checkCommandLineContains([
                    "-Xlinker", "-kext",
                    "-lkmodc++", "-lkmod", "-lcc_kext"])
            }
        }
    }

    /// We shouldn't generate module info if there are no other items in the sources phase
    @Test(.requireSDKs(.macOS))
    func kernelExtensionModuleInfoEmpty() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("File.c"),
                ]),
            targets: [
                TestStandardTarget(
                    "aTarget",
                    type: .kernelExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "PRODUCT_NAME": "KextTest",
                            "ARCHS": "x86_64 x86_64h",

                            "MODULE_NAME": "com.apple.dt.KextTest",
                            "MODULE_START": "KextTest_start",
                            "MODULE_STOP": "KextTest_stop",
                            "MODULE_VERSION": "1.0.0d1",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                        ]),
                    ])
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRule(["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/aTarget.build/DerivedSources/KextTest_info.c"])) { _ in }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["GENERATE_KERNEL_MODULE_INFO_FILE": "NO"]), runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            let writeRule = ["WriteAuxiliaryFile", "/tmp/Test/aProject/build/aProject.build/Debug/aTarget.build/DerivedSources/KextTest_info.c"]

            results.checkTasks(.matchRule(writeRule)) { tasks in
                #expect(tasks.count == 0)
            }
        }
    }

    /// Test that _info.c files are correctly excluded by `EXCLUDED_SOURCE_FILE_NAMES` and don't cause the build to still think a binary will be produced even when the sole source file has been excluded.
    @Test(.requireSDKs(.macOS))
    func kernelExtensionModuleInfoGeneratedFileIsExcluded() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "CODE_SIGNING_ALLOWED": "NO",
                                        "BUILD_VARIANTS": "normal debug profile",
                                        "EXCLUDED_SOURCE_FILE_NAMES": "*",
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "SKIP_INSTALL": "YES",
                                        "MODULE_NAME": "foo",
                                        "MODULE_START": "foo_start",
                                        "MODULE_STOP": "foo_stop",
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "SomeKext",
                    type: .kernelExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                        ]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        // Check the build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CreateBuildDirectory", "Gate", "Ld", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "RegisterExecutionPolicyException", "SetMode", "SetOwnerAndGroup", "SymLink", "Touch", "WriteAuxiliaryFile"])

            // Check there are no diagnostics.
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }

    /// Test a build rule which overrides the _info.c file compilation.
    @Test(.requireSDKs(.macOS))
    func overrideKernelExtensionModuleInfoBuildRule() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("file.fake-x"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug",
                                       buildSettings: [
                                        "BUILD_VARIANTS": "normal debug profile",
                                        "GENERATE_INFOPLIST_FILE": "YES",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "MODULE_NAME": "foo",
                                        "MODULE_START": "foo_start",
                                        "MODULE_STOP": "foo_stop",
                                       ])
            ],
            targets: [
                TestStandardTarget(
                    "SomeKext",
                    type: .kernelExtension,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug"),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "file.fake-x",
                        ]),
                    ],
                    buildRules: [
                        TestBuildRule(filePattern: "$(DERIVED_FILE_DIR)/$(PRODUCT_NAME)_info.c", script: "touch \"$SCRIPT_OUTPUT_FILE_0\"", outputs: [
                            "$(DERIVED_FILE_DIR)/$(FULL_PRODUCT_NAME)_info1.c"
                        ], runOncePerArchitecture: false)
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check the build.
        await tester.checkBuild(runDestination: .macOS) { results in
            results.consumeTasksMatchingRuleTypes(["CodeSign", "CreateBuildDirectory", "Gate", "Ld", "MkDir", "ProcessInfoPlistFile", "ProcessProductPackaging", "ProcessProductPackagingDER", "RegisterExecutionPolicyException", "SymLink", "Touch", "WriteAuxiliaryFile"])

            results.checkTarget("SomeKext") { target in
                // Check that there's only one RuleScriptExecution for fake-neutral, since it's architecture-independent
                results.checkTask(.matchTarget(target), .matchRule(["RuleScriptExecution", "\(SRCROOT)/build/aProject.build/Debug/SomeKext.build/DerivedSources/SomeKext.kext_info1.c", "\(SRCROOT)/build/aProject.build/Debug/SomeKext.build/DerivedSources/SomeKext_info.c", "normal", "undefined_arch"])) { _ in }

                // Check that the architecture-neutral rule's outputs are still varianted per architecture
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/SomeKext.build/Objects-normal/x86_64/SomeKext.kext_info1.o", "\(SRCROOT)/build/aProject.build/Debug/SomeKext.build/DerivedSources/SomeKext.kext_info1.c", "normal", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/SomeKext.build/Objects-debug/x86_64/SomeKext.kext_info1.o", "\(SRCROOT)/build/aProject.build/Debug/SomeKext.build/DerivedSources/SomeKext.kext_info1.c", "debug", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Debug/SomeKext.build/Objects-profile/x86_64/SomeKext.kext_info1.o", "\(SRCROOT)/build/aProject.build/Debug/SomeKext.build/DerivedSources/SomeKext.kext_info1.c", "profile", "x86_64", "c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
            }

            results.checkWarning(.equal("no rule to process file '/tmp/Test/aProject/Sources/file.fake-x' of type 'file' for architecture 'x86_64' (in target 'SomeKext' from project 'aProject')"))
            results.checkWarning(.equal("no rule to process file '/tmp/Test/aProject/Sources/file.fake-x' of type 'file' for architecture 'x86_64' (in target 'SomeKext' from project 'aProject')"))
            results.checkWarning(.equal("no rule to process file '/tmp/Test/aProject/Sources/file.fake-x' of type 'file' for architecture 'x86_64' (in target 'SomeKext' from project 'aProject')"))

            // Check there are no diagnostics.
            results.checkNoTask()
            results.checkNoDiagnostics()
        }
    }
}
