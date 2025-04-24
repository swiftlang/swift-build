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

import SWBTaskConstruction
import SWBProtocol

@Suite
fileprivate struct PostprocessingTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func setOwnerGroupAndModeWithVariants() async throws {
        let buildVariants = ["normal", "debug", "profile"]

        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.m"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "BUILD_VARIANTS": buildVariants.joined(separator: " "),
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])],
            targets: [
                TestAggregateTarget(
                    "All",
                    dependencies: ["Library", "Framework"]
                ),
                TestStandardTarget(
                    "Library",
                    type: .dynamicLibrary,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                ),
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                )
            ]
        )

        let tester = try await TaskConstructionTester(getCore(), testProject)

        let installParameters = BuildParameters(action: .install, configuration: "Debug")
        await tester.checkBuild(installParameters, runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget("Library") { target in
                results.checkTasks(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { tasks in
                    for (buildVariant, task) in zip(buildVariants, tasks.sorted(by: \.identifier)) {
                        let suffix = buildVariant == "normal" ? "" : "_\(buildVariant)"

                        task.checkRuleInfo(["SetOwnerAndGroup", "exampleUser:exampleGroup", "/tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib"])
                        task.checkCommandLine(["/usr/sbin/chown", "-RH", "exampleUser:exampleGroup", "/tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib"])

                        task.checkInputs([
                            .path("/tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib"),
                            .namePattern(.and(.prefix("target-"), .suffix("-Barrier-StripSymbols"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                            // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                            .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                        ])

                        task.checkOutputs([
                            .path("/tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib"),
                            .name("SetOwner /tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib")])
                    }
                }
                results.checkTasks(.matchTarget(target), .matchRuleType("SetMode")) { tasks in
                    for (buildVariant, task) in zip(buildVariants, tasks.sorted(by: \.identifier)) {
                        let suffix = buildVariant == "normal" ? "" : "_\(buildVariant)"

                        task.checkRuleInfo(["SetMode", "u+w,go-w,a+rX", "/tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib"])
                        task.checkCommandLine(["/bin/chmod", "-RH", "u+w,go-w,a+rX", "/tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib"])

                        task.checkInputs([
                            // Set mode artificially orders itself relative to the chown task.
                            .path("/tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib"),
                            .name("SetOwner /tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib"),
                            .namePattern(.and(.prefix("target-"), .suffix("-Barrier-StripSymbols"))),
                            .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                            // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                            .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                        ])

                        task.checkOutputs([
                            .path("/tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib"),
                            .name("SetMode /tmp/aProject.dst/usr/local/lib/Library\(suffix).dylib")])
                    }
                }
            }

            results.checkTarget("Framework") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("SetOwnerAndGroup")) { task in
                    task.checkRuleInfo(["SetOwnerAndGroup", "exampleUser:exampleGroup", "/tmp/aProject.dst/Library/Frameworks/Framework.framework"])
                    task.checkCommandLine(["/usr/sbin/chown", "-RH", "exampleUser:exampleGroup", "/tmp/aProject.dst/Library/Frameworks/Framework.framework"])

                    task.checkInputs([
                        .path("/tmp/aProject.dst/Library/Frameworks/Framework.framework"),
                        .namePattern(.and(.prefix("target-"), .suffix("-Barrier-StripSymbols"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                        // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                        .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                    ])

                    task.checkOutputs([
                        .path("/tmp/aProject.dst/Library/Frameworks/Framework.framework"),
                        .name("SetOwner /tmp/aProject.dst/Library/Frameworks/Framework.framework")])
                }
                results.checkTask(.matchTarget(target), .matchRuleType("SetMode")) { task in
                    task.checkRuleInfo(["SetMode", "u+w,go-w,a+rX", "/tmp/aProject.dst/Library/Frameworks/Framework.framework"])
                    task.checkCommandLine(["/bin/chmod", "-RH", "u+w,go-w,a+rX", "/tmp/aProject.dst/Library/Frameworks/Framework.framework"])

                    task.checkInputs([
                        // Set mode artificially orders itself relative to the chown task.
                        .path("/tmp/aProject.dst/Library/Frameworks/Framework.framework"),
                        .name("SetOwner /tmp/aProject.dst/Library/Frameworks/Framework.framework"),
                        .namePattern(.and(.prefix("target-"), .suffix("-Barrier-StripSymbols"))),
                        .namePattern(.and(.prefix("target-"), .suffix("-will-sign"))),
                        // Postprocessing tasks depend on the end phase nodes of earlier task producers.
                        .namePattern(.and(.prefix("target-"), .suffix("-entry"))),
                    ])

                    task.checkOutputs([
                        .path("/tmp/aProject.dst/Library/Frameworks/Framework.framework"),
                        .name("SetMode /tmp/aProject.dst/Library/Frameworks/Framework.framework")])
                }
            }
        }
    }

    /// Test applications built without the normal variant can still pass validation
    @Test(.requireSDKs(.macOS))
    func validateProductWithNonNormalVariant() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.m"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "BUILD_VARIANTS": "unexpected",
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                ])],
            targets: [
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                )
            ])

        try await TaskConstructionTester(getCore(), testProject).checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            results.checkTarget("Application") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Validate")) { task in
                    XCTAssertMatch(task.inputs[0].path.str, .suffix("Application.app"))
                }
            }
        }
    }

    /// Test execution policy exception registration by ensuring each product type gets a task of this kind.
    @Test(.requireSDKs(.macOS))
    func registerExecutionPolicyException() async throws {
        let testProject = try await TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.m"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "LIBTOOL": libtoolPath.str,
                ])],
            targets: [
                TestAggregateTarget(
                    "All",
                    dependencies: ["Library", "StaticLibrary", "Framework", "StaticFramework", "Executable", "Application", "ApplicationExtension"]
                ),
                TestStandardTarget(
                    "Library",
                    type: .dynamicLibrary,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                ),
                TestStandardTarget(
                    "StaticLibrary",
                    type: .staticLibrary,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                ),
                TestStandardTarget(
                    "Framework",
                    type: .framework,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                ),
                TestStandardTarget(
                    "StaticFramework",
                    type: .staticFramework,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                ),
                TestStandardTarget(
                    "Executable",
                    type: .commandLineTool,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                ),
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                ),
                TestStandardTarget(
                    "ApplicationExtension",
                    type: .applicationExtension,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                )
            ]
        )

        try await TaskConstructionTester(getCore(), testProject).checkBuild(runDestination: .macOS) { results in
            results.checkNoDiagnostics()

            for targetName in ["Library", "Framework", "Executable", "Application", "ApplicationExtension"] {
                results.checkTarget(targetName) { target in
                    results.checkTask(.matchTarget(target), .matchRuleType("RegisterExecutionPolicyException")) { task in
                        XCTAssertMatch(task.execDescription, .prefix("Register execution policy exception for "))
                    }
                }
            }

            for targetName in ["StaticLibrary", "StaticFramework"] {
                results.checkTarget(targetName) { target in
                    results.checkNoTask(.matchTarget(target), .matchRuleType("RegisterExecutionPolicyException"))
                }
            }
        }
    }

    /// Test that an app's product definition plist is copied to the build products directory.
    @Test(.requireSDKs(.macOS))
    func copyProductDefinition() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SourceFile.m"),
                ]
            ),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "GENERATE_INFOPLIST_FILE": "YES",
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "PRODUCT_DEFINITION_PLIST": "prod.plist",
                ])],
            targets: [
                TestStandardTarget(
                    "Application",
                    type: .application,
                    buildConfigurations: [TestBuildConfiguration("Debug")],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                )
            ]
        )

        let fs = PseudoFS()
        try fs.createDirectory(Path("/tmp/Test/aProject"), recursive: true)
        try await fs.writePlist(Path("/tmp/Test/aProject/prod.plist"), .plDict([
            "sysctl-requirements": .plString("hw.optional.f16c == 1"),
        ]))

        try await TaskConstructionTester(getCore(), testProject).checkBuild(runDestination: .macOS, fs: fs) { results in
            results.checkNoDiagnostics()

            results.checkTask(.matchRule(["Copy", "/tmp/Test/aProject/build/Debug/ProductDefinition.plist", "/tmp/Test/aProject/prod.plist"])) { _ in }
        }
    }
}
