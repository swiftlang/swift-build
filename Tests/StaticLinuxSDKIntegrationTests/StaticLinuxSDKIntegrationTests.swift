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

import Foundation
import Testing
import SWBTestSupport
import SWBProtocol
@_spi(Testing) import SWBCore
import SWBUtil

fileprivate extension Core {
    func findStaticLinuxSwiftSDK() async throws -> SwiftSDK? {
        try await findSwiftSDK(.prefix("static-linux-"))
    }
}

fileprivate extension Trait where Self == Testing.ConditionTrait {
    static var requiresStaticLinuxSwiftSDK: Self {
        requireSwiftSDK(.prefix("static-linux-"), in: { try await StaticLinuxSDKIntegrationTests.getSwiftSDKIntegrationTestingCore() })
    }
}

@Suite
fileprivate struct StaticLinuxSDKIntegrationTests: CoreBasedTests {
    @Test(.requireSDKs(.host), .requiresStaticLinuxSwiftSDK, .skipXcodeToolchain)
    func basicExecutable() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                        "SWIFT_VERSION": swiftVersion,
                        "LINKER_DRIVER": "auto",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "tool",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"])
                        ],
                    )
                ])

            let core = try await Self.getSwiftSDKIntegrationTestingCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<< """
                    #if canImport(Musl)
                    print("Hello from Static Linux!")
                    #else
                    #error("should not be enabled")
                    #endif
                """
            }

            let hostArch = try {
                let arch = try #require(Architecture.hostStringValue)
                if arch == "arm64" {
                    return "aarch64"
                }
                return arch
            }()
            let triple = "\(hostArch)-swift-linux-musl"
            let swiftSDK = try #require(await core.findStaticLinuxSwiftSDK())
            let destination = try RunDestinationInfo(sdkManifestPath: swiftSDK.manifestPath, triple: triple, targetArchitecture: hostArch, supportedArchitectures: [hostArch], disableOnlyActiveArch: false, core: core)
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()

                // We can only run the built executable on a Linux host
                guard core.hostOperatingSystem == .linux else {
                    return
                }

                let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: projectDir.join("build").join("Debug-linux").join("tool").str), arguments: [])
                #expect(executionResult.exitStatus == .exit(0))
                #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello from Static Linux!\n")
                #expect(String(decoding: executionResult.stderr, as: UTF8.self) == "")
            }
        }
    }
}
