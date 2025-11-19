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
import Foundation

import SWBBuildSystem
import SWBCore
import SWBTestSupport
import SWBTaskExecution
import SWBUtil
import SWBProtocol

@Suite
fileprivate struct APIDigesterBuildOperationTests: CoreBasedTests {
    @Test(.requireSDKs(.host), .skipHostOS(.windows, "Windows toolchains are missing swift-api-digester"))
    func apiDigesterDisableFailOnError() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("foo.swift")
                    ]
                ),
                buildConfigurations: [
                    TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "ARCHS": "$(ARCHS_STANDARD)",
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "SDKROOT": "$(HOST_PLATFORM)",
                            "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                            "SWIFT_VERSION": swiftVersion,
                            "CODE_SIGNING_ALLOWED": "NO",
                        ]
                    )
                ],
                targets: [
                    TestStandardTarget(
                        "foo",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [:])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["foo.swift"])
                        ]
                    )
                ]
            )
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("foo.swift")) { stream in
                stream <<< "public func foo() -> Int { 42 }"
            }

            try await tester.checkBuild(
                parameters: BuildParameters(
                    configuration: "Debug",
                    overrides: [
                        "RUN_SWIFT_ABI_GENERATION_TOOL": "YES",
                        "SWIFT_API_DIGESTER_MODE": "api",
                        "SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR": tmpDir.join("baseline").join("ABI").str,
                    ]
                ),
                runDestination: .host
            ) { results in
                results.checkNoErrors()
            }

            try await tester.fs.writeFileContents(projectDir.join("foo.swift")) { stream in
                stream <<< "public func foo() -> String { \"hello, world!\" }"
            }

            try await tester.checkBuild(
                parameters: BuildParameters(
                    configuration: "Debug",
                    overrides: [
                        "RUN_SWIFT_ABI_CHECKER_TOOL": "YES",
                        "SWIFT_API_DIGESTER_MODE": "api",
                        "SWIFT_ABI_CHECKER_BASELINE_DIR": tmpDir.join("baseline").str,
                        "SWIFT_ABI_CHECKER_DOWNGRADE_ERRORS": "YES",
                    ]
                ),
                runDestination: .host
            ) { results in
                results.checkWarning(.contains("func foo() has return type change from Swift.Int to Swift.String"))
                results.checkNoDiagnostics()
            }
        }
    }
}
