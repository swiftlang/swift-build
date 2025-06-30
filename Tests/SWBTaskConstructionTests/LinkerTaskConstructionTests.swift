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
fileprivate struct LinkerTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func linkerDriverSelection() async throws {
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles",
                children: [
                    TestFile("c.c"),
                    TestFile("cxx.cpp"),
                    TestFile("s.swift"),
                ]),
            buildConfigurations: [
                TestBuildConfiguration("Debug", buildSettings: [
                    "PRODUCT_NAME": "$(TARGET_NAME)",
                    "SWIFT_EXEC": try await swiftCompilerPath.str,
                    "SWIFT_VERSION": try await swiftVersion
                ]),
            ],
            targets: [
                TestStandardTarget(
                    "Library",
                    type: .dynamicLibrary,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug", buildSettings: [:]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase(["c.c", "cxx.cpp", "s.swift"]),
                    ]
                ),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: [:]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("clang++"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["EXCLUDED_SOURCE_FILE_NAMES": "cxx.cpp"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("clang"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "swiftc"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("swiftc"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "auto"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("swiftc"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "auto", "EXCLUDED_SOURCE_FILE_NAMES": "s.swift"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("clang++"), .anySequence])
            }
        }

        await tester.checkBuild(BuildParameters(configuration: "Debug", overrides: ["LINKER_DRIVER": "auto", "EXCLUDED_SOURCE_FILE_NAMES": "s.swift cxx.cpp"]), runDestination: .host) { results in
            results.checkNoDiagnostics()
            results.checkTask(.matchRuleType("Ld")) { task in
                task.checkCommandLineMatches([.contains("clang"), .anySequence])
            }
        }
    }
}
