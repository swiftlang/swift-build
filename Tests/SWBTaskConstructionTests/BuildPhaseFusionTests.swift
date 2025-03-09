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
@_spi(Testing) import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct BuildPhaseFusionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func ignoringBuildPhases() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = try await TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.swift"),
                        TestFile("Image.png"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SWIFT_VERSION": swiftVersion,
                            "SWIFT_EXEC": swiftCompilerPath.str,
                            "IGNORE_BUILD_PHASES": "YES",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.swift"]),
                            TestShellScriptBuildPhase(name: "Scripty McScriptface", originalObjectID: "", outputs: ["/foo/foo.txt"]),
                            TestResourcesBuildPhase(["Image.png"]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOS) { results -> Void in
                results.checkNoDiagnostics()
                results.checkTarget("AppTarget") { target -> Void in
                    results.checkTask(.matchRuleType("SwiftDriver Compilation")) { task in
                        results.checkTaskDoesNotFollow(task, .matchRuleType("CopyPNGFile"))
                        results.checkTaskDoesNotFollow(task, .matchRuleType("PhaseScriptExecution"))
                    }
                    results.checkTask(.matchRuleType("PhaseScriptExecution")) { task in
                        results.checkTaskDoesNotFollow(task, .matchRuleType("SwiftDriver Compilation"))
                        results.checkTaskDoesNotFollow(task, .matchRuleType("CopyPNGFile"))
                    }
                    results.checkTask(.matchRuleType("CopyPNGFile")) { task in
                        results.checkTaskDoesNotFollow(task, .matchRuleType("SwiftDriver Compilation"))
                        results.checkTaskDoesNotFollow(task, .matchRuleType("PhaseScriptExecution"))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func basicCopyResourcesCompileSourcesFusion() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("Image.png"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.c"]),
                            TestResourcesBuildPhase(["Image.png"]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOS) { results -> Void in
                results.checkNoDiagnostics()
                results.checkTarget("AppTarget") { target -> Void in
                    // The compile and copy tasks shouldn't be ordered with respect to each other.
                    results.checkTask(.matchRuleType("CompileC")) { task in
                        results.checkTaskDoesNotFollow(task, .matchRuleType("CopyPNGFile"))
                    }
                    results.checkTask(.matchRuleType("CopyPNGFile")) { task in
                        results.checkTaskDoesNotFollow(task, .matchRuleType("CompileC"))
                        // The copy task should follow the target-start gate.
                        results.checkTaskFollows(task, .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("-entry")))
                    }
                    // The postprocessing gate should follow compilation and resource copying.
                    results.checkTask(.matchRuleType("Gate"), .matchRuleItemPattern(.suffix("ProductPostprocessingTaskProducer"))) { task in
                        results.checkTaskFollows(task, .matchRuleType("CompileC"))
                        results.checkTaskFollows(task, .matchRuleType("CopyPNGFile"))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func scriptPhaseBlocksCopyResourcesCompileSourcesFusion() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("Image.png"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.c"]),
                            TestShellScriptBuildPhase(name: "Bad Script", originalObjectID: "A", contents: "", inputs: [], outputs: [], alwaysOutOfDate: true),
                            TestResourcesBuildPhase(["Image.png"]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOS) { results -> Void in
                results.checkNoDiagnostics()
                results.checkTarget("AppTarget") { target -> Void in
                    results.checkTask(.matchRuleType("PhaseScriptExecution")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CompileC"))
                    }
                    results.checkTask(.matchRuleType("CopyPNGFile")) { task in
                        results.checkTaskFollows(task, .matchRuleType("PhaseScriptExecution"))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func scriptFusion() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("Image.png"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Enabled",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "FUSE_BUILD_SCRIPT_PHASES": "YES",
                        ]),
                    TestBuildConfiguration(
                        "Disabled",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.c"]),
                            TestShellScriptBuildPhase(name: "S1", originalObjectID: "S1", contents: "", inputs: [], outputs: ["foo"], alwaysOutOfDate: false),
                            TestResourcesBuildPhase(["Image.png"]),
                            TestShellScriptBuildPhase(name: "S2", originalObjectID: "S2", contents: "", inputs: [], outputs: ["bar"], alwaysOutOfDate: false),
                            TestShellScriptBuildPhase(name: "S3", originalObjectID: "S3", contents: "", inputs: [], outputs: ["baz"], alwaysOutOfDate: false),
                            TestShellScriptBuildPhase(name: "S4", originalObjectID: "S4", contents: "", inputs: [], outputs: ["one"], alwaysOutOfDate: true),
                            TestShellScriptBuildPhase(name: "S5", originalObjectID: "S5", contents: "", inputs: [], outputs: ["two"], alwaysOutOfDate: false),
                            TestShellScriptBuildPhase(name: "S6", originalObjectID: "S6", contents: "", inputs: [], outputs: ["three"], alwaysOutOfDate: false),
                            TestShellScriptBuildPhase(name: "S7", originalObjectID: "S7", contents: "", inputs: [], outputs: [], alwaysOutOfDate: false),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(BuildParameters(configuration: "Enabled"), runDestination: .macOS) { results -> Void in
                results.checkWarning("Run script build phase 'S7' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase. (in target 'AppTarget' from project 'aProject')")
                results.checkNoDiagnostics()
                results.checkTarget("AppTarget") { target -> Void in
                    results.checkTask(.matchRuleItem("S1")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CompileC"))
                    }
                    results.checkTask(.matchRuleType("CopyPNGFile")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S1"))
                    }
                    results.checkTask(.matchRuleItem("S2")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CopyPNGFile"))
                    }
                    results.checkTask(.matchRuleItem("S3")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CopyPNGFile"))
                        results.checkTaskDoesNotFollow(task, .matchRuleItem("S2"))
                    }
                    results.checkTask(.matchRuleItem("S4")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S2"))
                        results.checkTaskFollows(task, .matchRuleItem("S3"))
                    }
                    results.checkTask(.matchRuleItem("S5")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S4"))
                    }
                    results.checkTask(.matchRuleItem("S6")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S4"))
                        results.checkTaskDoesNotFollow(task, .matchRuleItem("S5"))
                    }
                    results.checkTask(.matchRuleItem("S7")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S5"))
                        results.checkTaskFollows(task, .matchRuleItem("S6"))
                    }
                }
            }

            await tester.checkBuild(BuildParameters(configuration: "Disabled"), runDestination: .macOS) { results -> Void in
                results.checkWarning("Run script build phase 'S7' will be run during every build because it does not specify any outputs. To address this issue, either add output dependencies to the script phase, or configure it to run in every build by unchecking \"Based on dependency analysis\" in the script phase. (in target 'AppTarget' from project 'aProject')")
                results.checkNoDiagnostics()
                results.checkTarget("AppTarget") { target -> Void in
                    results.checkTask(.matchRuleItem("S1")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CompileC"))
                    }
                    results.checkTask(.matchRuleType("CopyPNGFile")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S1"))
                    }
                    results.checkTask(.matchRuleItem("S2")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CopyPNGFile"))
                    }
                    results.checkTask(.matchRuleItem("S3")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S2"))
                    }
                    results.checkTask(.matchRuleItem("S4")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S3"))
                    }
                    results.checkTask(.matchRuleItem("S5")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S4"))
                    }
                    results.checkTask(.matchRuleItem("S6")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S5"))
                    }
                    results.checkTask(.matchRuleItem("S7")) { task in
                        results.checkTaskFollows(task, .matchRuleItem("S6"))
                    }
                }
            }

        }
    }

    @Test(.requireSDKs(.macOS), .userDefaults(["AllowCopyFilesBuildPhaseFusion": "1"]))
    func copyFilesFusion() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("Image.png"),
                        TestFile("f1.txt"),
                        TestFile("f2.txt"),
                        TestFile("f3.txt"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.c"]),
                            TestCopyFilesBuildPhase(["f1.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                            TestResourcesBuildPhase(["Image.png"]),
                            TestCopyFilesBuildPhase(["f2.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                            TestCopyFilesBuildPhase(["f3.txt"], destinationSubfolder: .resources, onlyForDeployment: false),
                            TestShellScriptBuildPhase(name: "S1", originalObjectID: "S1", contents: "", inputs: [], outputs: ["foo"], alwaysOutOfDate: false),
                        ]
                    ),
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOS) { results -> Void in
                results.checkNoDiagnostics()
                results.checkTarget("AppTarget") { target -> Void in
                    results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("f1.txt")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CompileC"))
                    }
                    results.checkTask(.matchRuleType("CopyPNGFile")) { task in
                        results.checkTaskFollows(task, .matchRuleType("Copy"), .matchRuleItemBasename("f1.txt"))
                    }
                    results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("f2.txt")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CopyPNGFile"))
                    }
                    results.checkTask(.matchRuleType("Copy"), .matchRuleItemBasename("f3.txt")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CopyPNGFile"))
                        results.checkTaskDoesNotFollow(task, .matchRuleType("Copy"), .matchRuleItemBasename("f2.txt"))
                    }
                    results.checkTask(.matchRuleItem("S1")) { task in
                        results.checkTaskFollows(task, .matchRuleType("Copy"), .matchRuleItemBasename("f2.txt"))
                        results.checkTaskFollows(task, .matchRuleType("Copy"), .matchRuleItemBasename("f3.txt"))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func buildPhaseFusionDisabled() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir.join("srcroot"),
                groupTree: TestGroup(
                    "SomeFiles", path: "Sources",
                    children: [
                        TestFile("SourceFile.c"),
                        TestFile("Image.png"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "CODE_SIGN_IDENTITY": "",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "FUSE_BUILD_PHASES": "NO",
                        ]),
                ],
                targets: [
                    TestStandardTarget(
                        "AppTarget",
                        type: .application,
                        buildPhases: [
                            TestSourcesBuildPhase(["SourceFile.c"]),
                            TestResourcesBuildPhase(["Image.png"]),
                        ]
                    )
                ])
            let tester = try await TaskConstructionTester(getCore(), testProject)

            await tester.checkBuild(runDestination: .macOS) { results -> Void in
                results.checkNoDiagnostics()
                results.checkTarget("AppTarget") { target -> Void in
                    results.checkTask(.matchRuleType("CopyPNGFile")) { task in
                        results.checkTaskFollows(task, .matchRuleType("CompileC"))
                    }
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func scriptPhaseRelocationBasic() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreFoo.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGN_IDENTITY": "",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m"]),
                                    TestHeadersBuildPhase([TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ])
                        ])
                ])

            // The header copy should be moved before compile, and should not depend on target-entry.
            try await TaskConstructionTester(getCore(), testWorkspace).checkBuild(runDestination: .macOS) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("CoreFoo"), .matchRuleType("CpHeader")) { headerTask in
                    headerTask.checkInputs([
                        .namePattern(.suffix("CoreFoo.h/")),
                        .namePattern(.suffix("-immediate"))
                    ])
                    results.checkTaskDoesNotFollow(headerTask, .matchTargetName("CoreFoo"), .matchRuleType("CompileC"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func scriptPhaseRelocationBasicWithSandboxedScriptsProducingHeaders() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreBar.h", path: "/tmp/CoreBar.h"),
                                TestFile("CoreFoo.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGN_IDENTITY": "",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m"]),
                                    TestShellScriptBuildPhase(name: "Generate CoreBar.h", originalObjectID: "", outputs: ["/tmp/CoreBar.h"], alwaysOutOfDate: false),
                                    TestHeadersBuildPhase([TestBuildFile("CoreBar.h", headerVisibility: .public),
                                                           TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ])
                        ])
                ])

            // The header copy should not be relocated.
            try await TaskConstructionTester(getCore(), testWorkspace).checkBuild(runDestination: .macOS) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("CoreFoo"), .matchRuleType("CpHeader"), .matchRulePattern([.contains("CoreBar.h")])) { headerTask in
                    results.checkTaskFollows(headerTask, .matchTargetName("CoreFoo"), .matchRuleType("CompileC"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func scriptPhaseRelocationBasicWithSandboxedScriptsNotProducingHeaders() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreBar.h"),
                                TestFile("CoreFoo.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGN_IDENTITY": "",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m"]),
                                    TestShellScriptBuildPhase(name: "Generate CoreBar.h", originalObjectID: "", outputs: ["/tmp/whatever.txt"], alwaysOutOfDate: false),
                                    TestHeadersBuildPhase([TestBuildFile("CoreBar.h", headerVisibility: .public),
                                                           TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ])
                        ])
                ])

            // The header copy should be moved before compile, and should not depend on target-entry.
            try await TaskConstructionTester(getCore(), testWorkspace).checkBuild(runDestination: .macOS) { results in
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("CoreFoo"), .matchRuleType("CpHeader"), .matchRulePattern([.contains("CoreFoo.h")])) { headerTask in
                    headerTask.checkInputs([
                        .namePattern(.suffix("CoreFoo.h/")),
                        .namePattern(.suffix("-immediate"))
                    ])
                    results.checkTaskDoesNotFollow(headerTask, .matchTargetName("CoreFoo"), .matchRuleType("CompileC"))
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func scriptPhaseRelocationBasicWithUnsandboxedScripts() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testWorkspace = TestWorkspace(
                "Test",
                sourceRoot: tmpDirPath.join("Test"),
                projects: [
                    TestProject(
                        "aProject",
                        groupTree: TestGroup(
                            "Sources", path: "Sources", children: [
                                TestFile("CoreFoo.h"),
                                TestFile("CoreBar.h", path: "/tmp/CoreBar.h"),
                                TestFile("CoreFoo.m"),
                            ]),
                        buildConfigurations: [TestBuildConfiguration(
                            "Debug",
                            buildSettings: [
                                "CODE_SIGN_IDENTITY": "",
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                            ]
                        )],
                        targets: [
                            TestStandardTarget(
                                "CoreFoo", type: .framework,
                                buildPhases: [
                                    TestSourcesBuildPhase(["CoreFoo.m"]),
                                    TestShellScriptBuildPhase(name: "Generate CoreBar.h", originalObjectID: "", outputs: ["/tmp/whatever.txt"], alwaysOutOfDate: false),
                                    TestHeadersBuildPhase([TestBuildFile("CoreBar.h", headerVisibility: .public),
                                                           TestBuildFile("CoreFoo.h", headerVisibility: .public)]),
                                ])
                        ])
                ])

            // The header copy should not be relocated.
            try await TaskConstructionTester(getCore(), testWorkspace).checkBuild(runDestination: .macOS) { results in
                results.checkWarning("tasks in 'Copy Headers' are delayed by unsandboxed script phases; set ENABLE_USER_SCRIPT_SANDBOXING=YES to enable sandboxing (in target 'CoreFoo' from project 'aProject')")
                results.checkNoDiagnostics()
                results.checkTask(.matchTargetName("CoreFoo"), .matchRuleType("CpHeader"), .matchRulePattern([.contains("CoreBar.h")])) { headerTask in
                    results.checkTaskFollows(headerTask, .matchTargetName("CoreFoo"), .matchRuleType("CompileC"))
                }
            }
        }
    }
}
