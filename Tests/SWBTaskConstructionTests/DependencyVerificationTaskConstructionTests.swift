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

    @Test(.requireSDKs(.macOS), .requireClangFeatures(.printHeadersDirectPerFile))
    func addsTraceArgsWhenValidationEnabled() async throws {
        try await testWith([
            "MODULE_DEPENDENCIES": "Foo",
            "VALIDATE_MODULE_DEPENDENCIES": "YES_ERROR"
        ]) { tester, srcroot in
            await tester.checkBuild(runDestination: .macOS, fs: localFS) { results in
                results.checkTask(.compileC(target, fileName: source)) { task in
                    task.checkCommandLineContains([
                        "-Xclang", "-header-include-file",
                        "-Xclang", outputFile(srcroot, "\(sourceBaseName).o.trace.json"),
                        "-Xclang", "-header-include-filtering=direct-per-file",
                        "-Xclang", "-header-include-format=json",
                    ])
                }
            }
        }
    }

    @Test(.requireSDKs(.macOS))
    func noTraceArgsWhenValidationDisabled() async throws {
        try await testWith([:]) { tester, srcroot in
            await tester.checkBuild(runDestination: .macOS, fs: localFS) { results in
                results.checkTask(.compileC(target, fileName: source)) { task in
                    task.checkCommandLineDoesNotContain("-header-include-file")
                }
            }
        }
    }

    private func testWith(
        _ buildSettings: [String: String],
        _ assertions: (_ tester: TaskConstructionTester, _ srcroot: Path) async throws -> Void
    ) async throws {
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
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GENERATE_INFOPLIST_FILE": "YES",
                        "CLANG_ENABLE_MODULES": "YES",
                    ].merging(buildSettings) { _, new in new }
                )
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
