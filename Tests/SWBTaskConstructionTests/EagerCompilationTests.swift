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

import Foundation
import Testing

import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct EagerCompilationTests: CoreBasedTests {
    var eagerCompilationProject: TestProject {
        get async throws {
            let allEFiles: [TestFile] = (0..<100).map { n in TestFile("E_\(n).h") }
            let allEBuildFiles: [TestBuildFile] = (0..<100).map { n in TestBuildFile("E_\(n).h", headerVisibility: .public) }

            return try await TestProject(
                "aProject",
                groupTree: TestGroup("Sources", path: "Sources", children: [
                    TestFile("A.m"),
                    TestFile("A.fake-data"),
                    TestFile("B.m"),
                    TestFile("C.m"),
                    TestFile("D.m"),
                    TestFile("E.h"),
                    TestFile("E.m"),
                    TestFile("F.m"),
                    TestFile("F.modulemap"),
                    TestFile("G.m"),
                    TestFile("G.modulemap"),
                    TestFile("H.swift"),
                ] + allEFiles),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "EAGER_COMPILATION_REQUIRE": "true", // to verify there is no warning for targets with no scripts
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "EAGER_PARALLEL_COMPILATION_DISABLE": "YES",
                        "TAPI_EXEC": tapiToolPath.str,
                    ]
                )],
                targets: [
                    TestStandardTarget("A", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("A.m")
                        ]),
                        TestCopyFilesBuildPhase([TestBuildFile("A.fake-data")],
                                                destinationSubfolder: .builtProductsDir,
                                                destinationSubpath: "$(PUBLIC_HEADERS_FOLDER_PATH)",
                                                onlyForDeployment: false)
                    ], dependencies: ["E", "F", "G"]),
                    TestStandardTarget("B", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("B.m")
                        ])
                    ], dependencies: ["A"]),
                    TestStandardTarget("C", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("C.m")
                        ])
                    ]),
                    TestStandardTarget("D", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("D.m")
                        ])
                    ], dependencies: ["B", "C"]),
                    TestStandardTarget("E", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("E.m")]),
                        TestCopyFilesBuildPhase([TestBuildFile("E.h", headerVisibility: .public)] + allEBuildFiles,
                                                destinationSubfolder: .builtProductsDir,
                                                destinationSubpath: "$(PUBLIC_HEADERS_FOLDER_PATH)",
                                                onlyForDeployment: false),
                    ]),
                    TestStandardTarget("F", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("F.m")]),
                        TestCopyFilesBuildPhase([TestBuildFile("F.modulemap")],
                                                destinationSubfolder: .builtProductsDir,
                                                destinationSubpath: "$(CONTENTS_FOLDER_PATH)/Modules",
                                                onlyForDeployment: false),
                    ]),
                    TestStandardTarget("G", type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                                        "DEFINES_MODULE": "YES",
                                        "MODULEMAP_FILE_CONTENTS": "foo",
                                       ])],
                                       buildPhases: [
                                        TestSourcesBuildPhase([TestBuildFile("G.m")]),
                                       ]
                                      ),
                    TestStandardTarget("H", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("H.swift")
                        ])
                    ], dependencies: ["E", "F", "G"]),
                ])
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationSerialBuild() async throws {
        let tester = try await TaskConstructionTester(getCore(), eagerCompilationProject)
        let parameters = BuildParameters(configuration: "Debug", overrides: ["DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING": "YES"])
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: false, useImplicitDependencies: false, useDryRun: false)

        let checks = [
            ("B", ["A"]),
            ("C", ["B"]),
            ("D", ["A", "B", "C"])
        ]

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            for (after, befores) in checks {
                results.checkTask(.matchTargetName(after), .matchRuleType("CompileC")) { compileAfter in
                    // compilation should wait for dependencies to compile, but should not wait for linking.
                    for before in befores {
                        results.checkTaskFollows(compileAfter, .matchTargetName(before), .matchRuleType("CompileC"))

                        // with eager compilation disabled, the dependent target will have to wait for linking (among other things)
                        results.checkTaskFollows(compileAfter, .matchTargetName(before), .matchRuleType("Ld"))
                    }
                }

                results.checkTask(.matchTargetName(after), .matchRuleType("MkDir"), .matchRuleItemBasename("\(after).framework")) { mkdir in
                    // mkdir is an immediate task. it shouldn't really wait for anything from other targets, but it will
                    // if eager compilation is disabled.
                    for before in befores {
                        results.checkTaskFollows(mkdir, .matchTargetName(before), .matchRuleType("MkDir"), .matchRuleItemBasename("\(before).framework"))
                        results.checkTaskFollows(mkdir, .matchTargetName(before), .matchRuleType("CompileC"))
                    }
                }
            }

            for target in ["A", "B", "C", "D", "E", "F", "G", "H"] {
                results.checkWarning(.equal("target '\(target)' requires eager compilation, but parallel target builds are disabled, which prevent eager compilation (in target '\(target)' from project 'aProject')"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationParallelBuild() async throws {
        let tester = try await TaskConstructionTester(getCore(), eagerCompilationProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        let checks = [
            ("A", ["E", "F", "G"]),
            ("B", ["A"]),
            ("D", ["A", "B", "C"]),
            ("H", ["E", "F", "G"]),
        ]

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            for (after, befores) in checks {
                results.checkTask(.matchTargetName(after), .matchRuleItemPattern(.or("CompileC", "SwiftDriver Compilation"))) { compileAfter in
                    for before in befores {
                        // Make sure copying E's headers happens prior to compiling A's sources
                        // By default, Copy Files build phases are not compilation requirements unless they contain header files
                        // Avoid using `checkTasks` so that we can keep them in the task list and check them again during the execution of the loop.
                        let copyHeaderTasks = results.findMatchingTasks([.matchTargetName(before), .matchRuleType("Copy")])
                        for copyHeaderTask in copyHeaderTasks {
                            // We DON'T want this check for A, because its copy files phase does not have header files, so we keep the parallelism
                            if before != "A" {
                                results.checkTaskFollows(compileAfter, antecedent: copyHeaderTask)
                            } else {
                                results.checkTaskDoesNotFollow(compileAfter, antecedent: copyHeaderTask)
                            }
                        }

                        // Make sure the module map is in place prior to compiling sources that depend on it.
                        if ["G"].contains(before) {
                            // Avoid using `checkTask` so that we can keep it in the task list and check it again during the execution of the loop.
                            if let copyModuleMapTask = results.findOneMatchingTask([.matchTargetName(before), .matchRuleType("Copy"), .matchRuleItemBasename("module.modulemap")]) {
                                results.checkTaskFollows(compileAfter, antecedent: copyModuleMapTask)
                            }
                        }

                        results.checkTaskFollows(compileAfter, .matchTargetName(before), .matchRuleType("CompileC"))

                        // If we have a headers phase (or now, a copy phase with headers or module maps),
                        // compiling A's sources will transitively depend on linking E
                        // because compiling sources depends on the modules of dependent libraries
                        if ["E", "F"].contains(before) {
                            results.checkTaskFollows(compileAfter, .matchTargetName(before), .matchRuleType("Ld"))
                        } else {
                            results.checkTaskDoesNotFollow(compileAfter, .matchTargetName(before), .matchRuleType("Ld"))
                        }
                    }
                }

                results.checkTask(.matchTargetName(after), .matchRuleType("MkDir"), .matchRuleItemBasename("\(after).framework")) { mkdir in
                    // mkdir is an immediate task. it shouldn't really wait for anything from other targets.
                    for before in befores {
                        results.checkTaskDoesNotFollow(mkdir, .matchTargetName(before), .matchRuleType("MkDir"), .matchRuleItemBasename("\(before).framework"))
                        results.checkTaskDoesNotFollow(mkdir, .matchTargetName(before), .matchRuleType("CompileC"))
                    }
                }
            }

            results.checkTask(.matchTargetName("C"), .matchRuleType("CompileC")) { compileC in
                results.checkTaskDoesNotFollow(compileC, .matchTargetName("B"), .matchRuleType("CompileC"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationWithScriptsAfterCompiling() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                    TestShellScriptBuildPhase(name: "A Script", originalObjectID: "A Script", contents: "true", alwaysOutOfDate: true)
                ]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("B.m")])
                ], dependencies: ["A"]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("CompileC"))
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("Ld"))
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("MkDir"), .matchRuleItemBasename("B.framework")) { task in
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("MkDir"), .matchRuleItemBasename("A.framework"))
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("CompileC"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationWithScriptsBeforeCompiling() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                ]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestShellScriptBuildPhase(name: "B Script", originalObjectID: "B Script", contents: "true", alwaysOutOfDate: true),
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("CompileC"))
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("Ld"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("PhaseScriptExecution")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("CompileC"))
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("Ld"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("MkDir"), .matchRuleItemBasename("B.framework")) { task in
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("MkDir"), .matchRuleItemBasename("A.framework"))
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("CompileC"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationWithScriptsAllowed() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                    "EAGER_COMPILATION_ALLOW_SCRIPTS": "true",
                    "EAGER_COMPILATION_REQUIRE": "true",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                    TestShellScriptBuildPhase(name: "A Script", originalObjectID: "A Script", contents: "true", alwaysOutOfDate: true),
                ]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestShellScriptBuildPhase(name: "B Script", originalObjectID: "B Script", contents: "true", alwaysOutOfDate: true),
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { task in
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("Ld"))
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("PhaseScriptExecution")) { task in
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("Ld"))
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationBasicsWithSandboxedScripts() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                    TestShellScriptBuildPhase(name: "A Script", originalObjectID: "A Script", contents: "true", alwaysOutOfDate: true),
                ]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestShellScriptBuildPhase(name: "B Script", originalObjectID: "B Script", contents: "true", alwaysOutOfDate: true),
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { task in
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("Ld"))
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("PhaseScriptExecution")) { task in
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("Ld"))
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func sandboxingDoesNotImplyEagerCompilationForAggregateTargetScripts() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                ]
            )],
            targets: [
                TestAggregateTarget("Aggregate", buildPhases: [
                    TestShellScriptBuildPhase(name: "Script", originalObjectID: "Script", contents: "true", alwaysOutOfDate: true),
                ], dependencies: ["A"]),
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                ]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTask(.matchTargetName("Aggregate"), .matchRuleType("PhaseScriptExecution")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("-end")))
            }
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func headerGeneratingShellScriptsAreCompilationRequirements() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                    TestShellScriptBuildPhase(name: "A Script", originalObjectID: "A Script", contents: "touch /foo/bar.h", outputs: ["/foo/bar.h"], alwaysOutOfDate: false),
                ]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("Ld"))
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationWithTestHost() async throws {
        let core = try await getCore()
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .application, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                ]),
                TestStandardTarget("B", type: .unitTest, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                    "SDKROOT": "macosx",
                    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/A.app/Contents/MacOS/A",
                    "BUNDLE_LOADER": "$(TEST_HOST)",
                ])], buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
            ])

        let tester = try TaskConstructionTester(core, testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        let unitTestFrameworkSubpaths = [
            "Library/Frameworks/XCTest.framework",
            "Library/Frameworks/Testing.framework",
            "Library/PrivateFrameworks/XCTestCore.framework",
            "Library/PrivateFrameworks/XCUnit.framework",
            "Library/Frameworks/XCUIAutomation.framework",
            "Library/PrivateFrameworks/XCTestSupport.framework",
            "Library/PrivateFrameworks/XCTAutomationSupport.framework",
            "usr/lib/libXCTestBundleInject.dylib",
            "usr/lib/libXCTestSwiftSupport.dylib",
        ]

        // Create files in the filesystem so they're known to exist.
        let fs = PseudoFS()
        for frameworkSubpath in unitTestFrameworkSubpaths {
            let frameworkPath = core.developerPath.path.join("Platforms/MacOSX.platform/Developer").join(frameworkSubpath)
            try fs.createDirectory(frameworkPath.dirname, recursive: true)
            try fs.write(frameworkPath, contents: ByteString(encodingAsUTF8: frameworkPath.basename))
        }

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest, fs: fs) { results in
            results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { task in
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("CompileC"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("Ld")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("Ld"))
            }

            results.checkTask(.matchTargetName("A"), .matchRuleType("CodeSign"), .matchRuleItemBasename("A.app")) { task in
                results.checkTaskFollows(task, .matchTargetName("B"), .matchRuleType("CodeSign"), .matchRuleItemBasename("B.xctest"))
                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationWithDeploymentLocation() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                ]),
                TestStandardTarget("B", type: .framework, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                    "DEPLOYMENT_LOCATION": "true",
                ])], buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { task in
                results.checkTaskDoesNotFollow(task, .matchTargetName("A"), .matchRuleType("CompileC"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("Ld")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("Ld"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("CodeSign")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("CodeSign"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationRequiredWithDeploymentLocationAndNestedInstallPaths() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                    "EAGER_COMPILATION_REQUIRE": "true",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                    "DEPLOYMENT_LOCATION": "true",
                    "INSTALL_PATH": "/Library/Frameworks"
                ])], buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                ]),
                TestStandardTarget("B", type: .framework, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                    "DEPLOYMENT_LOCATION": "true",
                    "INSTALL_PATH": "/Library/Frameworks/A.framework/Versions/A/Frameworks"
                ])], buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkWarning(.contains("target 'B' requires eager compilation, but DEPLOYMENT_LOCATION is set and the build directory of 'A' encloses the build directory of 'B'."))
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationDisabledByTarget() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
                TestFile("C.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                ]),
                TestStandardTarget("B", type: .framework, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                    "EAGER_COMPILATION_DISABLE": "true",
                ])], buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
                TestStandardTarget("C", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("C.m")]),
                ], dependencies: ["B"])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("CompileC"))
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("Ld"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("MkDir"), .matchRuleItemBasename("B.framework")) { task in
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("MkDir"), .matchRuleItemBasename("A.framework"))
                results.checkTaskFollows(task, .matchTargetName("A"), .matchRuleType("CompileC"))
            }

            results.checkTask(.matchTargetName("C"), .matchRuleType("CompileC")) { task in
                results.checkTaskFollows(task, .matchTargetName("B"), .matchRuleType("CompileC"))
                results.checkTaskFollows(task, .matchTargetName("B"), .matchRuleType("Ld"))
            }

            // immediate tasks should still be immediate, even if the compilation tasks have to wait for the disabled target to finish
            results.checkTask(.matchTargetName("C"), .matchRuleType("MkDir"), .matchRuleItemBasename("C.framework")) { task in
                results.checkTaskDoesNotFollow(task, .matchTargetName("B"), .matchRuleType("MkDir"), .matchRuleItemBasename("B.framework"))
                results.checkTaskDoesNotFollow(task, .matchTargetName("B"), .matchRuleType("CompileC"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationDisabledAndRequiredByTarget() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                    "EAGER_COMPILATION_REQUIRE": "true",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                ]),
                TestStandardTarget("B", type: .framework, buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [
                    "EAGER_COMPILATION_DISABLE": "true",
                ])], buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkWarning(.contains("target 'B' has both required and disabled eager compilation"))
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerCompilationRequiredByTarget() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                    "EAGER_COMPILATION_REQUIRE": "true",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("A.m")]),
                    TestShellScriptBuildPhase(name: "Run Script", originalObjectID: "abcd", contents: "echo foo", alwaysOutOfDate: true),
                ]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("B.m")]),
                ], dependencies: ["A"]),
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkWarning(.contains("target 'A' requires eager compilation, but build phase 'Run Script' is delaying eager compilation"))
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerParallelCompilation() async throws {
        let project = TestProject(
            "Eager C Compilation",
            groupTree: TestGroup(
                "Group",
                path: "Sources",
                children: [
                    TestFile("A.h"),
                    TestFile("A.c"),
                    TestFile("B.c"),
                ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "ALWAYS_SEARCH_USER_PATHS": "false",
                    "EAGER_COMPILATION_REQUIRE": "YES",
                ])],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                    TestSourcesBuildPhase([TestBuildFile("A.c")]),
                ]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([TestBuildFile("B.c")]),
                ], dependencies: ["A"]),
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), project)
        let parameters = BuildParameters(configuration: "Debug")
        let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

        await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
            results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { compileAfter in
                // compilation should not wait for dependencies to compile
                results.checkTaskDoesNotFollow(compileAfter, .matchTargetName("A"), .matchRuleType("CompileC"))
                results.checkTaskDoesNotFollow(compileAfter, .matchTargetName("A"), .matchRuleType("Ld"))

                results.checkTaskFollows(compileAfter, .matchTargetName("A"), .matchRuleType("CpHeader"))
            }

            results.checkTask(.matchTargetName("B"), .matchRuleType("MkDir"), .matchRuleItemBasename("B.framework")) { mkdir in
                // mkdir is an immediate task. it shouldn't really wait for anything from other targets.
                results.checkTaskDoesNotFollow(mkdir, .matchTargetName("A"), .matchRuleType("MkDir"), .matchRuleItemBasename("A.framework"))
                results.checkTaskDoesNotFollow(mkdir, .matchTargetName("A"), .matchRuleType("CompileC"))
            }

            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerParallelCompilation_HeaderGeneratingShellScript() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourceRoot = tmpDir.join("Project")

            let project = TestProject(
                "Eager C Compilation - With header generating shell script phase",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("A.c"),
                        TestFile("B.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "EAGER_COMPILATION_REQUIRE": "NO",
                    ])],
                targets: [
                    TestStandardTarget("A", type: .framework, buildPhases: [
                        TestShellScriptBuildPhase(name: "Run Script Phase", originalObjectID: "abc", contents: "echo \"Hello world\"", inputs: [], outputs: [sourceRoot.join("Sources").join("A.h").str]),
                        TestSourcesBuildPhase([TestBuildFile("A.c")])
                    ]),
                    TestStandardTarget("B", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("B.c")])
                    ], dependencies: ["A"]),
                ]
            )

            let tester = try await TaskConstructionTester(getCore(), project)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { compileAfter in
                    // compilation should not wait for dependencies to compile
                    results.checkTaskDoesNotFollow(compileAfter, .matchTargetName("A"), .matchRuleType("CompileC"))
                    results.checkTaskDoesNotFollow(compileAfter, .matchTargetName("A"), .matchRuleType("Ld"))

                    // compilation should wait for dependencies to be module ready
                    for fileName in ["Script-abc.sh", "A.hmap", "A-own-target-headers.hmap", "A-project-headers.hmap", "A-all-non-framework-target-headers.hmap", "A-all-target-headers.hmap", "A-generated-files.hmap"] {
                        results.checkTaskFollows(compileAfter, .matchTargetName("A"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(fileName)))
                    }
                    results.checkTaskFollows(compileAfter, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
                    results.checkTaskFollows(compileAfter, .matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("modules-ready")))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("MkDir"), .matchRuleItemBasename("B.framework")) { mkdir in
                    // mkdir is an immediate task. it shouldn't really wait for anything from other targets.
                    results.checkTaskDoesNotFollow(mkdir, .matchTargetName("A"), .matchRuleType("MkDir"), .matchRuleItemBasename("A.framework"))
                    results.checkTaskDoesNotFollow(mkdir, .matchTargetName("A"), .matchRuleType("CompileC"))
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerParallelCompilation_MixedProject() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourceRoot = tmpDir.join("Project")

            let project = try await TestProject(
                "Eager C Compilation - With Swift and Clang targets",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("A.h"),
                        TestFile("A.c"),
                        TestFile("A.swift"),
                        TestFile("B.h"),
                        TestFile("B.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.1",
                    ])],
                targets: [
                    TestStandardTarget("A", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("A.c"), TestBuildFile("A.swift")])
                    ]),
                    TestStandardTarget("B", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("B.c")])
                    ], dependencies: ["A"]),
                ]
            )

            let tester = try await TaskConstructionTester(getCore(), project)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkTask(.matchTargetName("A"), .matchRuleType("CompileC")) { compileAfter in
                    results.checkTaskFollows(compileAfter, .matchTargetName("A"), .matchRuleType("SwiftDriver Compilation Requirements"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { compileAfter in
                    // compilation should not wait for dependencies to compile
                    results.checkTaskDoesNotFollow(compileAfter, .matchTargetName("A"), .matchRuleType("CompileC"))
                    results.checkTaskDoesNotFollow(compileAfter, .matchTargetName("A"), .matchRuleType("Ld"))

                    // compilation should wait for dependencies to be module ready
                    for fileName in ["A.hmap", "A-own-target-headers.hmap", "A-project-headers.hmap", "A-all-non-framework-target-headers.hmap", "A-all-target-headers.hmap", "A-generated-files.hmap"] {
                        results.checkTaskFollows(compileAfter, .matchTargetName("A"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix(fileName)))
                    }
                    results.checkTaskFollows(compileAfter, .matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("modules-ready")))
                    results.checkTaskFollows(compileAfter, .matchTargetName("A"), .matchRuleType("SwiftDriver Compilation Requirements"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("MkDir"), .matchRuleItemBasename("B.framework")) { mkdir in
                    // mkdir is an immediate task. it shouldn't really wait for anything from other targets.
                    results.checkTaskDoesNotFollow(mkdir, .matchTargetName("A"), .matchRuleType("MkDir"), .matchRuleItemBasename("A.framework"))
                    results.checkTaskDoesNotFollow(mkdir, .matchTargetName("A"), .matchRuleType("CompileC"))
                }

                results.checkNoDiagnostics()
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerParallelCompilation_GateTasks() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourceRoot = tmpDir.join("Project")

            let project = try await TestProject(
                "Eager C Compilation - Gate Tasks Ordering",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("A.c"),
                        TestFile("A.swift"),
                        TestFile("B.c"),
                        TestFile("C.c"),
                        TestFile("D.swift"),
                        TestFile("D.h"),
                        TestFile("D.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.1",
                    ])],
                targets: [
                    TestStandardTarget("A", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("A.c"), TestBuildFile("A.swift")])
                    ]),
                    TestStandardTarget("B", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("B.c")])
                    ], dependencies: ["A"]),
                    TestStandardTarget("C", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("C.c")])
                    ], dependencies: ["A"]),
                    TestStandardTarget("D", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("D.c"), TestBuildFile("D.swift")])
                    ], dependencies: ["C"]),
                ]
            )

            let tester = try await TaskConstructionTester(getCore(), project)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                func verifyDependencyChain(_ tasks: [[TaskCondition]], sourceLocation: SourceLocation = #_sourceLocation) {
                    // order doesn't matter for one or less tasks in a chain
                    guard tasks.count > 1 else { return }
                    // create  copy to operate on
                    let results = results.createCopy()
                    for index in tasks.index(after: tasks.startIndex)..<tasks.endIndex {
                        let dependency = tasks[tasks.index(before: index)]
                        let task = tasks[index]
                        results.checkTask(task, sourceLocation: sourceLocation) { foundTask in
                            results.checkTaskFollows(foundTask, dependency, sourceLocation: sourceLocation)
                        }
                    }
                }

                func noDependency(from task1: [TaskCondition], to task2: [TaskCondition], sourceLocation: SourceLocation = #_sourceLocation) {
                    let res = results.createCopy()
                    res.checkTask(task1, sourceLocation: sourceLocation) { foundTask in
                        res.checkTaskDoesNotFollow(foundTask, task2, sourceLocation: sourceLocation)
                    }
                }

                // target A
                verifyDependencyChain([
                    .gateTask("A", suffix: "begin-compiling"),
                    .emitSwiftCompilationRequirements("A"),
                    .compileC("A", fileName: "A.c"),
                    .gateTask("A", suffix: "end")
                ])

                // target A module ready
                verifyDependencyChain([
                    .emitSwiftCompilationRequirements("A"),
                    .gateTask("A", suffix: "modules-ready"),
                ])

                // target A <- B
                verifyDependencyChain([
                    .emitSwiftCompilationRequirements("A"),
                    .gateTask("A", suffix: "modules-ready"),
                    .compileC("B", fileName: "B.c"),
                    .gateTask("B", suffix: "end"),
                ])

                // target A <- C
                verifyDependencyChain([
                    .emitSwiftCompilationRequirements("A"),
                    .gateTask("A", suffix: "modules-ready"),
                    .compileC("C", fileName: "C.c"),
                    .gateTask("C", suffix: "end"),
                ])

                // target D
                verifyDependencyChain([
                    .gateTask("D", suffix: "begin-compiling"),
                    .emitSwiftCompilationRequirements("D"),
                    .gateTask("D", suffix: "modules-ready"),
                ])

                // target D
                verifyDependencyChain([
                    .gateTask("D", suffix: "immediate"),
                    [.matchTargetName("D"), .matchRuleType("WriteAuxiliaryFile"), .matchRuleItemPattern(.suffix("D.hmap"))],
                    .gateTask("D", suffix: "modules-ready"),
                ])

                // compiling should be done in parallel
                noDependency(from: .compileC("B", fileName: "B.c"),
                             to: .compileC("A", fileName: "A.c"))

                // modules ready should not depend on compiling C
                noDependency(from: .gateTask("A", suffix: "modules-ready"),
                             to: .compileC("A", fileName: "A.c"))
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerParallelCompilation_Precompile() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourceRoot = tmpDir.join("Project")

            let project = TestProject(
                "Eager C Compilation - Precompiled headers",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("A.h"),
                        TestFile("A.c"),
                        TestFile("A.pch"),
                        TestFile("B.c"),
                        TestFile("B.pch"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                    ])],
                targets: [
                    TestStandardTarget("A",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug",
                                                                                    buildSettings: ["GCC_PREFIX_HEADER": "Sources/A.pch"])],
                                       buildPhases: [
                                        TestSourcesBuildPhase([TestBuildFile("A.c")])
                                       ]),
                    TestStandardTarget("B",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug",
                                                                                    buildSettings: ["GCC_PREFIX_HEADER": "Sources/B.pch"])],
                                       buildPhases: [
                                        TestSourcesBuildPhase([TestBuildFile("B.c")])
                                       ],
                                       dependencies: ["A"]),
                ]
            )

            let tester = try await TaskConstructionTester(getCore(), project)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkTask(.matchTargetName("A"), .matchRuleType("CompileC")) { compileAfter in
                    results.checkTaskFollows(compileAfter, .matchTargetName("A"), .matchRuleType("ProcessPCH"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("ProcessPCH")) { compileAfter in
                    results.checkTaskDoesNotFollow(compileAfter, .matchTargetName("A"), .matchRuleType("CompileC"))
                    results.checkTaskDoesNotFollow(compileAfter, .gateTask("A", suffix: "end"))
                    results.checkTaskFollows(compileAfter, .gateTask("A", suffix: "modules-ready"))
                    results.checkTaskFollows(compileAfter, .gateTask("A", suffix: "begin-compiling"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { compileAfter in
                    results.checkTaskFollows(compileAfter, .matchTargetName("B"), .matchRuleType("ProcessPCH"))
                    results.checkTaskFollows(compileAfter, .gateTask("A", suffix: "modules-ready"))
                    results.checkTaskFollows(compileAfter, .gateTask("A", suffix: "begin-compiling"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func intentCompilation() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourceRoot = tmpDir.join("Project")

            let project = try await TestProject(
                "IntentProject",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("A.h"),
                        TestFile("A.intentdefinition"),
                        TestFile("A.mlmodel"),
                        TestFile("A.swift"),
                        TestFile("A.c"),
                        TestFile("B.c"),
                        TestFile("B.swift"),
                        TestFile("C.h"),
                        TestFile("C.m"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.2",
                        "INTENTS_CODEGEN_LANGUAGE": "Objective-C",
                        "COREML_CODEGEN_LANGUAGE": "Objective-C",
                    ])],
                targets: [
                    TestStandardTarget("CodegenFramework",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestHeadersBuildPhase([]),
                                        TestSourcesBuildPhase([
                                            TestBuildFile("A.intentdefinition", intentsCodegenVisibility: .public),
                                            TestBuildFile("A.mlmodel", intentsCodegenVisibility: .public),
                                        ])
                                       ]
                                      ),
                    TestStandardTarget("A",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                                        TestSourcesBuildPhase([
                                            TestBuildFile("A.c"),
                                            TestBuildFile("A.swift"),
                                            TestBuildFile("A.intentdefinition", intentsCodegenVisibility: .public),
                                        ])
                                       ]),
                    TestStandardTarget("B",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase([
                                            TestBuildFile("B.c"),
                                            TestBuildFile("B.swift"),
                                        ])
                                       ],
                                       dependencies: ["A"]),
                    TestStandardTarget("C",
                                       type: .applicationExtension,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase([
                                            TestBuildFile("C.m"),
                                        ])
                                       ],
                                       dependencies: ["CodegenFramework"]),
                ]
            )

            let core = try await getCore()
            let tester = try TaskConstructionTester(core, project)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            final class Delegate: MockTestTaskPlanningClientDelegate, @unchecked Sendable {
                override func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> ExternalToolResult {
                    switch commandLine.first.map(Path.init)?.basename {
                    case "intentbuilderc"?:
                        do {
                            if let outputDir = commandLine.elementAfterElements(["-output"]).map(Path.init),
                               let classPrefix = commandLine.elementAfterElements(["-classPrefix"]),
                               let language = commandLine.elementAfterElements(["-language"]),
                               let visibility = commandLine.elementAfterElements(["-visibility"]) {
                                if visibility != "public" {
                                    throw StubError.error("Visibility should be public")
                                }
                                switch language {
                                case "Swift":
                                    return .result(status: .exit(0), stdout: Data(outputDir.join("\(classPrefix)GeneratedIntent.swift").str.utf8), stderr: .init())
                                case "Objective-C":
                                    return .result(status: .exit(0), stdout: Data([outputDir.join("\(classPrefix)GeneratedIntent.h").str, outputDir.join("\(classPrefix)GeneratedIntent.m").str].joined(separator: "\n").utf8), stderr: .init())
                                default:
                                    throw StubError.error("unknown language '\(language)'")
                                }
                            }
                        }
                    case "coremlc"?:
                        do {
                            if let language = commandLine.elementAfterElements(["--language"]), commandLine.count > 4 {
                                let outputDir = Path(commandLine[3])
                                switch language {
                                case "Swift":
                                    return .result(status: .exit(0), stdout: Data(outputDir.join("GeneratedCoreML.swift").str.utf8), stderr: .init())
                                case "Objective-C":
                                    return .result(status: .exit(0), stdout: Data([outputDir.join("GeneratedCoreML.h").str, outputDir.join("GeneratedCoreML.m").str].joined(separator: "\n").utf8), stderr: .init())
                                default:
                                    throw StubError.error("unknown language '\(language)'")
                                }
                            }
                        }
                    default:
                        break
                    }
                    return try await super.executeExternalTool(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment)
                }
            }

            let fs = PseudoFS()
            let toolchain = try #require(core.toolchainRegistry.defaultToolchain)
            try fs.createDirectory(toolchain.path.join("usr").join("bin"), recursive: true)
            try fs.write(toolchain.path.join("usr").join("bin").join("coremlc"), contents: ByteString())

            await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest, fs: fs, clientDelegate: Delegate()) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchTargetName("A"), .matchRuleType("SwiftDriver Compilation")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("IntentDefinitionCodegen"))
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("GeneratedIntent.h")))
                }

                results.checkTask(.matchTargetName("A"), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("A.c"))) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("IntentDefinitionCodegen"))
                }

                results.checkTask(.matchTargetName("A"), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("GeneratedIntent.m"))) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("IntentDefinitionCodegen"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("SwiftDriver Compilation")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("IntentDefinitionCodegen"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("SwiftDriver Compilation Requirements")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("IntentDefinitionCodegen"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("IntentDefinitionCodegen"))
                }

                results.checkTask(.matchTargetName("C"), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("C.m"))) { compilationTask in
                    // Check that compilation of an app target starts after the generated header got copied
                    results.checkTaskFollows(compilationTask, .matchTargetName("CodegenFramework"), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("GeneratedIntent.h")))
                    results.checkTaskFollows(compilationTask, .matchTargetName("CodegenFramework"), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("GeneratedCoreML.h")))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func yaccCompilation() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourceRoot = tmpDir.join("Project")

            let project = try await TestProject(
                "YaccProject",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("A.h"),
                        TestFile("A.y"),
                        TestFile("A.swift"),
                        TestFile("A.c"),
                        TestFile("B.c"),
                        TestFile("B.swift"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.2",
                    ])],
                targets: [
                    TestStandardTarget("A",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                                        TestSourcesBuildPhase([
                                            TestBuildFile("A.c"),
                                            TestBuildFile("A.swift"),
                                            TestBuildFile("A.y"),
                                        ])
                                       ]),
                    TestStandardTarget("B",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase([
                                            TestBuildFile("B.c"),
                                            TestBuildFile("B.swift"),
                                        ])
                                       ],
                                       dependencies: ["A"]),
                ]
            )

            let tester = try await TaskConstructionTester(getCore(), project)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchTargetName("A"), .matchRuleType("SwiftDriver Compilation")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("Yacc"))
                }

                results.checkTask(.matchTargetName("A"), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("A.c"))) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("Yacc"))
                }

                results.checkTask(.matchTargetName("A"), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix(".tab.c"))) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("Yacc"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("SwiftDriver Compilation")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("Yacc"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("SwiftDriver Compilation Requirements")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("Yacc"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("Yacc"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func customBuildRule() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourceRoot = tmpDir.join("Project")

            let project = try await TestProject(
                "CustomBuildRuleProject",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("A.h"),
                        TestFile("A.fake-foo"),
                        TestFile("A.swift"),
                        TestFile("A.c"),
                        TestFile("B.c"),
                        TestFile("B.swift"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.2",
                    ])],
                targets: [
                    TestStandardTarget("A",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                                        TestSourcesBuildPhase([
                                            TestBuildFile("A.c"),
                                            TestBuildFile("A.swift"),
                                            TestBuildFile("A.fake-foo"),
                                        ])
                                       ],
                                       buildRules: [
                                        TestBuildRule(filePattern: "*.fake-foo", script: "cp ${SCRIPT_INPUT_FILE} ${SCRIPT_OUTPUT_FILE_0}", outputs: ["$(DERIVED_FILE_DIR)/$(INPUT_FILE_NAME).h"])
                                       ]),
                    TestStandardTarget("B",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase([
                                            TestBuildFile("B.c"),
                                            TestBuildFile("B.swift"),
                                        ])
                                       ],
                                       dependencies: ["A"]),
                ]
            )

            let tester = try await TaskConstructionTester(getCore(), project)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchTargetName("A"), .matchRuleType("SwiftDriver Compilation")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("RuleScriptExecution"))
                }

                results.checkTask(.matchTargetName("A"), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("A.c"))) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("RuleScriptExecution"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("SwiftDriver Compilation")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("RuleScriptExecution"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("SwiftDriver Compilation Requirements")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("RuleScriptExecution"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("RuleScriptExecution"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func shellScriptBuildPhase() async throws {
        try await withTemporaryDirectory { tmpDir in
            let sourceRoot = tmpDir.join("Project")

            let project = try await TestProject(
                "ShellScriptBuildPhaseProject",
                sourceRoot: sourceRoot,
                groupTree: TestGroup(
                    "Group",
                    path: "Sources",
                    children: [
                        TestFile("A.h"),
                        TestFile("A.swift"),
                        TestFile("A.c"),
                        TestFile("B.c"),
                        TestFile("B.swift"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "ALWAYS_SEARCH_USER_PATHS": "false",
                        "GCC_PRECOMPILE_PREFIX_HEADER": "YES",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": "5.2",
                    ])],
                targets: [
                    TestStandardTarget("A",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestHeadersBuildPhase([TestBuildFile("A.h", headerVisibility: .public)]),
                                        TestShellScriptBuildPhase(name: "Generate Header",
                                                                  originalObjectID: "foobar123",
                                                                  contents: """
                                                                cat << EOF > #{SCRIPT_OUTPUT_FILE_0}
                                                                @import Foundation;
                                                                NSString *_Nonnull globalGeneratedFunction() { return @"I'm generated."; }
                                                                EOF
                                                                """,
                                                                  outputs: ["$(DERIVED_FILE_DIR)/Generated/OutputFile.h"]),
                                        TestSourcesBuildPhase([
                                            TestBuildFile("A.c"),
                                            TestBuildFile("A.swift"),
                                        ])
                                       ]),
                    TestStandardTarget("B",
                                       type: .framework,
                                       buildConfigurations: [TestBuildConfiguration("Debug")],
                                       buildPhases: [
                                        TestSourcesBuildPhase([
                                            TestBuildFile("B.c"),
                                            TestBuildFile("B.swift"),
                                        ])
                                       ],
                                       dependencies: ["A"]),
                ]
            )

            let tester = try await TaskConstructionTester(getCore(), project)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

            await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkNoDiagnostics()

                results.checkTask(.matchTargetName("A"), .matchRuleType("SwiftDriver Compilation")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
                }

                results.checkTask(.matchTargetName("A"), .matchRuleType("SwiftDriver Compilation Requirements")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
                }

                results.checkTask(.matchTargetName("A"), .matchRuleType("CompileC"), .matchRuleItemPattern(.suffix("A.c"))) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("SwiftDriver Compilation")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("SwiftDriver Compilation Requirements")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
                }

                results.checkTask(.matchTargetName("B"), .matchRuleType("CompileC")) { compilationTask in
                    results.checkTaskFollows(compilationTask, .matchTargetName("A"), .matchRuleType("PhaseScriptExecution"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func generateHeaderTaskOrdering() async throws {
        try await withTemporaryDirectory { srcroot in
            let testProject = TestProject("aProject",
                                          sourceRoot: srcroot,
                                          groupTree: TestGroup("SomeFiles", path: "Sources",
                                                               children: [
                                                                TestFile("A.h"),
                                                               ]),
                                          buildConfigurations: [
                                            TestBuildConfiguration("Debug",
                                                                   buildSettings: [
                                                                    "GENERATE_INFOPLIST_FILE": "YES",
                                                                    "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                    "EAGER_COMPILATION_REQUIRE": "YES",
                                                                    "EAGER_COMPILATION_ALLOW_SCRIPTS": "YES",
                                                                   ]),
                                          ],
                                          targets: [
                                            TestStandardTarget("A",
                                                               type: .framework,
                                                               buildConfigurations: [
                                                                TestBuildConfiguration("Debug"),
                                                               ],
                                                               buildPhases: [
                                                                TestShellScriptBuildPhase(name: "Generate A.h",
                                                                                          originalObjectID: "script1",
                                                                                          contents: "echo \"\" > ${SCRIPT_OUTPUT_FILE_0}",
                                                                                          inputs: [],
                                                                                          outputs: [srcroot.join("Sources").join("A.h").str]),
                                                                TestHeadersBuildPhase([
                                                                    TestBuildFile("A.h", headerVisibility: .public)]),
                                                               ]),
                                          ])

            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOS, targetName: "A") { results in
                results.checkWarning(.prefix("tasks in 'Copy Headers' are delayed by unsandboxed script phases"))
                results.checkNoDiagnostics()

                results.checkTask(.matchRuleType("CpHeader")) { copyTask in
                    results.checkTaskFollows(copyTask, .matchRuleType("PhaseScriptExecution"))
                    results.checkTaskFollows(copyTask, .matchRuleItemPattern(.suffix("-immediate")))

                    results.checkTaskDoesNotFollow(copyTask, .matchRuleItemPattern(.suffix("-entry")))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireLLBuild(apiVersion: 12))
    func swiftEagerCompilation() async throws {
        // This tests only the task construction side of eager compilation
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject("aProject",
                                                    sourceRoot: tmpDir,
                                                    groupTree: TestGroup("SomeFiles", path: "Sources",
                                                                         children: [
                                                                            TestFile("A.swift"),
                                                                            TestFile("B.swift"),
                                                                            TestFile("C.swift"),
                                                                         ]),
                                                    buildConfigurations: [
                                                        TestBuildConfiguration("Debug",
                                                                               buildSettings: [
                                                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                                                "SWIFT_VERSION": swiftVersion,
                                                                                "TAPI_EXEC": tapiToolPath.str,

                                                                                "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                                                               ]),
                                                    ],
                                                    targets: [
                                                        TestStandardTarget("A",
                                                                           type: .framework,
                                                                           buildConfigurations: [
                                                                            TestBuildConfiguration("Debug"),
                                                                           ],
                                                                           buildPhases: [
                                                                            TestSourcesBuildPhase(["A.swift"]),
                                                                           ]),

                                                        TestStandardTarget("B",
                                                                           type: .framework,
                                                                           buildConfigurations: [
                                                                            TestBuildConfiguration("Debug"),
                                                                           ],
                                                                           buildPhases: [
                                                                            TestSourcesBuildPhase(["B.swift"]),
                                                                           ],
                                                                           dependencies: ["A"]),

                                                        TestStandardTarget("C",
                                                                           type: .framework,
                                                                           buildConfigurations: [
                                                                            TestBuildConfiguration("Debug"),
                                                                           ],
                                                                           buildPhases: [
                                                                            TestSourcesBuildPhase(["C.swift"]),
                                                                           ]),
                                                    ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            try await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkNoDiagnostics()

                let compilationRequirementRuleInfoType = "SwiftDriver Compilation Requirements"
                let compilationRuleInfoType = "SwiftDriver Compilation"
                let linkingRuleInfoType = "Ld"

                guard
                    let compilationRequirementTargetA = results.getTask(.matchTargetName("A"), .matchRuleType(compilationRequirementRuleInfoType)),
                    let compilationRequirementTargetB = results.getTask(.matchTargetName("B"), .matchRuleType(compilationRequirementRuleInfoType)),
                    let compilationRequirementTargetC = results.getTask(.matchTargetName("C"), .matchRuleType(compilationRequirementRuleInfoType)),

                        let compilationTargetA = results.getTask(.matchTargetName("A"), .matchRuleType(compilationRuleInfoType)),
                    let compilationTargetB = results.getTask(.matchTargetName("B"), .matchRuleType(compilationRuleInfoType)),
                    let compilationTargetC = results.getTask(.matchTargetName("C"), .matchRuleType(compilationRuleInfoType)),

                        let linkingTargetA = results.getTask(.matchTargetName("A"), .matchRuleType(linkingRuleInfoType)),
                    let linkingTargetB = results.getTask(.matchTargetName("B"), .matchRuleType(linkingRuleInfoType)),
                    let linkingTargetC = results.getTask(.matchTargetName("C"), .matchRuleType(linkingRuleInfoType))
                else {
                    Issue.record("Did not find Swift Driver tasks.")
                    return
                }

                func copyModuleFiles(targetName: String) throws -> [any PlannedTask] {
                    [".swiftmodule", ".swiftinterface", ".private.swiftmodule", ".swiftdoc"].flatMap {
                        results.getTasks(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("\(targetName)\($0)")))
                    }
                }

                // Check that compilation requirement does not produce object files
                #expect(!compilationRequirementTargetA.outputs.contains(where: { $0.path.fileExtension == "o" }))
                #expect(!compilationRequirementTargetB.outputs.contains(where: { $0.path.fileExtension == "o" }))
                #expect(!compilationRequirementTargetC.outputs.contains(where: { $0.path.fileExtension == "o" }))

                // Check that compilation produces object files
                #expect(compilationTargetA.outputs.contains(where: { $0.path.fileExtension == "o" }))
                #expect(compilationTargetB.outputs.contains(where: { $0.path.fileExtension == "o" }))
                #expect(compilationTargetC.outputs.contains(where: { $0.path.fileExtension == "o" }))

                // Check that compilation requirement follows copying of module files
                for copyTask in try copyModuleFiles(targetName: "A") {
                    results.checkTaskFollows(compilationRequirementTargetB, antecedent: copyTask)
                    results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: copyTask)
                }

                // Check that compilation requirement is waiting for compilation requirements of dependency targets
                results.checkTaskFollows(compilationRequirementTargetB, antecedent: compilationRequirementTargetA)
                results.checkTaskDoesNotFollow(compilationRequirementTargetA, antecedent: compilationRequirementTargetB)
                results.checkTaskDoesNotFollow(compilationRequirementTargetA, antecedent: compilationRequirementTargetC)
                results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: compilationRequirementTargetA)
                results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: compilationRequirementTargetB)

                // Check that the compilation task is not blocked by the compilation requirements task
                results.checkTaskDoesNotFollow(compilationTargetA, antecedent: compilationRequirementTargetA)
                results.checkTaskDoesNotFollow(compilationTargetB, antecedent: compilationRequirementTargetB)
                results.checkTaskDoesNotFollow(compilationTargetC, antecedent: compilationRequirementTargetC)

                // Check that compilation is waiting for compilation requirement of dependency targets
                results.checkTaskFollows(compilationTargetB, antecedent: compilationRequirementTargetA)

                // The actual eager part: check that compilation is **not** waiting for compilation of dependency targets
                results.checkTaskDoesNotFollow(compilationTargetB, antecedent: compilationTargetA)

                // Check that linking follows compilation
                results.checkTaskFollows(linkingTargetA, antecedent: compilationTargetA)
                results.checkTaskFollows(linkingTargetB, antecedent: compilationTargetB)
                results.checkTaskFollows(linkingTargetC, antecedent: compilationTargetC)
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftEagerCompilation_generatedHeaderDependencies() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("Swift.swift"),
                    TestFile("ObjC.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "SWIFT_OBJC_INTERFACE_HEADER_NAME": "Header-Swift.h",
                    ])],
            targets: [
                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["Swift.swift", "ObjC.m"]),
                    ])])
        let testWorkspace = TestWorkspace("aWorkspace", projects: [testProject])
        let tester = try await TaskConstructionTester(getCore(), testWorkspace)

        try await tester.checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            try results.checkTarget("App") { target in
                let swiftCompilationRequirements = try #require(results.getTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation Requirements")))
                let swiftCompilation = try #require(results.getTask(.matchTarget(target), .matchRuleType("SwiftDriver Compilation")))
                let cCompilation = try #require(results.getTask(.matchTarget(target), .matchRuleType("CompileC")))

                // C compilation should follow Swift compilation requirements, which include the generated header.
                results.checkTaskFollows(cCompilation, antecedent: swiftCompilationRequirements)
                // C compilation need not follow the Swift compilation tasks.
                results.checkTaskDoesNotFollow(cCompilation, antecedent: swiftCompilation)
                // Swift compilation tasks shouldn't be blocked by Swift compilation requirements tasks.
                results.checkTaskDoesNotFollow(swiftCompilation, antecedent: swiftCompilationRequirements)
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireLLBuild(apiVersion: 12))
    func swiftEagerCompilation_WMO() async throws {
        // This tests only the task construction side of eager compilation
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject("aProject",
                                                    sourceRoot: tmpDir,
                                                    groupTree: TestGroup("SomeFiles", path: "Sources",
                                                                         children: [
                                                                            TestFile("A.swift"),
                                                                            TestFile("B.swift"),
                                                                            TestFile("C.swift"),
                                                                         ]),
                                                    buildConfigurations: [
                                                        TestBuildConfiguration("Debug",
                                                                               buildSettings: [
                                                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                                                "SWIFT_VERSION": swiftVersion,
                                                                                "SWIFT_ENABLE_LIBRARY_EVOLUTION": "YES",
                                                                                "TAPI_EXEC": tapiToolPath.str,
                                                                                "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                                                               ]),
                                                    ],
                                                    targets: [
                                                        TestStandardTarget("A",
                                                                           type: .framework,
                                                                           buildConfigurations: [
                                                                            TestBuildConfiguration("Debug"),
                                                                           ],
                                                                           buildPhases: [
                                                                            TestSourcesBuildPhase(["A.swift"]),
                                                                           ]),

                                                        TestStandardTarget("B",
                                                                           type: .framework,
                                                                           buildConfigurations: [
                                                                            TestBuildConfiguration("Debug"),
                                                                           ],
                                                                           buildPhases: [
                                                                            TestSourcesBuildPhase(["B.swift"]),
                                                                           ],
                                                                           dependencies: ["A"]),

                                                        TestStandardTarget("C",
                                                                           type: .framework,
                                                                           buildConfigurations: [
                                                                            TestBuildConfiguration("Debug"),
                                                                           ],
                                                                           buildPhases: [
                                                                            TestSourcesBuildPhase(["C.swift"]),
                                                                           ]),
                                                    ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            try await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkNoDiagnostics()

                let compilationRequirementRuleInfoType = "SwiftDriver Compilation Requirements"
                let compilationRuleInfoType = "SwiftDriver Compilation"
                let linkingRuleInfoType = "Ld"

                guard
                    let compilationRequirementTargetA = results.getTask(.matchTargetName("A"), .matchRuleType(compilationRequirementRuleInfoType)),
                    let compilationRequirementTargetB = results.getTask(.matchTargetName("B"), .matchRuleType(compilationRequirementRuleInfoType)),
                    let compilationRequirementTargetC = results.getTask(.matchTargetName("C"), .matchRuleType(compilationRequirementRuleInfoType)),

                        let compilationTargetA = results.getTask(.matchTargetName("A"), .matchRuleType(compilationRuleInfoType)),
                    let compilationTargetB = results.getTask(.matchTargetName("B"), .matchRuleType(compilationRuleInfoType)),
                    let compilationTargetC = results.getTask(.matchTargetName("C"), .matchRuleType(compilationRuleInfoType)),

                        let linkingTargetA = results.getTask(.matchTargetName("A"), .matchRuleType(linkingRuleInfoType)),
                    let linkingTargetB = results.getTask(.matchTargetName("B"), .matchRuleType(linkingRuleInfoType)),
                    let linkingTargetC = results.getTask(.matchTargetName("C"), .matchRuleType(linkingRuleInfoType))
                else {
                    Issue.record("Did not find Swift Driver tasks.")
                    return
                }

                func copyModuleFiles(targetName: String) throws -> [any PlannedTask] {
                    [".swiftmodule", ".swiftinterface", ".private.swiftmodule", ".swiftdoc"].flatMap {
                        results.getTasks(.matchTargetName(targetName), .matchRuleType("PBXCp"), .matchRuleItemPattern(.suffix("\(targetName)\($0)")))
                    }
                }

                // Check that compilation produces object files
                #expect(compilationTargetA.outputs.contains(where: { $0.path.fileExtension == "o" }))
                #expect(compilationTargetB.outputs.contains(where: { $0.path.fileExtension == "o" }))
                #expect(compilationTargetC.outputs.contains(where: { $0.path.fileExtension == "o" }))

                // Check that compilation requirements produces no object files
                #expect(!compilationRequirementTargetA.outputs.contains(where: { $0.path.fileExtension == "o" }))
                #expect(!compilationRequirementTargetB.outputs.contains(where: { $0.path.fileExtension == "o" }))
                #expect(!compilationRequirementTargetC.outputs.contains(where: { $0.path.fileExtension == "o" }))

                // Check that compilation requirement follows copying of module files
                for copyTask in try copyModuleFiles(targetName: "A") {
                    results.checkTaskFollows(compilationRequirementTargetB, antecedent: copyTask)
                    results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: copyTask)
                }

                // Check that compilation requirement is waiting for compilation requirements of dependency targets
                results.checkTaskFollows(compilationRequirementTargetB, antecedent: compilationRequirementTargetA)
                results.checkTaskDoesNotFollow(compilationRequirementTargetA, antecedent: compilationRequirementTargetB)
                results.checkTaskDoesNotFollow(compilationRequirementTargetA, antecedent: compilationRequirementTargetC)
                results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: compilationRequirementTargetA)
                results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: compilationRequirementTargetB)

                // Check that compilation is waiting for compilation requirement of dependency targets
                results.checkTaskFollows(compilationTargetB, antecedent: compilationRequirementTargetA)

                // The actual eager part: check that compilation is **not** waiting for compilation of dependency targets
                results.checkTaskDoesNotFollow(compilationTargetB, antecedent: compilationTargetA)

                // Check that linking does not follow compilation requirements
                // rdar://87413615 Compilation follows compilation requirements due to generated header task
                //                results.checkTaskDoesNotFollow(linkingTargetA, antecedent: compilationRequirementTargetA)
                //                results.checkTaskDoesNotFollow(linkingTargetB, antecedent: compilationRequirementTargetB)
                //                results.checkTaskDoesNotFollow(linkingTargetC, antecedent: compilationRequirementTargetC)

                // Check that linking follows compilation
                results.checkTaskFollows(linkingTargetA, antecedent: compilationTargetA)
                results.checkTaskFollows(linkingTargetB, antecedent: compilationTargetB)
                results.checkTaskFollows(linkingTargetC, antecedent: compilationTargetC)
            }
        }
    }

    @Test(.requireSDKs(.macOS), .requireLLBuild(apiVersion: 12))
    func swiftEagerCompilation_explicitModules() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject("aProject",
                                                    sourceRoot: tmpDir,
                                                    groupTree: TestGroup("SomeFiles", path: "Sources",
                                                                         children: [
                                                                            TestFile("A.swift"),
                                                                            TestFile("B.swift"),
                                                                            TestFile("C.swift"),
                                                                         ]),
                                                    buildConfigurations: [
                                                        TestBuildConfiguration("Debug",
                                                                               buildSettings: [
                                                                                "GENERATE_INFOPLIST_FILE": "YES",
                                                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                                                "SWIFT_VERSION": swiftVersion,
                                                                                "TAPI_EXEC": tapiToolPath.str,

                                                                                "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                                                                                "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                                                                               ]),
                                                    ],
                                                    targets: [
                                                        TestStandardTarget("A",
                                                                           type: .framework,
                                                                           buildConfigurations: [
                                                                            TestBuildConfiguration("Debug"),
                                                                           ],
                                                                           buildPhases: [
                                                                            TestSourcesBuildPhase(["A.swift"]),
                                                                           ]),

                                                        TestStandardTarget("B",
                                                                           type: .framework,
                                                                           buildConfigurations: [
                                                                            TestBuildConfiguration("Debug"),
                                                                           ],
                                                                           buildPhases: [
                                                                            TestSourcesBuildPhase(["B.swift"]),
                                                                           ],
                                                                           dependencies: ["A"]),

                                                        TestStandardTarget("C",
                                                                           type: .framework,
                                                                           buildConfigurations: [
                                                                            TestBuildConfiguration("Debug"),
                                                                           ],
                                                                           buildPhases: [
                                                                            TestSourcesBuildPhase(["C.swift"]),
                                                                           ]),
                                                    ])

            let tester = try await TaskConstructionTester(getCore(), testProject)
            let parameters = BuildParameters(configuration: "Debug")
            let buildRequest = BuildRequest(parameters: parameters, buildTargets: tester.workspace.projects[0].targets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) }), continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            try await tester.checkBuild(parameters, runDestination: .macOS, buildRequest: buildRequest) { results in
                results.checkNoDiagnostics()

                let compilationRequirementRuleInfoType = "SwiftDriver Compilation Requirements"
                let compilationRuleInfoType = "SwiftDriver Compilation"
                let linkingRuleInfoType = "Ld"

                guard
                    let compilationRequirementTargetA = results.getTask(.matchTargetName("A"), .matchRuleType(compilationRequirementRuleInfoType)),
                    let compilationRequirementTargetB = results.getTask(.matchTargetName("B"), .matchRuleType(compilationRequirementRuleInfoType)),
                    let compilationRequirementTargetC = results.getTask(.matchTargetName("C"), .matchRuleType(compilationRequirementRuleInfoType)),

                        let compilationTargetA = results.getTask(.matchTargetName("A"), .matchRuleType(compilationRuleInfoType)),
                    let compilationTargetB = results.getTask(.matchTargetName("B"), .matchRuleType(compilationRuleInfoType)),
                    let compilationTargetC = results.getTask(.matchTargetName("C"), .matchRuleType(compilationRuleInfoType)),

                        let linkingTargetA = results.getTask(.matchTargetName("A"), .matchRuleType(linkingRuleInfoType)),
                    let linkingTargetB = results.getTask(.matchTargetName("B"), .matchRuleType(linkingRuleInfoType)),
                    let linkingTargetC = results.getTask(.matchTargetName("C"), .matchRuleType(linkingRuleInfoType))
                else {
                    Issue.record("Did not find Swift Driver tasks.")
                    return
                }


                func copyModuleFiles(targetName: String) throws -> [any PlannedTask] {
                    [".swiftmodule", ".swiftinterface", ".private.swiftmodule", ".swiftdoc"].flatMap {
                        results.getTasks(.matchTargetName(targetName), .matchRuleType("Copy"), .matchRuleItemPattern(.suffix("\(targetName)\($0)")))
                    }
                }

                // Check that compilation requirement follows copying of module files
                for copyTask in try copyModuleFiles(targetName: "A") {
                    results.checkTaskFollows(compilationRequirementTargetB, antecedent: copyTask)
                    results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: copyTask)
                }

                // Check that compilation requirement is waiting for compilation requirements of dependency targets
                results.checkTaskFollows(compilationRequirementTargetB, antecedent: compilationRequirementTargetA)
                results.checkTaskDoesNotFollow(compilationRequirementTargetA, antecedent: compilationRequirementTargetB)
                results.checkTaskDoesNotFollow(compilationRequirementTargetA, antecedent: compilationRequirementTargetC)
                results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: compilationRequirementTargetA)
                results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: compilationRequirementTargetB)

                // Check that compilation requirement follows compilation requirement of dependencies
                results.checkTaskFollows(compilationRequirementTargetB, antecedent: compilationRequirementTargetA)
                results.checkTaskDoesNotFollow(compilationRequirementTargetC, antecedent: compilationRequirementTargetA)

                // Check that compilation is waiting for compilation requirement of dependency targets
                results.checkTaskFollows(compilationTargetB, antecedent: compilationRequirementTargetA)

                // The actual eager part: check that compilation is **not** waiting for compilation of dependency targets
                results.checkTaskDoesNotFollow(compilationTargetB, antecedent: compilationTargetA)

                // Check that linking follows compilation
                results.checkTaskFollows(linkingTargetA, antecedent: compilationTargetA)
                results.checkTaskFollows(linkingTargetB, antecedent: compilationTargetB)
                results.checkTaskFollows(linkingTargetC, antecedent: compilationTargetC)
            }
        }
    }
}
