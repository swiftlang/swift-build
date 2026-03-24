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

private func findStaticLinuxSwiftSDK() -> SwiftSDK? {
    guard let hostArch = Architecture.hostStringValue else {
        return nil
    }
    let triple = "\(hostArch)-swift-linux-musl"
    let sdks = try? SwiftSDK.findSDKs(targetTriples: [triple], fs: localFS, hostOperatingSystem: ProcessInfo.processInfo.hostOperatingSystem())
    return sdks?.first
}

extension Trait where Self == Testing.ConditionTrait {
    static var requiresStaticLinuxSwiftSDK: Self {
        enabled("Static Linux Swift SDK is not installed", {
            return findStaticLinuxSwiftSDK() != nil
        })
    }
}

@Suite
fileprivate struct StaticLinuxSDKIntegrationTests: CoreBasedTests {

    // Currently, the integration testing GitHub Actions in CI may download a matching toolchain
    // for the Swift SDK if the base image isn't a match. Currently, we hardcode knowledge of where
    // that toolchain will be installed, but we should consider updating the swiftlang shared workflows
    // with a better way of passing along this path.
    func getStaticLinuxSDKIntegrationTestingCore() async throws -> Core {
        // If a matching toolchain was downloaded, it will be in /github/home/.swift-toolchains
        let userToolchainsDir = Path("/github/home/.swift-toolchains")
        let userToolchains = (try? localFS.listdir(userToolchainsDir)) ?? []
        if let onlyUserToolchain = userToolchains.only {
            return try await Self.makeCore(developerPathOverride: .swiftToolchain(userToolchainsDir.join(onlyUserToolchain), xcodeDeveloperPath: nil))
        } else {
            // Otherwise, use the default fallback toolchain.
            return try await getCore()
        }
    }

    @Test(.requireSDKs(.host), .requiresStaticLinuxSwiftSDK, .skipXcodeToolchain, .requireHostOS(.linux))
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

            let core = try await getStaticLinuxSDKIntegrationTestingCore()
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

            let hostArch = try #require(Architecture.hostStringValue)
            let triple = "\(hostArch)-swift-linux-musl"
            let swiftSDK = try #require(findStaticLinuxSwiftSDK())
            let destination = RunDestinationInfo(buildTarget: .swiftSDK(sdkManifestPath: swiftSDK.manifestPath.str, triple: triple), targetArchitecture: hostArch, supportedArchitectures: [hostArch], disableOnlyActiveArch: false)
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()
                let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: projectDir.join("build").join("Debug-linux").join("tool").str), arguments: [])
                #expect(executionResult.exitStatus == .exit(0))
                #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello from Static Linux!\n")
                #expect(String(decoding: executionResult.stderr, as: UTF8.self) == "")
            }
        }
    }
}
