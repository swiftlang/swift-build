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
fileprivate struct BareMetalMachOTaskConstructionTests: CoreBasedTests {
    /// The bare-metal Mach-O platform takes the Darwin specs, so Mach-O images get the Darwin compiler and linker behavior
    /// without the generic Unix specs having to know about it.
    @Test(.requireSDKs(.host), .requirePlatform("none-macho"))
    func bareMetalMachOPlatformUsesDarwinSpecs() async throws {
        let swiftCompilerPath = try await self.swiftCompilerPath
        let swiftVersion = try await self.swiftVersion
        let testProject = TestProject(
            "aProject",
            groupTree: TestGroup(
                "SomeFiles", path: "Sources",
                children: [
                    TestFile("SwiftFile.swift"),
                    TestFile("CFile.c"),
                ]),
            targets: [
                TestStandardTarget(
                    "MyTool",
                    type: .commandLineTool,
                    buildConfigurations: [
                        TestBuildConfiguration("Debug",
                                               buildSettings: [
                                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                                "SDKROOT": "none-macho",
                                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                                "ARCHS": "armv7em",
                                                "VALID_ARCHS": "armv7em",
                                                "LLVM_TARGET_TRIPLE_VENDOR": "apple",
                                                "LLVM_TARGET_TRIPLE_SUFFIX": "-macho",
                                                "DEAD_CODE_STRIPPING": "YES",
                                                "ENABLE_TESTABILITY": "YES",
                                                "SWIFT_EXEC": swiftCompilerPath.str,
                                                "SWIFT_VERSION": swiftVersion,
                                               ]),
                    ],
                    buildPhases: [
                        TestSourcesBuildPhase([TestBuildFile("SwiftFile.swift"), TestBuildFile("CFile.c")]),
                    ]),
            ])
        let core = try await getCore()
        let tester = try TaskConstructionTester(core, testProject)

        let destination = RunDestinationInfo(
            platform: "none-macho",
            sdk: "none-macho",
            sdkVariant: nil,
            targetArchitecture: "armv7em",
            supportedArchitectures: ["armv7em"],
            disableOnlyActiveArch: false
        )
        let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

        await tester.checkBuild(parameters, runDestination: nil) { results in
            // swift-autolink-extract only understands ELF objects.
            results.checkNoTask(.matchTargetName("MyTool"), .matchRuleType("SwiftAutolinkExtract"))

            results.checkTask(.matchTargetName("MyTool"), .matchRuleType("CompileC")) { task in
                task.checkCommandLineContains(["-target", "armv7em-apple-none-macho"])
                task.checkCommandLineDoesNotContain("--sysroot")
            }

            results.checkTask(.matchTargetName("MyTool"), .matchRuleType("Ld")) { task in
                task.checkCommandLineDoesNotContain("--gc-sections")
                task.checkCommandLineDoesNotContain("-rdynamic")
            }

            results.checkNoDiagnostics()
        }
    }
}
