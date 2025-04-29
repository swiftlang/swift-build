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
import SWBTaskConstruction
import SWBUtil
import SWBProtocol

@Suite
fileprivate struct MasterObjectFileTests: CoreBasedTests {
    // Test interesting permutations of generating a master object file.
    @Test(.requireSDKs(.macOS))
    func masterObjectFileGeneration() async throws {
        let core = try await getCore()
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "CODE_SIGN_IDENTITY": "",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "MACOSX_DEPLOYMENT_TARGET": core.loadSDK(.macOS).defaultDeploymentTarget,
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AllLibraries",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_MASTER_OBJECT_FILE": "YES",
                                "WARNING_LDFLAGS": "-lWarningLibrary",
                                "PRELINK_LIBS": "-lSomeLibrary -lAnotherLibrary",
                                "PRELINK_FLAGS": "-exported_symbols_list Exports.exp",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase([]),
                    ],
                    dependencies: ["Tool"]),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try TaskConstructionTester(core, testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check a debug build.
        await tester.checkBuild(runDestination: .macOS, fs: localFS) { results in
            // Ignore all tasks we don't want to check.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

            results.checkTarget("AllLibraries") { target in
                // There should be tasks to create the master object file and then the static library.
                results.checkTask(.matchTarget(target), .matchRuleType("MasterObjectLink")) { task in
                    task.checkCommandLineMatches([.suffix("ld"), "-r", "-arch", "x86_64", "-syslibroot", .equal(core.loadSDK(.macOS).path.str), "-exported_symbols_list", "Exports.exp", "-lWarningLibrary", "-lSomeLibrary", "-lAnotherLibrary", "-o", .equal("\(SRCROOT)/build/aProject.build/Debug/AllLibraries.build/Objects-normal/libAllLibraries.a-x86_64-master.o")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                    task.checkCommandLineMatches([.suffix("libtool"), "-static", "-arch_only", "x86_64", "-D", "-syslibroot", .equal(core.loadSDK(.macOS).path.str), .equal("-L\(SRCROOT)/build/Debug"), "-filelist", .equal("\(SRCROOT)/build/aProject.build/Debug/AllLibraries.build/Objects-normal/x86_64/AllLibraries.LinkFileList"), "-dependency_info", "\(SRCROOT)/build/aProject.build/Debug/AllLibraries.build/Objects-normal/x86_64/AllLibraries_libtool_dependency_info.dat", "-o", .equal("\(SRCROOT)/build/Debug/libAllLibraries.a")])
                }
            }

            // There should be no other tasks.
            results.checkNoTask()

            // Check diagnostics.
            results.checkWarning(.prefix("WARNING_LDFLAGS is deprecated; use OTHER_LDFLAGS instead."))
            results.checkNoDiagnostics()

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }

        // Check an install build with RETAIN_RAW_BINARIES.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Debug", overrides: ["RETAIN_RAW_BINARIES": "YES"]), runDestination: .macOS, fs: localFS) { results in
            // Ignore all tasks we don't want to check.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

            results.checkTarget("AllLibraries") { target in
                // There should be tasks to create the master object file and then the static library.
                results.checkTask(.matchTarget(target), .matchRuleType("MasterObjectLink")) { task in
                    task.checkCommandLineMatches([.suffix("ld"), "-r", "-arch", "x86_64", "-syslibroot", .equal(core.loadSDK(.macOS).path.str), "-exported_symbols_list", "Exports.exp", "-lWarningLibrary", "-lSomeLibrary", "-lAnotherLibrary", "-o", .equal("\(SRCROOT)/build/aProject.build/Debug/AllLibraries.build/Objects-normal/libAllLibraries.a-x86_64-master.o")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                    task.checkCommandLineMatches([.suffix("libtool"), "-static", "-arch_only", "x86_64", "-D", "-syslibroot", .equal(core.loadSDK(.macOS).path.str), .equal("-L\(SRCROOT)/build/Debug/BuiltProducts"), "-filelist", .equal("\(SRCROOT)/build/aProject.build/Debug/AllLibraries.build/Objects-normal/x86_64/AllLibraries.LinkFileList"), "-dependency_info", "\(SRCROOT)/build/aProject.build/Debug/AllLibraries.build/Objects-normal/x86_64/AllLibraries_libtool_dependency_info.dat", "-o", "/tmp/aProject.dst/usr/local/lib/libAllLibraries.a"])
                }

                // There should be a task to create the symlink in the built products dir to the product in the DSTROOT, and to copy the product from the DSTROOT to the SYMROOT.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Debug/BuiltProducts/libAllLibraries.a", "../../../../../aProject.dst/usr/local/lib/libAllLibraries.a"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/libAllLibraries.a", "/tmp/aProject.dst/usr/local/lib/libAllLibraries.a"])) { _ in }

                // There should be postprocessing tasks on the product in the DSTROOT.
                results.checkTask(.matchTarget(target), .matchRule(["Strip", "/tmp/aProject.dst/usr/local/lib/libAllLibraries.a"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SetOwnerAndGroup", "exampleUser:exampleGroup", "/tmp/aProject.dst/usr/local/lib/libAllLibraries.a"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SetMode", "u+w,go-w,a+rX", "/tmp/aProject.dst/usr/local/lib/libAllLibraries.a"])) { _ in }
            }

            // There should be no other tasks.
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkWarning(.prefix("WARNING_LDFLAGS is deprecated; use OTHER_LDFLAGS instead."))
            results.checkNoDiagnostics()

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }

        // Check an installapi build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Debug"), runDestination: .macOS, fs: localFS) { results in
            // Ignore all tasks we don't want to check.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

            results.checkTarget("AllLibraries") { target in
                // There should be tasks to create the master object file and then the static library.
                results.checkNoTask(.matchTarget(target), .matchRuleType("MasterObjectLink"))
            }

            // There should be no other tasks.
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }

    @Test(.requireSDKs(.macOS, .iOS))
    func masterObjectFileGenerationVariant_macCatalyst() async throws {
        let core = try await getCore()
        // Test that a master object file gets generated even if the target contains no sources or libraries in its build phases.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
                        "SDKROOT": "iphoneos",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AllLibraries",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_MASTER_OBJECT_FILE": "YES",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase([]),
                    ],
                    dependencies: ["Tool"]),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try TaskConstructionTester(core, testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check a build for MacCatalyst.
        await tester.checkBuild(runDestination: .macCatalyst, fs: localFS) { results in
            // Ignore all tasks we don't want to check.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

            results.checkTarget("AllLibraries") { target in
                // There should be tasks to create the master object file and then the static library.
                results.checkTask(.matchTarget(target), .matchRuleType("MasterObjectLink")) { task in
                    task.checkCommandLineMatches([.suffix("ld"), "-r", "-arch", "x86_64", "-syslibroot", .equal(core.loadSDK(.macOS).path.str), "-o", .equal("\(SRCROOT)/build/aProject.build/Debug-maccatalyst/AllLibraries.build/Objects-normal/libAllLibraries.a-x86_64-master.o")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                    task.checkCommandLineMatches([.suffix("libtool"), "-static", "-arch_only", "x86_64", "-D", "-syslibroot", .equal(core.loadSDK(.macOS).path.str), .equal("-L\(SRCROOT)/build/Debug-maccatalyst"), "-L\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/lib", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/maccatalyst", "-L\(core.loadSDK(.macOS).path.str)/System/iOSSupport/usr/lib", "-L\(core.developerPath.path.str)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/maccatalyst", "-filelist", .equal("\(SRCROOT)/build/aProject.build/Debug-maccatalyst/AllLibraries.build/Objects-normal/x86_64/AllLibraries.LinkFileList"), "-dependency_info", "\(SRCROOT)/build/aProject.build/Debug-maccatalyst/AllLibraries.build/Objects-normal/x86_64/AllLibraries_libtool_dependency_info.dat", "-o", .equal("\(SRCROOT)/build/Debug-maccatalyst/libAllLibraries.a")])
                }
            }

            // There should be no other tasks.
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }

    @Test(.requireSDKs(.iOS))
    func masterObjectFileGenerationVariant_ios() async throws {
        let core = try await getCore()
        // Test that a master object file gets generated even if the target contains no sources or libraries in its build phases.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
                        "SDKROOT": "iphoneos",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AllLibraries",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_MASTER_OBJECT_FILE": "YES",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase([]),
                    ],
                    dependencies: ["Tool"]),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try TaskConstructionTester(core, testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check a debug build.
        await tester.checkBuild(runDestination: .iOS, fs: localFS) { results in
            // Ignore all tasks we don't want to check.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

            results.checkTarget("AllLibraries") { target in
                // There should be tasks to create the master object file and then the static library.
                results.checkTask(.matchTarget(target), .matchRuleType("MasterObjectLink")) { task in
                    task.checkCommandLineMatches([.suffix("ld"), "-r", "-arch", "arm64", "-syslibroot", .equal(results.runDestinationSDK.path.str), "-o", .equal("\(SRCROOT)/build/aProject.build/Debug-iphoneos/AllLibraries.build/Objects-normal/libAllLibraries.a-arm64-master.o")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                    task.checkCommandLineMatches([.suffix("libtool"), "-static", "-arch_only", "arm64", "-D", "-syslibroot", .equal(results.runDestinationSDK.path.str), .equal("-L\(SRCROOT)/build/Debug-iphoneos"), "-filelist", .equal("\(SRCROOT)/build/aProject.build/Debug-iphoneos/AllLibraries.build/Objects-normal/arm64/AllLibraries.LinkFileList"), "-dependency_info", "\(SRCROOT)/build/aProject.build/Debug-iphoneos/AllLibraries.build/Objects-normal/arm64/AllLibraries_libtool_dependency_info.dat", "-o", .equal("\(SRCROOT)/build/Debug-iphoneos/libAllLibraries.a")])
                }
            }

            // There should be no other tasks.
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }

    @Test(.requireSDKs(.iOS))
    func masterObjectFileGenerationVariant_ios_simulator() async throws {
        let core = try await getCore()
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "IPHONEOS_DEPLOYMENT_TARGET": core.loadSDK(.iOS).defaultDeploymentTarget,
                        "SDKROOT": "iphonesimulator",
                    ]),
            ],
            targets: [
                TestStandardTarget(
                    "AllLibraries",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "GENERATE_MASTER_OBJECT_FILE": "YES",
                            ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([]),
                        TestFrameworksBuildPhase([]),
                    ],
                    dependencies: ["Tool"]),
            ])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try TaskConstructionTester(core, testWorkspace)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check a debug build.
        await tester.checkBuild(runDestination: .iOSSimulator, fs: localFS) { results in
            // Ignore all tasks we don't want to check.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

            results.checkTarget("AllLibraries") { target in
                // There should be tasks to create the master object file and then the static library.
                results.checkTask(.matchTarget(target), .matchRuleType("MasterObjectLink")) { task in
                    task.checkCommandLineMatches([.suffix("ld"), "-r", "-arch", "x86_64", "-syslibroot", .equal(results.runDestinationSDK.path.str), "-o", .equal("\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AllLibraries.build/Objects-normal/libAllLibraries.a-x86_64-master.o")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                    task.checkCommandLineMatches([.suffix("libtool"), "-static", "-arch_only", "x86_64", "-D", "-syslibroot", .equal(results.runDestinationSDK.path.str), .equal("-L\(SRCROOT)/build/Debug-iphonesimulator"), "-filelist", .equal("\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AllLibraries.build/Objects-normal/x86_64/AllLibraries.LinkFileList"), "-dependency_info", "\(SRCROOT)/build/aProject.build/Debug-iphonesimulator/AllLibraries.build/Objects-normal/x86_64/AllLibraries_libtool_dependency_info.dat", "-o", .equal("\(SRCROOT)/build/Debug-iphonesimulator/libAllLibraries.a")])
                }
            }

            // There should be no other tasks.
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }
}
