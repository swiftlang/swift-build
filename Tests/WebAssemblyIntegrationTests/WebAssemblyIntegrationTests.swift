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

private func findWebAssemblySwiftSDK() -> SwiftSDK? {
    let wasmSDKs = try? SwiftSDK.findSDKs(targetTriples: ["wasm32-unknown-wasip1"], fs: localFS, hostOperatingSystem: ProcessInfo.processInfo.hostOperatingSystem())
    let nonEmbeddedWASMSDK = wasmSDKs?.filter { !$0.identifier.contains("embedded") }.only
    return nonEmbeddedWASMSDK
}

extension Trait where Self == Testing.ConditionTrait {
    static var requiresWebAssemblySwiftSDK: Self {
        enabled("WebAssembly Swift SDK is not installed", {
            return findWebAssemblySwiftSDK() != nil
        })
    }
}

@Suite
fileprivate struct WebAssemblyIntegrationTests: CoreBasedTests {
    @Test(.requireSDKs(.host), .requiresWebAssemblySwiftSDK, .skipXcodeToolchain)
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
            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<< """
                    #if os(WASI)
                    print("Hello from WebAssembly!")
                    #endif
                """
            }

            let swiftSDK = try #require(findWebAssemblySwiftSDK())
            let destination = RunDestinationInfo(buildTarget: .swiftSDK(sdkManifestPath: swiftSDK.manifestPath.str, triple: "wasm32-unknown-wasip1"), targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false)
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()
                let wasmKitPath = try #require(try core.coreSettings.defaultToolchain?.executableSearchPaths.lookup(subject: .executable(basename: "wasmkit"), operatingSystem: ProcessInfo.processInfo.hostOperatingSystem()))
                let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: wasmKitPath.str), arguments: ["run", projectDir.join("build").join("Debug-webassembly").join("tool").str])
                #expect(executionResult.exitStatus == .exit(0))
                #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello from WebAssembly!\n")
                #expect(String(decoding: executionResult.stderr, as: UTF8.self) == "")
            }
        }
    }
}
