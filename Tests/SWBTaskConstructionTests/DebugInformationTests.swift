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
import SWBProtocol
import SWBUtil

/// Tests of debug formats and dSYM generation.
@Suite
fileprivate struct DebugInformationTests: CoreBasedTests {
    /// Test the different DWARF version formats we support.
    @Test(.requireSDKs(.macOS))
    func debugInformationVersion() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("CFile.c"),
                    TestFile("SwiftFile.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Config",
                    buildSettings: [
                        "DEBUG_INFORMATION_FORMAT": "dwarf",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "CFile.c",
                            "SwiftFile.swift",
                        ]),
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Test the default version.
        await tester.checkBuild(BuildParameters(configuration: "Config"), runDestination: .macOS) { results in
            // Check clang.
            results.checkTask(.matchRuleType("CompileC")) { task in
                task.checkCommandLineContains(["-g"])
                task.checkCommandLineDoesNotContain("-gdwarf-4")
                task.checkCommandLineDoesNotContain("-gdwarf-5")
            }

            // Check swiftc.
            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkCommandLineContains(["-g"])
                task.checkCommandLineDoesNotContain("-dwarf-version=4")
                task.checkCommandLineDoesNotContain("-dwarf-version=5")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Test explicitly setting to DWARF 4.
        await tester.checkBuild(BuildParameters(configuration: "Config", overrides: ["DEBUG_INFORMATION_VERSION" : "dwarf4"]), runDestination: .macOS) { results in
            // Check clang.
            results.checkTask(.matchRuleType("CompileC")) { task in
                task.checkCommandLineContains(["-g", "-gdwarf-4"])
                task.checkCommandLineDoesNotContain("-gdwarf-5")
            }

            // Check swiftc.
            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkCommandLineContains(["-g", "-dwarf-version=4"])
                task.checkCommandLineDoesNotContain("-dwarf-version=5")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Test explicitly setting to DWARF 5.
        await tester.checkBuild(BuildParameters(configuration: "Config", overrides: ["DEBUG_INFORMATION_VERSION" : "dwarf5"]), runDestination: .macOS) { results in
            // Check clang.
            results.checkTask(.matchRuleType("CompileC")) { task in
                task.checkCommandLineContains(["-g", "-gdwarf-5"])
                task.checkCommandLineDoesNotContain("-gdwarf-4")
            }

            // Check swiftc.
            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkCommandLineContains(["-g", "-dwarf-version=5"])
                task.checkCommandLineDoesNotContain("-dwarf-version=4")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Test disabling debug information.
        await tester.checkBuild(BuildParameters(configuration: "Config", overrides: ["DEBUG_INFORMATION_FORMAT" : "", "DEBUG_INFORMATION_VERSION" : "dwarf5"]), runDestination: .macOS) { results in
            // Check clang.
            results.checkTask(.matchRuleType("CompileC")) { task in
                task.checkCommandLineDoesNotContain("-g")
                task.checkCommandLineDoesNotContain("-gdwarf-4")
                task.checkCommandLineDoesNotContain("-gdwarf-5")
            }

            // Check swiftc.
            results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                task.checkCommandLineDoesNotContain("-g")
                task.checkCommandLineDoesNotContain("-dwarf-version=4")
                task.checkCommandLineDoesNotContain("-dwarf-version=5")
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    /// Check that we only generate dSYMs when appropriate.
    @Test(.requireSDKs(.macOS))
    func dSYMGeneration() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        // Check behavior with dSYMs disabled.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["DEBUG_INFORMATION_FORMAT": "dwarf"]), runDestination: .macOS) { results in
            // There shouldn't be a dSYM task.
            results.checkNoTask(.matchRuleType("GenerateDSYMFile"))

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check behavior with dSYMs enabled.
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"]), runDestination: .macOS) { results in
            // Check the expected dSYM task.
            results.checkTask(.matchRuleType("GenerateDSYMFile")) { task in
                task.checkRuleInfo(["GenerateDSYMFile", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/Test/aProject/build/Debug/CoreFoo.framework/Versions/A/CoreFoo"])
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check install behavior with dSYMs enabled.
        let buildVariants = ["debug", "normal"]
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: [
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "BUILD_VARIANTS": buildVariants.joined(separator: " "),
        ]), runDestination: .macOS) { results in
            // Check tasks for each build variant.
            for buildVariant in buildVariants {
                let binaryName = "CoreFoo" + (buildVariant == "normal" ? "" : "_\(buildVariant)")

                // Check the dsymutil task for the build variant.
                var dsymutilTask: (any PlannedTask)? = nil
                results.checkTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename(binaryName)) { task in
                    task.checkRuleInfo(["GenerateDSYMFile", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/\(binaryName)"])
                    dsymutilTask = task
                }

                // Make sure the strip task for this build variant is ordered after the dsymutil task.
                results.checkTask(.matchRuleType("Strip"), .matchRuleItemBasename(binaryName)) { task in
                    if let dsymutilTask {
                        results.checkTaskFollows(task, antecedent: dsymutilTask)
                    }
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check install behavior with `DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT` enabled.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: [
            "DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT": "YES",
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "BUILD_VARIANTS": buildVariants.joined(separator: " "),
        ]), runDestination: .macOS) { results in
            var dsymutilTasks = [any PlannedTask]()
            results.checkTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("CoreFoo")) { task in
                task.checkRuleInfo(["GenerateDSYMFile", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/CoreFoo"])
                dsymutilTasks.append(task)
            }

            results.checkTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("CoreFoo_debug")) { task in
                task.checkRuleInfo(["GenerateDSYMFile", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/aProject.dst/Library/Frameworks/CoreFoo.framework/Versions/A/CoreFoo_debug"])
                dsymutilTasks.append(task)
            }

            results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("CoreFoo.framework.dSYM")) { task in
                task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-resolve-src-symlinks", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/aProject.dst/Library/Frameworks"])

                // Make sure this task follows the dSYM producer tasks.
                for dsymutilTask in dsymutilTasks {
                    results.checkTaskDependsOn(task, antecedent: dsymutilTask)
                }
            }

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }

        // Check build behavior with `DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT` enabled.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: [
            "DWARF_DSYM_FILE_SHOULD_ACCOMPANY_PRODUCT": "YES",
            "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
            "BUILD_VARIANTS": buildVariants.joined(separator: " "),
        ]), runDestination: .macOS) { results in
            results.checkTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("CoreFoo")) { task in
                task.checkRuleInfo(["GenerateDSYMFile", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/Test/aProject/build/Debug/CoreFoo.framework/Versions/A/CoreFoo"])
            }

            results.checkTask(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("CoreFoo_debug")) { task in
                task.checkRuleInfo(["GenerateDSYMFile", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/Test/aProject/build/Debug/CoreFoo.framework/Versions/A/CoreFoo_debug"])
            }

            results.checkNoTask(.matchRuleType("Copy"), .matchRuleItemBasename("CoreFoo.framework.dSYM"))

            // Check there are no diagnostics.
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func duplicatedDSYMName() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("main.c"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "NO",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "CoreFoo", type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])]),
                TestStandardTarget(
                    "OtherTarget", type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [ "PRODUCT_NAME": "CoreFoo", "TARGET_BUILD_DIR": "/tmp/Test/aProject/build/Debug/Other" ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["main.c"])]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        let buildParameters = BuildParameters(configuration: "Debug", overrides: ["DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"])
        let project = tester.workspace.projects.first!
        let target1 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[0])
        let target2 = BuildRequest.BuildTargetInfo(parameters: buildParameters, target: project.targets[1])
        let buildRequest = BuildRequest(parameters: buildParameters, buildTargets: [target1, target2], continueBuildingAfterErrors: false, useParallelTargets: true, useImplicitDependencies: true, useDryRun: false)

        await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, checkTaskGraphIntegrity: false) { results in
            results.checkTasks(.matchRuleType("GenerateDSYMFile"), .matchRuleItemBasename("CoreFoo")) { tasks in
                #expect(tasks.count == 2)
                for task in tasks {
                    if task.ruleInfo.last?.contains("Other") == true {
                        task.checkRuleInfo(["GenerateDSYMFile", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/Test/aProject/build/Debug/Other/CoreFoo.framework/Versions/A/CoreFoo"])
                    } else {
                        task.checkRuleInfo(["GenerateDSYMFile", "/tmp/Test/aProject/build/Debug/CoreFoo.framework.dSYM", "/tmp/Test/aProject/build/Debug/CoreFoo.framework/Versions/A/CoreFoo"])
                    }
                }
            }

            results.checkNoDiagnostics()
        }
    }

}
