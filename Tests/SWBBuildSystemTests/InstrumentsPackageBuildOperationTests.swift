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

import SWBCore
import SWBTestSupport
import SWBUtil
import SWBProtocol
import SwiftBuildTestSupport

import Testing

@Suite(.requireXcode16())
fileprivate struct InstrumentsPackageBuildOperationTests: CoreBasedTests {
    /// An Instruments package target.
    @Test(.requireSDKs(.macOS))
    func instrumentsPackage() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "Sources", children: [
                        TestFile("PackageDefinition.instrpkg"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "DSTROOT": "/\(tmpDir.str)/$(PROJECT_NAME).dst",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "INSTALL_OWNER": "",
                            "INSTALL_GROUP": "staff",
                        ]
                    )],
                targets: [
                    TestStandardTarget(
                        "Measure",
                        type: .instrumentsPackage,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["PackageDefinition.instrpkg"]),
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            try tester.fs.write(SRCROOT.join("PackageDefinition.instrpkg"), contents:
                """
                <?xml version="1.0" encoding="UTF-8" ?>
                <package>
                    <id>com.foo.bar</id>
                    <title>Foo</title>
                    <owner>
                        <name>Foo</name>
                    </owner>
                </package>
                """)

            try await tester.checkBuild(parameters: BuildParameters(action: .install, configuration: "Debug"), runDestination: .macOS) { results in
                // Check that there are no warnings or errors.  If the Instruments package processing tool doesn't declare a virtual output then the post-processing tasks will not be able to be ordered with respect to it.
                results.checkNoDiagnostics()

                results.checkTask(.matchRuleType("BuildInstrumentsPackage")) { task in
                    task.checkCommandLineMatches([
                        .equal("--emit-dependency-info"),
                        .suffix("instruments-package-builder.dependencies")
                    ])
                }

                results.checkFileExists(tmpDir.join("aProject.dst/Library/Instruments/Packages/Measure.instrdst"))
            }
        }
    }
}
