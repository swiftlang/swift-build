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
fileprivate struct DependencyVerificationTaskConstructionTests: CoreBasedTests {

    let project = "TestProject"
    let target = "TestTarget"
    let sourceBaseName = "TestSource"
    let source = "TestSource.m"

    func outputFile(_ srcroot: Path, _ filename: String) -> String {
        return "\(srcroot.str)/build/\(project).build/Debug/\(target).build/Objects-normal/x86_64/\(filename)"
    }

    @Test
    func addsTraceArgsWhenDependenciesDeclared() async throws {
        try await testWith(dependencies: ["Foo"]) { tester, srcroot in
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("Ld")) { task in
                    task.checkCommandLineContains([
                        "-Xlinker", "-trace_file",
                        "-Xlinker", outputFile(srcroot, "\(target)_trace.json"),
                    ])
                }
                results.checkTask(.compileC(target, fileName: source)) { task in
                    task.checkCommandLineContains([
                        "-Xclang", "-header-include-file",
                        "-Xclang", outputFile(srcroot, "\(sourceBaseName).o.trace.json"),
                        "-Xclang", "-header-include-filtering=only-direct-system",
                        "-Xclang", "-header-include-format=json"
                    ])
                }
            }
        }
    }

    @Test
    func noTraceArgsWhenDependenciesDeclared() async throws {
        try await testWith(dependencies: []) { tester, srcroot in
            await tester.checkBuild(runDestination: .macOS) { results in
                results.checkTask(.matchRuleType("Ld")) { task in
                    task.checkCommandLineDoesNotContain("-trace_file")
                }
                results.checkTask(.compileC(target, fileName: source)) { task in
                    task.checkCommandLineDoesNotContain("-header-include-file")
                }
            }
        }
    }

    private func testWith(dependencies: [String], _ assertions: (_ tester: TaskConstructionTester, _ srcroot: Path) async throws -> Void) async throws {
        let testProject = TestProject(
            project,
            groupTree: TestGroup(
                "TestGroup",
                children: [
                    TestFile(source)
                ]),
            buildConfigurations: [
                TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "DEPENDENCIES": dependencies.joined(separator: " "),
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CLANG_ENABLE_MODULES": "YES"
                    ])
            ],
            targets: [
                TestStandardTarget(
                    target,
                    type: .framework,
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile(source)])
                    ]
                )
            ])

        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)
        let SRCROOT = tester.workspace.projects[0].sourceRoot

        try await assertions(tester, SRCROOT)
    }

}
