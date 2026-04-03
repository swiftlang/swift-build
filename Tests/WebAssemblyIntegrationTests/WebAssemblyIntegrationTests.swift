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
    func findWebAssemblySwiftSDK() async throws -> SwiftSDK? {
        try await findSwiftSDK("wasm")
    }
}

fileprivate extension Trait where Self == Testing.ConditionTrait {
    static var requiresWebAssemblySwiftSDK: Self {
        requireSwiftSDK("wasm", in: { try await WebAssemblyIntegrationTests.getSwiftSDKIntegrationTestingCore() })
    }
}

@Suite
fileprivate struct WebAssemblyIntegrationTests: CoreBasedTests {
    @Test(.requireSDKs(.host), .requiresWebAssemblySwiftSDK, .skipXcodeToolchain)
    func basicSwiftExecutable() async throws {
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
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
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
                    #if os(WASI)
                    print("Hello from WebAssembly!")
                    #endif
                """
            }

            let swiftSDK = try #require(await core.findWebAssemblySwiftSDK())
            let destination = try RunDestinationInfo(sdkManifestPath: swiftSDK.manifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()
                let settings = results.buildRequestContext.getCachedSettings(results.buildRequest.parameters)
                let wasmKitPath = try #require(try settings.executableSearchPaths.lookup(subject: .executable(basename: "wasmkit"), operatingSystem: ProcessInfo.processInfo.hostOperatingSystem()))
                let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: wasmKitPath.str), arguments: ["run", projectDir.join("build").join("Debug-webassembly").join("tool.wasm").str])
                #expect(executionResult.exitStatus == .exit(0))
                #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello from WebAssembly!\n")
                #expect(String(decoding: executionResult.stderr, as: UTF8.self) == "")
            }
        }
    }

    @Test(.requireSDKs(.host), .requiresWebAssemblySwiftSDK, .skipXcodeToolchain, .skipHostOS(.windows))
    func hostToolAndWasmExecutable() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let core = try await Self.getSwiftSDKIntegrationTestingCore()
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("tool.swift"),
                        TestFile("main.swift"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "CODE_SIGNING_ALLOWED": "NO",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": swiftVersion,
                        "SDKROOT": "auto",
                        "LINKER_DRIVER": "auto",
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "HostTool",
                        type: .hostBuildTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug")
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["tool.swift"])
                        ]
                    ),
                    TestStandardTarget(
                        "WasmApp",
                        type: .commandLineTool,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                            ])
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["main.swift"]),
                            TestShellScriptBuildPhase(
                                name: "Generate Resource",
                                shellPath: "/bin/bash",
                                originalObjectID: "GenerateResource",
                                contents: "${SCRIPT_INPUT_FILE_0} > ${SCRIPT_OUTPUT_FILE_0}",
                                inputs: ["$(BUILD_DIR)/$(CONFIGURATION)\(try core.hostOperatingSystem.hostEffectivePlatformName)/HostTool"],
                                outputs: ["$(TARGET_BUILD_DIR)/generated.txt"],
                                alwaysOutOfDate: false
                            ),
                        ],
                        dependencies: [
                            "HostTool"
                        ]
                    ),
                ])
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("tool.swift")) { stream in
                stream <<< """
                    @main struct HostTool {
                        static func main() {
                            print("Generated by host tool")
                        }
                    }
                """
            }

            try await tester.fs.writeFileContents(projectDir.join("main.swift")) { stream in
                stream <<< """
                    print("Hello from WebAssembly!")
                """
            }

            let swiftSDK = try #require(await core.findWebAssemblySwiftSDK())
            let destination = try RunDestinationInfo(sdkManifestPath: swiftSDK.manifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(action: .build, configuration: "Debug")
            let buildTargets = [BuildRequest.BuildTargetInfo(parameters: parameters, target: tester.workspace.targets(named: "WasmApp")[0])]
            let request = BuildRequest(parameters: parameters, buildTargets: buildTargets, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
            try await tester.checkBuild(runDestination: destination, buildRequest: request) { results in
                results.checkNoErrors()

                #expect(try tester.fs.read(projectDir.join("build/Debug-webassembly/generated.txt")).unsafeStringValue == "Generated by host tool\n")

                let settings = results.buildRequestContext.getCachedSettings(results.buildRequest.parameters)
                let wasmKitPath = try #require(try settings.executableSearchPaths.lookup(subject: .executable(basename: "wasmkit"), operatingSystem: ProcessInfo.processInfo.hostOperatingSystem()))
                let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: wasmKitPath.str), arguments: ["run", projectDir.join("build").join("Debug-webassembly").join("WasmApp.wasm").str])
                #expect(executionResult.exitStatus == .exit(0))
                #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello from WebAssembly!\n")
                #expect(String(decoding: executionResult.stderr, as: UTF8.self) == "")
            }
        }
    }

    @Test(.requireSDKs(.host), .requiresWebAssemblySwiftSDK, .skipXcodeToolchain)
    func basicCExecutable() async throws {
        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup(
                    "SomeFiles",
                    children: [
                        TestFile("main.c"),
                    ]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SWIFT_VERSION": swiftVersion,
                        "SDKROOT": "auto",
                        "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
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
                            TestSourcesBuildPhase(["main.c"])
                        ],
                    )
                ])
            let core = try await Self.getSwiftSDKIntegrationTestingCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)

            let projectDir = tester.workspace.projects[0].sourceRoot

            try await tester.fs.writeFileContents(projectDir.join("main.c")) { stream in
                stream <<< """
                    #include <stdio.h>
                    int main(void) {
                        printf("Hello from WebAssembly!");
                        return 0;
                    }
                """
            }

            let swiftSDK = try #require(await core.findWebAssemblySwiftSDK())
            let destination = try RunDestinationInfo(sdkManifestPath: swiftSDK.manifestPath, triple: "wasm32-unknown-wasip1", targetArchitecture: "wasm32", supportedArchitectures: ["wasm32"], disableOnlyActiveArch: false, core: core)
            try await tester.checkBuild(runDestination: destination) { results in
                results.checkNoErrors()
                let settings = results.buildRequestContext.getCachedSettings(results.buildRequest.parameters)
                let wasmKitPath = try #require(try settings.executableSearchPaths.lookup(subject: .executable(basename: "wasmkit"), operatingSystem: ProcessInfo.processInfo.hostOperatingSystem()))
                let executionResult = try await Process.getOutput(url: URL(fileURLWithPath: wasmKitPath.str), arguments: ["run", projectDir.join("build").join("Debug-webassembly").join("tool.wasm").str])
                #expect(executionResult.exitStatus == .exit(0))
                #expect(String(decoding: executionResult.stdout, as: UTF8.self) == "Hello from WebAssembly!")
                #expect(String(decoding: executionResult.stderr, as: UTF8.self) == "")
            }
        }
    }
}

extension OperatingSystem {
    var hostEffectivePlatformName: String {
        get throws {
            if self == .macOS {
                return ""
            } else {
                return "-\(try self.xcodePlatformName)"
            }
        }
    }
}
