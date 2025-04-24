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
import SWBUtil
import SWBCore

import SWBTestSupport
import SWBProtocol

@Suite(.requireXcode16())
fileprivate struct BuildActionTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func installApi() async throws {
        // Test running the installapi build action on a framework.
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceOne.m"),
                    TestFile("SourceTwo.m"),
                    TestFile("SourceThree.swift"),
                    TestFile("ProjectHeaderFile.h"),
                    TestFile("PrivateHeaderFile.h"),
                    TestFile("PublicHeaderFile.h"),
                    TestFile("FrameworkTarget.h"),
                    TestFile("StringsResource.strings"),
                    TestFile("libdynamic.dylib"),
                    TestFile("StubFramework.framework"),
                    TestFile("Script-Input-Header.fake-input"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "DEFINES_MODULE": "YES",
                    "CODE_SIGN_IDENTITY": "-",
                    "TAPI_EXEC": tapiToolPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "FrameworkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "INFOPLIST_FILE": "MyInfo.plist",
                            "SUPPORTS_TEXT_BASED_API": "YES"
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                            "SourceTwo.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                            TestBuildFile("PublicHeaderFile.h", headerVisibility: .public),
                            TestBuildFile("PrivateHeaderFile.h", headerVisibility: .private),
                            TestBuildFile("ProjectHeaderFile.h"),   // visibility: project
                        ]),
                        TestResourcesBuildPhase([
                            "StringsResource.strings",
                        ]),
                        TestFrameworksBuildPhase([
                            "libdynamic.dylib",
                        ]),
                        TestCopyFilesBuildPhase([
                            "StubFramework.framework",
                        ], destinationSubfolder: .frameworks),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check an installhdrs release build.
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Release"), runDestination: .macOS) { results in
            results.checkTarget("FrameworkTarget") { target in
                // There should be the expected number of mkdir and symlink tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { tasks in
                    #expect(tasks.count == 5)
                })
                results.checkTasks(.matchTarget(target), .matchRuleType("SymLink"), body: { tasks in
                    #expect(tasks.count == 6)
                })

                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }

                // There should be three CpHeader tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders/PrivateHeaderFile.h", "\(SRCROOT)/PrivateHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PrivateHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/PublicHeaderFile.h", "\(SRCROOT)/PublicHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PublicHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/FrameworkTarget.h", "\(SRCROOT)/FrameworkTarget.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/FrameworkTarget.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }

                // We should be generating and copying the module map file.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap")) { task in
                    task.checkRuleInfo(["Copy", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap"])
                }

                // There should be a 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }

                // Ignore all Gate and build directory tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                // There should be no other tasks.
                results.checkNoTask()

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }

        // Check an installapi release build with copy files enabled.
        let overrides = [
            "INSTALLAPI_COPY_PHASE": "YES",
        ]
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Release", overrides: overrides), runDestination: .macOS) { results in
            results.checkTarget("FrameworkTarget") { target in
                // There should be the expected number of mkdir and symlink tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { tasks in
                    #expect(tasks.count == 6)
                })
                results.checkTasks(.matchTarget(target), .matchRuleType("SymLink"), body: { tasks in
                    #expect(tasks.count == 7)
                })

                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }

                // There should be three CpHeader tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders/PrivateHeaderFile.h", "\(SRCROOT)/PrivateHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PrivateHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/PublicHeaderFile.h", "\(SRCROOT)/PublicHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PublicHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/FrameworkTarget.h", "\(SRCROOT)/FrameworkTarget.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/FrameworkTarget.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }

                // We should be generating and copying the module map file.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap")) { task in
                    task.checkRuleInfo(["Copy", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap"])
                }

                // There should be a Copy task, since $(INSTALLAPI_COPY_PHASE) is enabled.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy")) { task in
                    task.checkRuleInfo(["Copy", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Frameworks/StubFramework.framework", "\(SRCROOT)/StubFramework.framework"])
                }

                // There should be a 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }

                // Ignore all Gate and build directory tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                // There should be no other tasks.
                results.checkNoTask()

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }

    @Test(.requireSDKs(.macOS))
    func installApiDynamicLibrary() async throws {
        // Test running the installapi build action on a dynamic library.
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceOne.m"),
                    TestFile("SourceTwo.m"),
                    TestFile("SourceThree.swift"),
                    TestFile("ProjectHeaderFile.h"),
                    TestFile("PrivateHeaderFile.h"),
                    TestFile("PublicHeaderFile.h"),
                    TestFile("DynamicLibraryTarget.h"),
                    TestFile("DoesNotSupportTextBasedAPI.h"),
                    TestFile("UsesNonStandardExtension.h"),
                    TestFile("StaticLibraryTarget.h"),
                    TestFile("StringsResource.strings"),
                    TestFile("libdynamic.dylib"),
                    TestFile("Script-Input-Header.fake-input"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "TAPI_EXEC": tapiToolPath.str,
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "DynamicLibraryTarget",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "SUPPORTS_TEXT_BASED_API": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                            "SourceTwo.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("DynamicLibraryTarget.h", headerVisibility: .public),
                            TestBuildFile("PublicHeaderFile.h", headerVisibility: .public),
                            TestBuildFile("PrivateHeaderFile.h", headerVisibility: .private),
                            TestBuildFile("ProjectHeaderFile.h"),   // visibility: project
                        ]),
                        TestResourcesBuildPhase([
                            "StringsResource.strings",
                        ]),
                        TestFrameworksBuildPhase([
                            "libdynamic.dylib",
                        ]),
                    ]),
                TestStandardTarget(
                    "DoesNotSupportTextBasedAPI",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "ALLOW_UNSUPPORTED_TEXT_BASED_API": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("DoesNotSupportTextBasedAPI.h", headerVisibility: .public),
                        ])
                    ]),
                TestStandardTarget(
                    "UsesNonStandardExtension",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "EXECUTABLE_EXTENSION": "videodecoder",
                            "SUPPORTS_TEXT_BASED_API": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("UsesNonStandardExtension.h", headerVisibility: .public),
                        ])
                    ]),
                TestStandardTarget(
                    "StaticLibraryTarget",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "SUPPORTS_TEXT_BASED_API": "YES",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("StaticLibraryTarget.h", headerVisibility: .public),
                        ])
                    ]),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check an installapi release build.
        let parameters = BuildParameters(action: .installAPI, configuration: "Release")
        let buildTargets = tester.workspace.allTargets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) })
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: buildTargets, dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
        await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTarget("DynamicLibraryTarget") { target in
                // There should be one symlink task.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/Release/DynamicLibraryTarget.tbd", "../../../../aProject.dst/usr/local/lib/DynamicLibraryTarget.tbd"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }

                // There should be three CpHeader tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/usr/local/include/PrivateHeaderFile.h", "\(SRCROOT)/PrivateHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PrivateHeaderFile.h", "/tmp/aProject.dst/usr/local/include"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/usr/local/include/PublicHeaderFile.h", "\(SRCROOT)/PublicHeaderFile.h"])) { task in
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PublicHeaderFile.h", "/tmp/aProject.dst/usr/local/include"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/usr/local/include/DynamicLibraryTarget.h", "\(SRCROOT)/DynamicLibraryTarget.h"])) { task in
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/DynamicLibraryTarget.h", "/tmp/aProject.dst/usr/local/include"])
                }
            }
            results.checkTarget("DoesNotSupportTextBasedAPI") { target in
                // There should be no symlink tasks
                results.checkNoTask(.matchTarget(target), .matchRuleType("SymLink"))
                // There should be no TAPI tasks
                results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateTAPI"))
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/usr/local/include/DoesNotSupportTextBasedAPI.h", "\(SRCROOT)/DoesNotSupportTextBasedAPI.h"])) { task in
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/DoesNotSupportTextBasedAPI.h", "/tmp/aProject.dst/usr/local/include"])
                }
            }
            results.checkTarget("UsesNonStandardExtension") { target in
                // There should be no symlink tasks
                results.checkNoTask(.matchTarget(target), .matchRuleType("SymLink"))
                // There should still be a TAPI task
                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/usr/local/include/UsesNonStandardExtension.h", "\(SRCROOT)/UsesNonStandardExtension.h"])) { task in
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/UsesNonStandardExtension.h", "/tmp/aProject.dst/usr/local/include"])
                }
            }
            results.checkTarget("StaticLibraryTarget") { target in
                // There should be no symlink tasks
                results.checkNoTask(.matchTarget(target), .matchRuleType("SymLink"))
                // There should be no TAPI tasks
                results.checkNoTask(.matchTarget(target), .matchRuleType("GenerateTAPI"))
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/usr/local/include/StaticLibraryTarget.h", "\(SRCROOT)/StaticLibraryTarget.h"])) { task in
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/StaticLibraryTarget.h", "/tmp/aProject.dst/usr/local/include"])
                }
            }

            // Ignore all Gate and build directory tasks.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

            // There should be no other tasks.
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }

        // Check an installapi release build with copy files enabled.
        let overrides = [
            "INSTALLAPI_COPY_PHASE": "YES",
        ]
        await tester.checkBuild(BuildParameters(action: .installAPI, configuration: "Release", overrides: overrides), runDestination: .macOS) { results in
            results.checkTarget("DynamicLibraryTarget") { target in
                // There should be one symlink task.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/Release/DynamicLibraryTarget.tbd", "../../../../aProject.dst/usr/local/lib/DynamicLibraryTarget.tbd"])) { _ in }

                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI")) { _ in }

                // There should be three CpHeader tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/usr/local/include/PrivateHeaderFile.h", "\(SRCROOT)/PrivateHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PrivateHeaderFile.h", "/tmp/aProject.dst/usr/local/include"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/usr/local/include/PublicHeaderFile.h", "\(SRCROOT)/PublicHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PublicHeaderFile.h", "/tmp/aProject.dst/usr/local/include"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/usr/local/include/DynamicLibraryTarget.h", "\(SRCROOT)/DynamicLibraryTarget.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/DynamicLibraryTarget.h", "/tmp/aProject.dst/usr/local/include"])
                }

                // Ignore all Gate and build directory tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
                results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }

                // There should be no other tasks.
                results.checkNoTask()

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }

    @Test(.requireSDKs(.macOS))
    func installhdrs() async throws {
        // Test running the installhdrs build action on a framework.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceOne.m"),
                    TestFile("SourceTwo.m"),
                    TestFile("SourceThree.swift"),
                    TestFile("ProjectHeaderFile.h"),
                    TestFile("PrivateHeaderFile.h"),
                    TestFile("PublicHeaderFile.h"),
                    TestFile("FrameworkTarget.h"),
                    TestFile("StringsResource.strings"),
                    TestFile("libdynamic.dylib"),
                    TestFile("StubFramework.framework"),
                    TestFile("Script-Input-Header.fake-input"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "DEFINES_MODULE": "YES",
                    "CODE_SIGN_IDENTITY": "-",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "FrameworkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: ["INFOPLIST_FILE": "MyInfo.plist"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                            "SourceTwo.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("FrameworkTarget.h", headerVisibility: .public),
                            TestBuildFile("PublicHeaderFile.h", headerVisibility: .public),
                            TestBuildFile("PrivateHeaderFile.h", headerVisibility: .private),
                            TestBuildFile("ProjectHeaderFile.h"),    // visibility: project
                        ]),
                        TestResourcesBuildPhase([
                            "StringsResource.strings",
                        ]),
                        TestFrameworksBuildPhase([
                            "libdynamic.dylib",
                        ]),
                        TestCopyFilesBuildPhase([
                            "StubFramework.framework",
                        ], destinationSubfolder: .frameworks),
                        TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "Foo", contents: "echo \"Running script\"\nexit 0\n",
                                                  inputs: ["Script-Input-Header.fake-input"], outputs: ["$(TARGET_BUILD_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/Script-Header.h"]),
                        TestShellScriptBuildPhase(name: "Always Run Script", originalObjectID: "Bar", contents: "echo \"Running script\"\nexit 0\n",
                                                  inputs: ["Script-Input-Header.fake-input"], outputs: ["$(TARGET_BUILD_DIR)/$(PUBLIC_HEADERS_FOLDER_PATH)/Script2-Header.h"],
                                                  alwaysRunForInstallHdrs: true),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        // Check an installhdrs release build.
        await tester.checkBuild(BuildParameters(action: .installHeaders, configuration: "Release"), runDestination: .macOS) { results in
            results.checkTarget("FrameworkTarget") { target in
                // There should be the expected number of mkdir and symlink tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { tasks in
                    #expect(tasks.count == 5)
                })
                results.checkTasks(.matchTarget(target), .matchRuleType("SymLink"), body: { tasks in
                    #expect(tasks.count == 5)
                })

                // There should be three CpHeader tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders/PrivateHeaderFile.h", "\(SRCROOT)/PrivateHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PrivateHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/PublicHeaderFile.h", "\(SRCROOT)/PublicHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PublicHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/FrameworkTarget.h", "\(SRCROOT)/FrameworkTarget.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/FrameworkTarget.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }

                // There should only be the PhaseScriptExecution that says it needs to always run (and the WriteAuxiliaryFile that writes it out).
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh")) { task in
                    task.checkRuleInfo(["PhaseScriptExecution", "Always Run Script", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh"])
                    task.checkCommandLine(["/bin/sh", "-c", "/tmp/Test/aProject/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Script-Input-Header.fake-input"),
                        .path("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh"),
                        .namePattern(.suffix("-fused-phase3-run-script")),
                        .namePattern(.prefix("target-")),
                    ])
                    task.checkOutputs([
                        .path("/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/Script2-Header.h"),
                    ])
                }

                // We should be generating and copying the module map file.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap")) { task in
                    task.checkRuleInfo(["Copy", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap"])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.DependencyMetadataFileList")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.DependencyMetadataFileList"])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.DependencyStaticMetadataFileList")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.DependencyStaticMetadataFileList"])
                }

                // There should be a 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }

                // Ignore all Gate and build directory tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

                // There should be no other tasks.
                results.checkNoTask()

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }

        // Check an installhdrs release build with copy files and shell script phases enabled.
        let overrides = [
            "INSTALLHDRS_COPY_PHASE": "YES",
            "INSTALLHDRS_SCRIPT_PHASE": "YES",
        ]
        await tester.checkBuild(BuildParameters(action: .installHeaders, configuration: "Release", overrides: overrides), runDestination: .macOS) { results in
            results.checkTarget("FrameworkTarget") { target in
                // There should be the expected number of mkdir and symlink tasks.
                results.checkTasks(.matchTarget(target), .matchRuleType("MkDir"), body: { tasks in
                    #expect(tasks.count == 6)
                })
                results.checkTasks(.matchTarget(target), .matchRuleType("SymLink"), body: { tasks in
                    #expect(tasks.count == 6)
                })

                // There should be two CpHeader tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders/PrivateHeaderFile.h", "\(SRCROOT)/PrivateHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PrivateHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/PublicHeaderFile.h", "\(SRCROOT)/PublicHeaderFile.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/PublicHeaderFile.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }

                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/FrameworkTarget.h", "\(SRCROOT)/FrameworkTarget.h"])) { task in
                    // Validate we also construct command lines.
                    task.checkCommandLine(["builtin-copy", "-exclude", ".DS_Store", "-exclude", "CVS", "-exclude", ".svn", "-exclude", ".git", "-exclude", ".hg", "-strip-unsigned-binaries", "-strip-deterministic", "-strip-tool", "strip", "-resolve-src-symlinks", "\(SRCROOT)/FrameworkTarget.h", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers"])
                }

                // We should be generating and copying the module map file.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("Copy"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap")) { task in
                    task.checkRuleInfo(["Copy", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Modules/module.modulemap", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/module.modulemap"])
                }

                // There should be a Copy task, since $(INSTALLHDRS_COPY_PHASE) is enabled.
                results.checkTask(.matchTarget(target), .matchRuleType("Copy")) { task in
                    task.checkRuleInfo(["Copy", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Frameworks/StubFramework.framework", "\(SRCROOT)/StubFramework.framework"])
                }

                // There should be a PhaseScriptExecution task, and a WriteAuxiliaryFile task to generate the script, since $(INSTALLHDRS_SCRIPT_PHASE) is enabled.
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Foo.sh")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Foo.sh"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Foo.sh")) { task in
                    task.checkRuleInfo(["PhaseScriptExecution", "Run Script", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Foo.sh"])
                    task.checkCommandLine(["/bin/sh", "-c", "/tmp/Test/aProject/build/aProject.build/Release/FrameworkTarget.build/Script-Foo.sh"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Script-Input-Header.fake-input"),
                        .path("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Foo.sh"),
                        .namePattern(.suffix("-fused-phase2-copy-files")),
                        .namePattern(.prefix("target-")),
                    ])
                    task.checkOutputs([
                        .path("/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/Script-Header.h"),
                    ])
                }

                // There should only be the PhaseScriptExecution that says it needs to always run (and the WriteAuxiliaryFile that writes it out).
                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh"])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("PhaseScriptExecution"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh")) { task in
                    task.checkRuleInfo(["PhaseScriptExecution", "Always Run Script", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh"])
                    task.checkCommandLine(["/bin/sh", "-c", "/tmp/Test/aProject/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh"])

                    task.checkInputs([
                        .path("\(SRCROOT)/Script-Input-Header.fake-input"),
                        .path("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Script-Bar.sh"),
                        .namePattern(.suffix("-fused-phase3-run-script")),
                        .namePattern(.prefix("target-")),
                    ])
                    task.checkOutputs([
                        .path("/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework/Versions/A/Headers/Script2-Header.h"),
                    ])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.DependencyMetadataFileList")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.DependencyMetadataFileList"])
                }

                results.checkTask(.matchTarget(target), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItem("\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.DependencyStaticMetadataFileList")) { task in
                    task.checkRuleInfo(["WriteAuxiliaryFile", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.DependencyStaticMetadataFileList"])
                }

                // There should be a 'Touch' task.
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "/tmp/aProject.dst/Library/Frameworks/FrameworkTarget.framework"])) { _ in }

                // Ignore all Gate and build directory tasks.
                results.checkTasks(.matchRuleType("Gate")) { _ in }
                results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }

                // There should be no other tasks.
                results.checkNoTask()

                // There shouldn't be any diagnostics.
                results.checkNoDiagnostics()
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }


    /// Test running an install on a product to a location which contains an upwards path component ('..'), as path normalization and provisional task nullification can results in some build artifacts not being produced if paths don't line up.
    @Test(.requireSDKs(.macOS))
    func installWithUpwardsPath() async throws {
        // Test running the installhdrs build action on a framework.
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceOne.m"),
                    TestFile("PrivateHeaderFile.h"),
                    TestFile("PublicHeaderFile.h"),
                    TestFile("StringsResource.strings"),
                    TestFile("StubFramework.framework"),
                    TestFile("Service.xpc"),
                    TestFile("Extension.appex"),
                    TestFile("Info.plist"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Release", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "CODE_SIGN_IDENTITY": "-",
                    "RETAIN_RAW_BINARIES": "YES",
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "FrameworkTarget",
                    type: .framework,
                    buildConfigurations: [
                        TestBuildConfiguration("Release", buildSettings: [
                            "INFOPLIST_FILE": "Info.plist",
                            // The INSTALL_PATH definition here is the point of the test - we want to make sure tasks get created when there's a '..' in the path.
                            "INSTALL_PATH": "/Applications/SomeOtherApp.app/Frameworks/../InternalFrameworks",
                        ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([
                            "SourceOne.m",
                        ]),
                        TestHeadersBuildPhase([
                            TestBuildFile("PublicHeaderFile.h", headerVisibility: .public),
                            TestBuildFile("PrivateHeaderFile.h", headerVisibility: .private),
                        ]),
                        TestResourcesBuildPhase([
                            "StringsResource.strings",
                        ]),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("StubFramework.framework", codeSignOnCopy: true),
                        ], destinationSubfolder: .frameworks, onlyForDeployment: false),
                        // The destination here matches how the "XPCServices" popup in the build phase UI populates it.  See <rdar://problem/15366863>
                        TestCopyFilesBuildPhase([
                            TestBuildFile("Service.xpc", codeSignOnCopy: true),
                        ], destinationSubfolder: .builtProductsDir, destinationSubpath: "$(CONTENTS_FOLDER_PATH)/XPCServices", onlyForDeployment: false),
                        TestCopyFilesBuildPhase([
                            TestBuildFile("Extension.appex", codeSignOnCopy: true),
                        ], destinationSubfolder: .plugins, onlyForDeployment: false),
                    ]
                ),
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        let fs = PseudoFS()

        try fs.createDirectory(Path(SRCROOT).join("StubFramework.framework/Versions/A"), recursive: true)
        try fs.createDirectory(Path(SRCROOT).join("StubFramework.framework/Versions/Current"), recursive: true)
        try fs.write(Path(SRCROOT).join("StubFramework.framework/Versions/A/StubFramework"), contents: "binary")

        // Check the Release build.
        await tester.checkBuild(BuildParameters(action: .install, configuration: "Release"), runDestination: .macOS, fs: fs) { results in
            // Ignore all tasks we don't want to check.
            results.checkTasks(.matchRuleType("Gate")) { _ in }
            results.checkTasks(.matchRuleType("WriteAuxiliaryFile")) { _ in }
            results.checkTasks(.matchRuleType("CreateBuildDirectory")) { _ in }
            results.checkTasks(.matchRuleType("RegisterExecutionPolicyException")) { _ in }

            results.checkTarget("FrameworkTarget") { target in
                // There should be the expected number of mkdir and symlink tasks.
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/Headers"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/Resources"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/Frameworks"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/PlugIns"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["MkDir", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/XPCServices"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/Current", "A"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/FrameworkTarget", "Versions/Current/FrameworkTarget"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Headers", "Versions/Current/Headers"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/PrivateHeaders", "Versions/Current/PrivateHeaders"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Resources", "Versions/Current/Resources"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Frameworks", "Versions/Current/Frameworks"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/PlugIns", "Versions/Current/PlugIns"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/XPCServices", "Versions/Current/XPCServices"])) { _ in }
                // This is the symlink in the built products dir pointing to the content in the dstroot.
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "\(SRCROOT)/build/Release/BuiltProducts/FrameworkTarget.framework", "../../../../../aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework"])) { _ in }

                // There should be two CpHeader tasks.
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/Headers/PublicHeaderFile.h", "\(SRCROOT)/PublicHeaderFile.h"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CpHeader", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/PrivateHeaders/PrivateHeaderFile.h", "\(SRCROOT)/PrivateHeaderFile.h"])) { _ in }

                // There should be tasks to create the binary.
                results.checkTask(.matchTarget(target), .matchRule(["CompileC", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/Objects-normal/x86_64/SourceOne.o", "\(SRCROOT)/SourceOne.m", "normal", "x86_64", "objective-c", "com.apple.compilers.llvm.clang.1_0.compiler"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRuleType("Ld"), .matchRuleItem("/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget")) { _ in }

                results.checkTask(.matchTarget(target), .matchRuleType("GenerateTAPI"), .matchRuleItem("/tmp/Test/aProject/build/EagerLinkingTBDs/Release/FrameworkTarget.framework/Versions/A/FrameworkTarget.tbd")) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SymLink", "/tmp/Test/aProject/build/EagerLinkingTBDs/Release/FrameworkTarget.framework/FrameworkTarget.tbd", "/tmp/Test/aProject/build/EagerLinkingTBDs/Release/FrameworkTarget.framework/Versions/A/FrameworkTarget.tbd"])) { _ in }

                // There should be the expected copying and processing tasks.
                results.checkTask(.matchTarget(target), .matchRule(["ProcessInfoPlistFile", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/Resources/Info.plist", "\(SRCROOT)/Info.plist"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CopyStringsFile", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/Resources/StringsResource.strings", "\(SRCROOT)/StringsResource.strings"])) { _ in }

                // There should be tasks to copy and sign the embedded bundles.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/Frameworks/StubFramework.framework", "\(SRCROOT)/StubFramework.framework"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/Frameworks/StubFramework.framework/Versions/A"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/XPCServices/Service.xpc", "\(SRCROOT)/Service.xpc"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/XPCServices/Service.xpc"]))
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/PlugIns/Extension.appex", "\(SRCROOT)/Extension.appex"])) { _ in }
                results.checkNoTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/PlugIns/Extension.appex"]))

                // There should be the expected postprocessing tasks task.
                results.checkTask(.matchTarget(target), .matchRule(["Strip", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A/FrameworkTarget"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SetOwnerAndGroup", "exampleUser:exampleGroup", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["SetMode", "u+w,go-w,a+rX", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackaging", "", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.framework.xcent"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["ProcessProductPackagingDER", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.framework.xcent", "\(SRCROOT)/build/aProject.build/Release/FrameworkTarget.build/FrameworkTarget.framework.xcent.der"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["CodeSign", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework/Versions/A"])) { _ in }
                results.checkTask(.matchTarget(target), .matchRule(["Touch", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework"])) { _ in }

                // There should be a task to copy the binary into the SYMROOT, since RETAIN_RAW_BINARIES is enabled.
                results.checkTask(.matchTarget(target), .matchRule(["Copy", "\(SRCROOT)/build/FrameworkTarget.framework", "/tmp/aProject.dst/Applications/SomeOtherApp.app/InternalFrameworks/FrameworkTarget.framework"])) { _ in }
            }

            // PseudoFS doesn't support symlinks
            results.checkWarning(.prefix("Couldn't resolve framework symlink for '\(SRCROOT)/StubFramework.framework/Versions/Current':"))

            // There should be no other tasks.
            results.checkNoTask()

            // There shouldn't be any diagnostics.
            results.checkNoDiagnostics()

            // Check there are no other targets.
            #expect(results.otherTargets == [])
        }
    }

}
