//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing

import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

import SWBTaskConstruction

@Suite
fileprivate struct BareMetalTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.host), .requirePlatform("none"))
    func bareMetalLinkerSpecSelection() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SwiftFile.swift"),
                ]),
            targets: [
                TestStandardTarget(
                    "MyTool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "none",
                                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                "ARCHS": "wasm32",
                                                "VALID_ARCHS": "wasm32",
                                                "LLVM_TARGET_TRIPLE_VENDOR": "unknown",
                                                "LLVM_TARGET_TRIPLE_SUFFIX": "-wasm",
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("SwiftFile.swift")]),
                    ]),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        let destination = RunDestinationInfo(
            platform: "none",
            sdk: "none",
            sdkVariant: nil,
            targetArchitecture: "wasm32",
            supportedArchitectures: ["wasm32"],
            disableOnlyActiveArch: false
        )
        let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

        await tester.checkBuild(parameters, runDestination: nil) { results in
            results.checkTask(.matchTargetName("MyTool"), .matchRuleType("Ld")) { task in
                task.checkCommandLineContains(["-target", "wasm32-unknown-none-wasm"])
                task.checkCommandLineDoesNotContain("-reproducible")
                task.checkCommandLineDoesNotContain("-filelist")
                task.checkCommandLineDoesNotContain("-dependency_info")
                task.checkCommandLineMatches([.anySequence, .prefix("@"), .anySequence])
            }

            results.checkNoDiagnostics()
        }
    }
}
