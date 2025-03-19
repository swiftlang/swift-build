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

import SWBTaskExecution

@Suite
fileprivate struct SwiftBuildTraceTests: CoreBasedTests {
    @Test(.requireSDKs(.host), .requireThreadSafeWorkingDirectory)
    func swiftBuildTraceEmission() async throws {
        try await withTemporaryDirectory { tmpDirPath async throws -> Void in
            try await withEnvironment(["SWIFTBUILD_TRACE_FILE": tmpDirPath.join(".SWIFTBUILD_TRACE").str]) {
                let testWorkspace = TestWorkspace(
                    "Test",
                    sourceRoot: tmpDirPath.join("Test"),
                    projects: [
                        TestProject(
                            "aProject",
                            groupTree: TestGroup(
                                "Sources",
                                children: [
                                    TestFile("main.swift"),
                                ]),
                            buildConfigurations: [
                                TestBuildConfiguration(
                                    "Debug",
                                    buildSettings: [
                                        "CODE_SIGNING_ALLOWED": "NO",
                                        "PRODUCT_NAME": "$(TARGET_NAME)",
                                        "SWIFT_VERSION": "5.0",
                                    ]),
                            ],
                            targets: [
                                TestStandardTarget(
                                    "Tool",
                                    type: .commandLineTool,
                                    buildPhases: [
                                        TestSourcesBuildPhase([
                                            "main.swift",
                                        ]),
                                    ]
                                ),
                            ])
                    ])
                let tester = try await BuildOperationTester(getCore(), testWorkspace, simulated: false)

                try await tester.fs.writeFileContents(tmpDirPath.join("Test/aProject/main.swift")) {
                    $0 <<< "for _ in 0..<100 { }\nprint(\"hello, world!\")\n"
                }

                try await tester.checkBuild(runDestination: .host) { results in
                    results.checkNoDiagnostics()
                }

                try await tester.checkBuild(runDestination: .host) { results in
                    results.checkNoDiagnostics()
                }

                let trace = try tester.fs.read(tmpDirPath.join(".SWIFTBUILD_TRACE")).asString
                print(trace)
                #expect(try #/\{\"buildDescriptionSignature\":\".*\",\"isTargetParallelizationEnabled\":true,\"name\":\"Test\",\"path\":\".*\"\}\n\{\"buildDescriptionSignature\":\".*\",\"isTargetParallelizationEnabled\":true,\"name\":\"Test\",\"path\":\".*\"\}\n/#.wholeMatch(in: trace) != nil)
            }
        }
    }
}
