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

@Suite
fileprivate struct LibtoolTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func libtoolDeterministicMode() async throws {
        let libtoolPath = try await self.libtoolPath
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("SourceFile.m"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "LIBTOOL": libtoolPath.str,
                    "PRODUCT_NAME": "$(TARGET_NAME)"
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Deterministic",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["LIBTOOL_DETERMINISTIC_MODE": "YES"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ],
                    dependencies: ["Nondeterministic"]
                ),
                TestStandardTarget(
                    "Nondeterministic",
                    type: .staticLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: ["LIBTOOL_DETERMINISTIC_MODE": "NO"]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["SourceFile.m"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot.str

        await tester.checkBuild(runDestination: .macOS) { results in
            results.checkTarget("Deterministic") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                    task.checkRuleInfo(["Libtool", "\(SRCROOT)/build/Debug/libDeterministic.a", "normal"])
                    task.checkCommandLine([libtoolPath.str, "-static", "-arch_only", "x86_64", "-D", "-syslibroot", core.loadSDK(.macOS).path.str, "-L\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/Deterministic.build/Objects-normal/x86_64/Deterministic.LinkFileList", "-dependency_info", "\(SRCROOT)/build/aProject.build/Debug/Deterministic.build/Objects-normal/x86_64/Deterministic_libtool_dependency_info.dat", "-o", "\(SRCROOT)/build/Debug/libDeterministic.a"])
                }
            }

            results.checkTarget("Nondeterministic") { target in
                results.checkTask(.matchTarget(target), .matchRuleType("Libtool")) { task in
                    task.checkRuleInfo(["Libtool", "\(SRCROOT)/build/Debug/libNondeterministic.a", "normal"])
                    task.checkCommandLine([libtoolPath.str, "-static", "-arch_only", "x86_64", "-syslibroot", core.loadSDK(.macOS).path.str, "-L\(SRCROOT)/build/Debug", "-filelist", "\(SRCROOT)/build/aProject.build/Debug/Nondeterministic.build/Objects-normal/x86_64/Nondeterministic.LinkFileList", "-dependency_info", "\(SRCROOT)/build/aProject.build/Debug/Nondeterministic.build/Objects-normal/x86_64/Nondeterministic_libtool_dependency_info.dat", "-o", "\(SRCROOT)/build/Debug/libNondeterministic.a"])
                }
            }

            // Check there are no other targets.
            #expect(results.otherTargets == [])

            // There should be no diagnostics.
            results.checkNoDiagnostics()
        }
    }
}
