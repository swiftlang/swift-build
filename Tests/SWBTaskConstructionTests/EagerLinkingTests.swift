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
import SWBProtocol

import SWBTaskConstruction

@Suite
fileprivate struct EagerLinkingTests: CoreBasedTests {
    private var objcTestProject: TestProject {
        return TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
                TestFile("C.m"),
                TestFile("D.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "EAGER_LINKING": "YES",
                    "EAGER_LINKING_REQUIRE": "YES",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("A.m")
                    ])
                ], dependencies: ["B", "C"]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("B.m")
                    ])
                ]),
                TestStandardTarget("C", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("C.m")
                    ])
                ], dependencies: ["D"]),
                TestStandardTarget("D", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("D.m")
                    ])
                ])
            ])
    }

    private var swiftTestProject: TestProject {
        get async throws {
            let tapiToolPath = try await self.tapiToolPath
            return try await TestProject(
                "aProject",
                groupTree: TestGroup("Sources", path: "Sources", children: [
                    TestFile("A.swift"),
                    TestFile("B.swift"),
                    TestFile("C.swift"),
                    TestFile("D.swift"),
                ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                        "EAGER_LINKING": "YES",
                        "EAGER_LINKING_REQUIRE": "YES",
                        "SWIFT_EXEC": swiftCompilerPath.str,
                        "SWIFT_VERSION": swiftVersion,
                        "TAPI_EXEC": tapiToolPath.str,
                    ]
                )],
                targets: [
                    TestStandardTarget("A", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("A.swift")
                        ])
                    ], dependencies: ["B", "C"]),
                    TestStandardTarget("B", type: .framework,
                                       buildPhases: [
                                        TestSourcesBuildPhase([
                                            TestBuildFile("B.swift")
                                        ])
                                       ]),
                    TestStandardTarget("C", type: .framework, buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("C.swift")
                        ])
                    ], dependencies: ["D"]),
                    TestStandardTarget("D", type: .dynamicLibrary, buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("D.swift")
                        ])
                    ])
                ])
        }
    }

    @Test(.requireSDKs(.macOS))
    func objCTaskDependenciesEagerLinkingEnabled() async throws {
        let tester = try await TaskConstructionTester(getCore(), objcTestProject)
        try await tester.checkBuild(runDestination: .macOS) { results in
            let compileATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("CompileC")))
            let linkATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("Ld")))
            let aStartLinking = try #require(results.getTask(.matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("begin-linking"))))

            let compileBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("CompileC")))
            let linkBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("Ld")))
            let bLinkerInputsReady = try #require(results.getTask(.matchTargetName("B"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let bStartLinking = try #require(results.getTask(.matchTargetName("B"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("begin-linking"))))

            let compileCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("CompileC")))
            let linkCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("Ld")))
            let cLinkerInputsReady = try #require(results.getTask(.matchTargetName("C"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let cStartLinking = try #require(results.getTask(.matchTargetName("C"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("begin-linking"))))

            let compileDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("CompileC")))
            let linkDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("Ld")))
            let dLinkerInputsReady = try #require(results.getTask(.matchTargetName("D"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let dStartLinking = try #require(results.getTask(.matchTargetName("D"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("begin-linking"))))

            results.checkTaskFollows(linkATask, antecedent: aStartLinking)
            results.checkTaskFollows(aStartLinking, antecedent: bLinkerInputsReady)
            results.checkTaskFollows(aStartLinking, antecedent: cLinkerInputsReady)
            results.checkTaskFollows(bLinkerInputsReady, antecedent: linkBTask)
            results.checkTaskFollows(linkBTask, antecedent: bStartLinking)
            results.checkTaskFollows(cLinkerInputsReady, antecedent: linkCTask)
            results.checkTaskFollows(linkCTask, antecedent: cStartLinking)
            results.checkTaskFollows(cStartLinking, antecedent: dLinkerInputsReady)
            results.checkTaskFollows(dLinkerInputsReady, antecedent: linkDTask)
            results.checkTaskFollows(linkDTask, antecedent: dStartLinking)

            results.checkTaskFollows(linkATask, antecedent: compileATask)
            results.checkTaskFollows(linkBTask, antecedent: compileBTask)
            results.checkTaskFollows(linkCTask, antecedent: compileCTask)
            results.checkTaskFollows(linkDTask, antecedent: compileDTask)

            let beginATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("entry"))))
            let endATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("end"))))

            // Linking A shouldn't depend on the 'Start A' gate task, but linking must finish before the 'End A' gate.
            results.checkTaskDoesNotFollow(linkATask, antecedent: beginATask)
            results.checkTaskFollows(endATask, antecedent: linkATask)
        }
    }

    @Test(.requireSDKs(.macOS))
    func objCLinkerInputsReadyDependsOnLipo() async throws {
        let tester = try await TaskConstructionTester(getCore(), objcTestProject)
        try await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["ARCHS": "arm64 x86_64"]), runDestination: .anyMac) { results in
            let linkBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("Ld"), .matchRuleItem("x86_64")))
            let linkBTask2 = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("Ld"), .matchRuleItem("x86_64")))
            let lipoBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleType("CreateUniversalBinary")))
            let bLinkerInputsReady = try #require(results.getTask(.matchTargetName("B"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let bStartLinking = try #require(results.getTask(.matchTargetName("B"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("begin-linking"))))

            results.checkTaskFollows(linkBTask, antecedent: bStartLinking)
            results.checkTaskFollows(linkBTask2, antecedent: bStartLinking)
            results.checkTaskFollows(lipoBTask, antecedent: linkBTask)
            results.checkTaskFollows(lipoBTask, antecedent: linkBTask2)
            // Lipo must run before linker inputs are considered ready for dependent targets.
            results.checkTaskFollows(bLinkerInputsReady, antecedent: lipoBTask)
        }
    }

    @Test(.requireSDKs(.macOS))
    func objCTaskDependenciesEagerLinkingEnabledForAllButOneTarget() async throws {
        let project = TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.m"),
                TestFile("B.m"),
                TestFile("C.m"),
                TestFile("D.m"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "EAGER_LINKING": "YES",
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("A.m")
                    ])
                ], dependencies: ["B", "C"]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("B.m")
                    ])
                ]),
                TestStandardTarget("C", type: .framework, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "EAGER_LINKING": "NO",
                        ]
                    )], buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("C.m")
                        ])
                    ], dependencies: ["D"]),
                TestStandardTarget("D", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("D.m")
                    ])
                ])
            ])
        let tester = try await TaskConstructionTester(getCore(), project)
        try await tester.checkBuild(runDestination: .macOS) { results in
            let compileATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("CompileC")))
            let linkATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("Ld")))
            let aStartLinking = try #require(results.getTask(.matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("begin-linking"))))

            let compileBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("CompileC")))
            let linkBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("Ld")))
            let bLinkerInputsReady = try #require(results.getTask(.matchTargetName("B"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let bStartLinking = try #require(results.getTask(.matchTargetName("B"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("begin-linking"))))

            let compileCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("CompileC")))
            let linkCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("Ld")))
            let cLinkerInputsReady = try #require(results.getTask(.matchTargetName("C"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let cStartLinking = try #require(results.getTask(.matchTargetName("C"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("begin-linking"))))

            let compileDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("CompileC")))
            let linkDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("Ld")))
            let dLinkerInputsReady = try #require(results.getTask(.matchTargetName("D"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let dStartLinking = try #require(results.getTask(.matchTargetName("D"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("begin-linking"))))

            results.checkTaskFollows(linkATask, antecedent: aStartLinking)
            results.checkTaskFollows(aStartLinking, antecedent: bLinkerInputsReady)

            results.checkTaskFollows(bLinkerInputsReady, antecedent: linkBTask)
            results.checkTaskFollows(linkBTask, antecedent: bStartLinking)
            results.checkTaskFollows(cLinkerInputsReady, antecedent: linkCTask)
            results.checkTaskFollows(linkCTask, antecedent: cStartLinking)

            let endDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("end"))))
            results.checkTaskFollows(cStartLinking, antecedent: endDTask)

            results.checkTaskFollows(dLinkerInputsReady, antecedent: linkDTask)
            results.checkTaskFollows(linkDTask, antecedent: dStartLinking)

            results.checkTaskFollows(linkATask, antecedent: compileATask)
            results.checkTaskFollows(linkBTask, antecedent: compileBTask)
            results.checkTaskFollows(linkCTask, antecedent: compileCTask)
            results.checkTaskFollows(linkDTask, antecedent: compileDTask)

            let beginATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("entry"))))
            let endATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("end"))))

            results.checkTaskDoesNotFollow(linkATask, antecedent: beginATask)
            results.checkTaskFollows(endATask, antecedent: linkATask)
        }
    }

    @Test(.requireSDKs(.macOS))
    func eagerLinkingEnablementCriteria() async throws {
        let tester = try await TaskConstructionTester(getCore(), objcTestProject)
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["EAGER_LINKING": "NO"]), runDestination: .macOS) { results in
            results.checkWarning("target 'A' has both required and disabled eager linking (in target 'A' from project 'aProject')")
            results.checkWarning("target 'B' has both required and disabled eager linking (in target 'B' from project 'aProject')")
            results.checkWarning("target 'C' has both required and disabled eager linking (in target 'C' from project 'aProject')")
            results.checkWarning("target 'D' has both required and disabled eager linking (in target 'D' from project 'aProject')")
            results.checkNoDiagnostics()
        }
        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["EAGER_COMPILATION_DISABLE": "YES"]), runDestination: .macOS) { results in
            results.checkWarning("target 'A' requires eager linking, but eager compilation is disabled (in target 'A' from project 'aProject')")
            results.checkWarning("target 'B' requires eager linking, but eager compilation is disabled (in target 'B' from project 'aProject')")
            results.checkWarning("target 'C' requires eager linking, but eager compilation is disabled (in target 'C' from project 'aProject')")
            results.checkWarning("target 'D' requires eager linking, but eager compilation is disabled (in target 'D' from project 'aProject')")
            results.checkNoDiagnostics()
        }
    }

    @Test(.requireSDKs(.macOS))
    func eligibleTargetsEmitTBD() async throws {
        let testProject = try await TestProject(
            "aProject",
            sourceRoot: Path("/TEST"),
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("Fwk.swift"),
                    TestFile("App.swift"),
                    TestFile("Fwk.docc")
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str,
                    "LIBTOOL": libtoolPath.str,
                    "DOCC_EXEC": doccToolPath.str,
                    "DYLIB_CURRENT_VERSION": "2.0",
                    "DYLIB_COMPATIBILITY_VERSION": "1.0",
                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                    "EAGER_LINKING": "YES",
                    "DEFINES_MODULE": "YES",
                ])],
            targets: [
                TestStandardTarget(
                    "Fwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])
                    ]),
                TestStandardTarget(
                    "DocumentedFwk",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift", "Fwk.docc"])
                    ]),
                TestStandardTarget(
                    "FwkLinkingStaticLib",
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"]),
                        TestFrameworksBuildPhase([TestBuildFile(.target("StaticLib"))])
                    ], dependencies: ["StaticLib"]),
                TestStandardTarget(
                    "StaticLib",
                    type: .staticLibrary,
                    buildPhases: [
                        TestSourcesBuildPhase(["Fwk.swift"])
                    ]),

                TestStandardTarget(
                    "App",
                    type: .application,
                    buildPhases: [
                        TestSourcesBuildPhase(["App.swift"]),
                        TestFrameworksBuildPhase([TestBuildFile(.target("Fwk"))])
                    ], dependencies: ["Fwk"])
            ])
        let tester = try await TaskConstructionTester(getCore(), testProject)

        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, targetName: "Fwk") { results in
            results.checkTarget("Fwk") { target in
                results.checkNoDiagnostics()

                // Verify the driver planning task contains the TBD emission flags.
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    task.checkCommandLineMatches([
                        "builtin-Swift-Compilation-Requirements", .anySequence,
                        "-emit-tbd", "-emit-tbd-path", "/TEST/build/aProject.build/Debug/Fwk.build/Objects-normal/x86_64/Swift-API.tbd", .anySequence,
                        "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                        "-Xfrontend", "-tbd-current-version", "-Xfrontend", "2.0",
                        "-Xfrontend", "-tbd-compatibility-version", "-Xfrontend", "1.0", .anySequence,
                    ])
                }
            }
        }

        // A DocC input in the compile sources phase shouldn't make the target ineligible for eager linking.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, targetName: "DocumentedFwk") { results in
            results.checkTarget("DocumentedFwk") { target in
                results.checkNoDiagnostics()

                // Verify the driver planning task contains the TBD emission flags.
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    task.checkCommandLineMatches([
                        "builtin-Swift-Compilation-Requirements", .anySequence,
                        "-emit-tbd", "-emit-tbd-path", "/TEST/build/aProject.build/Debug/DocumentedFwk.build/Objects-normal/x86_64/Swift-API.tbd", .anySequence,
                        "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/Library/Frameworks/DocumentedFwk.framework/Versions/A/DocumentedFwk",
                        "-Xfrontend", "-tbd-current-version", "-Xfrontend", "2.0",
                        "-Xfrontend", "-tbd-compatibility-version", "-Xfrontend", "1.0", .anySequence,
                    ])
                }
            }
        }

        // If the _vers.c file is being generated with exported symbols, don't try to emit a TBD.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: ["VERSIONING_SYSTEM": "apple-generic"]), runDestination: .macOS, targetName: "Fwk") { results in
            results.checkTarget("Fwk") { target in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    task.checkCommandLineDoesNotContain("-emit-tbd")
                    task.checkCommandLineDoesNotContain("-emit-tbd-path")
                }
            }
        }
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug", overrides: ["VERSIONING_SYSTEM": "apple-generic", "VERSION_INFO_EXPORT_DECL": "static"]), runDestination: .macOS, targetName: "Fwk") { results in
            results.checkTarget("Fwk") { target in
                results.checkNoDiagnostics()

                // Verify the driver planning task contains the TBD emission flags.
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    task.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements", "--", .anySequence])
                    task.checkCommandLineMatches([
                        "builtin-Swift-Compilation-Requirements", .anySequence,
                        "-emit-tbd", "-emit-tbd-path", "/TEST/build/aProject.build/Debug/Fwk.build/Objects-normal/x86_64/Swift-API.tbd", .anySequence,
                        "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                        "-Xfrontend", "-tbd-current-version", "-Xfrontend", "2.0",
                        "-Xfrontend", "-tbd-compatibility-version", "-Xfrontend", "1.0", .anySequence,
                    ])
                }
            }
        }

        // An all-Swift app target should not emit a TBD, but the framework it links should.
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, targetName: "App") { results in
            results.checkTarget("App") { target in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    task.checkCommandLineDoesNotContain("-emit-tbd")
                    task.checkCommandLineDoesNotContain("-emit-tbd-path")
                }
            }
            results.checkTarget("Fwk") { target in
                results.checkNoDiagnostics()

                // Verify the driver planning task contains the TBD emission flags.
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    task.checkCommandLineMatches(["builtin-Swift-Compilation-Requirements", "--", .anySequence])
                    task.checkCommandLineMatches([
                        "builtin-Swift-Compilation-Requirements", .anySequence,
                        "-emit-tbd", "-emit-tbd-path", "/TEST/build/aProject.build/Debug/Fwk.build/Objects-normal/x86_64/Swift-API.tbd", .anySequence,
                        "-Xfrontend", "-tbd-install_name", "-Xfrontend", "/Library/Frameworks/Fwk.framework/Versions/A/Fwk",
                        "-Xfrontend", "-tbd-current-version", "-Xfrontend", "2.0",
                        "-Xfrontend", "-tbd-compatibility-version", "-Xfrontend", "1.0", .anySequence,
                    ])
                }
            }
        }
        // A static library target should not emit a TBD
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, targetName: "StaticLib") { results in
            results.checkTarget("StaticLib") { target in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    task.checkCommandLineDoesNotContain("-emit-tbd")
                    task.checkCommandLineDoesNotContain("-emit-tbd-path")
                }
            }
        }
        // A static library target should not emit a TBD
        await tester.checkBuild(BuildParameters(action: .build, configuration: "Debug"), runDestination: .macOS, targetName: "FwkLinkingStaticLib") { results in
            results.checkTarget("FwkLinkingStaticLib") { target in
                results.checkNoDiagnostics()
                results.checkTask(.matchRuleType("SwiftDriver Compilation Requirements"), .matchTarget(target)) { task in
                    task.checkCommandLineDoesNotContain("-emit-tbd")
                    task.checkCommandLineDoesNotContain("-emit-tbd-path")
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftTaskDependenciesEagerLinkingEnabled() async throws {
        let tester = try await TaskConstructionTester(getCore(), swiftTestProject)
        try await tester.checkBuild(runDestination: .macOS) { results in
            let compileATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("SwiftDriver Compilation")))
            let emitModuleATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("SwiftDriver Compilation Requirements")))
            let linkATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("Ld")))
            let aLinkerInputsReady = try #require(results.getTask(.matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let aTapiTask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("GenerateTAPI")))

            let compileBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("SwiftDriver Compilation")))
            let emitModuleBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("SwiftDriver Compilation Requirements")))
            let linkBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("Ld")))
            let bLinkerInputsReady = try #require(results.getTask(.matchTargetName("B"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let bTapiTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("GenerateTAPI")))

            let compileCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("SwiftDriver Compilation")))
            let emitModuleCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("SwiftDriver Compilation Requirements")))
            let linkCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("Ld")))
            let cLinkerInputsReady = try #require(results.getTask(.matchTargetName("C"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let cTapiTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("GenerateTAPI")))

            let compileDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("SwiftDriver Compilation")))
            let emitModuleDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("SwiftDriver Compilation Requirements")))
            let linkDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("Ld")))
            let dLinkerInputsReady = try #require(results.getTask(.matchTargetName("D"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))
            let dTapiTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("GenerateTAPI")))

            // Every target in the project should be eligible for eager linking.

            // Check that the link task does not have an edge to linker-inputs-ready.
            results.checkTaskDoesNotFollow(aLinkerInputsReady, antecedent: linkATask)
            results.checkTaskDoesNotFollow(bLinkerInputsReady, antecedent: linkBTask)
            results.checkTaskDoesNotFollow(cLinkerInputsReady, antecedent: linkCTask)
            results.checkTaskDoesNotFollow(dLinkerInputsReady, antecedent: linkDTask)

            // The emit-module tasks should precede linker-inputs-ready, but the compile tasks should not.
            results.checkTaskFollows(aLinkerInputsReady, antecedent: emitModuleATask)
            results.checkTaskDoesNotFollow(aLinkerInputsReady, antecedent: compileATask)
            results.checkTaskFollows(bLinkerInputsReady, antecedent: emitModuleBTask)
            results.checkTaskDoesNotFollow(bLinkerInputsReady, antecedent: compileBTask)
            results.checkTaskFollows(cLinkerInputsReady, antecedent: emitModuleCTask)
            results.checkTaskDoesNotFollow(cLinkerInputsReady, antecedent: compileCTask)
            results.checkTaskFollows(dLinkerInputsReady, antecedent: emitModuleDTask)
            results.checkTaskDoesNotFollow(dLinkerInputsReady, antecedent: compileDTask)

            // The tapi tasks should precede linker-inputs-ready and follow emit-module, but not compile tasks
            results.checkTaskFollows(aLinkerInputsReady, antecedent: aTapiTask)
            results.checkTaskFollows(bLinkerInputsReady, antecedent: bTapiTask)
            results.checkTaskFollows(cLinkerInputsReady, antecedent: cTapiTask)
            results.checkTaskFollows(dLinkerInputsReady, antecedent: dTapiTask)
            results.checkTaskFollows(aTapiTask, antecedent: emitModuleATask)
            results.checkTaskFollows(bTapiTask, antecedent: emitModuleBTask)
            results.checkTaskFollows(cTapiTask, antecedent: emitModuleCTask)
            results.checkTaskFollows(dTapiTask, antecedent: emitModuleDTask)
            results.checkTaskDoesNotFollow(aTapiTask, antecedent: compileATask)
            results.checkTaskDoesNotFollow(bTapiTask, antecedent: compileBTask)
            results.checkTaskDoesNotFollow(cTapiTask, antecedent: compileCTask)
            results.checkTaskDoesNotFollow(dTapiTask, antecedent: compileDTask)

            // Check that downstream targets don't depend on upstream linking, but do depend on module emission.
            results.checkTaskDoesNotFollow(linkCTask, antecedent: linkDTask)
            results.checkTaskFollows(linkCTask, antecedent: emitModuleDTask)
            results.checkTaskDoesNotFollow(linkATask, antecedent: linkCTask)
            results.checkTaskFollows(linkATask, antecedent: emitModuleCTask)
            results.checkTaskDoesNotFollow(linkATask, antecedent: linkBTask)
            results.checkTaskFollows(linkATask, antecedent: emitModuleBTask)
        }
    }

    @Test(.requireSDKs(.macOS))
    func swiftTaskDependenciesEagerLinkingEnabledForAllButOneTarget() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup("Sources", path: "Sources", children: [
                TestFile("A.swift"),
                TestFile("B.swift"),
                TestFile("C.swift"),
                TestFile("D.swift"),
            ]),
            buildConfigurations: [TestBuildConfiguration(
                "Debug",
                buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_USE_INTEGRATED_DRIVER": "YES",
                    "EAGER_LINKING": "YES",
                    "EAGER_LINKING_REQUIRE": "YES",
                    "SWIFT_EXEC": swiftCompilerPath.str,
                    "SWIFT_VERSION": swiftVersion,
                    "TAPI_EXEC": tapiToolPath.str
                ]
            )],
            targets: [
                TestStandardTarget("A", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("A.swift")
                    ])
                ], dependencies: ["B", "C"]),
                TestStandardTarget("B", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("B.swift")
                    ])
                ]),
                TestStandardTarget("C", type: .framework, buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "EAGER_LINKING": "NO",
                            "EAGER_LINKING_REQUIRE": "NO",
                        ]
                    )], buildPhases: [
                        TestSourcesBuildPhase([
                            TestBuildFile("C.swift")
                        ])
                    ], dependencies: ["D"]),
                TestStandardTarget("D", type: .framework, buildPhases: [
                    TestSourcesBuildPhase([
                        TestBuildFile("D.swift")
                    ])
                ])
            ])

        let tester = try await TaskConstructionTester(getCore(), testProject)
        try await tester.checkBuild(runDestination: .macOS) { results in
            let compileATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("SwiftDriver Compilation")))
            let emitModuleATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("SwiftDriver Compilation Requirements")))
            let linkATask = try #require(results.getTask(.matchTargetName("A"), .matchRuleItem("Ld")))
            let aLinkerInputsReady = try #require(results.getTask(.matchTargetName("A"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))

            let compileBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("SwiftDriver Compilation")))
            let emitModuleBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("SwiftDriver Compilation Requirements")))
            let linkBTask = try #require(results.getTask(.matchTargetName("B"), .matchRuleItem("Ld")))
            let bLinkerInputsReady = try #require(results.getTask(.matchTargetName("B"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))

            let compileCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("SwiftDriver Compilation")))
            let emitModuleCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("SwiftDriver Compilation Requirements")))
            let linkCTask = try #require(results.getTask(.matchTargetName("C"), .matchRuleItem("Ld")))
            let cLinkerInputsReady = try #require(results.getTask(.matchTargetName("C"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))

            let compileDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("SwiftDriver Compilation")))
            let emitModuleDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("SwiftDriver Compilation Requirements")))
            let linkDTask = try #require(results.getTask(.matchTargetName("D"), .matchRuleItem("Ld")))
            let dLinkerInputsReady = try #require(results.getTask(.matchTargetName("D"), .matchRuleType("Gate"), .matchRuleItemPattern(.suffix("linker-inputs-ready"))))

            // Every target in the project should be eligible for eager linking.

            // Check that the link task does not have an edge to linker-inputs-ready for all targets except C.
            results.checkTaskDoesNotFollow(aLinkerInputsReady, antecedent: linkATask)
            results.checkTaskDoesNotFollow(bLinkerInputsReady, antecedent: linkBTask)
            results.checkTaskFollows(cLinkerInputsReady, antecedent: linkCTask)
            results.checkTaskDoesNotFollow(dLinkerInputsReady, antecedent: linkDTask)

            // The emit-module tasks should have an edge to linker-inputs-ready, but the compile tasks should not (for all targets except C).
            results.checkTaskFollows(aLinkerInputsReady, antecedent: emitModuleATask)
            results.checkTaskDoesNotFollow(aLinkerInputsReady, antecedent: compileATask)
            results.checkTaskFollows(bLinkerInputsReady, antecedent: emitModuleBTask)
            results.checkTaskDoesNotFollow(bLinkerInputsReady, antecedent: compileBTask)
            results.checkTaskFollows(cLinkerInputsReady, antecedent: emitModuleCTask)
            results.checkTaskFollows(cLinkerInputsReady, antecedent: compileCTask)
            results.checkTaskFollows(dLinkerInputsReady, antecedent: emitModuleDTask)
            results.checkTaskDoesNotFollow(dLinkerInputsReady, antecedent: compileDTask)

            // Check that downstream targets don't depend on upstream linking, but do depend on module emission (for all targets except C).
            results.checkTaskFollows(linkCTask, antecedent: linkDTask)
            results.checkTaskFollows(linkCTask, antecedent: emitModuleDTask)
            results.checkTaskFollows(linkATask, antecedent: linkCTask)
            results.checkTaskFollows(linkATask, antecedent: emitModuleCTask)
            results.checkTaskDoesNotFollow(linkATask, antecedent: linkBTask)
            results.checkTaskFollows(linkATask, antecedent: emitModuleBTask)
        }
    }
}
