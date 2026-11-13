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

import Foundation
import Testing

import SWBCore
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct MachOSwiftSDKTaskConstructionTests: CoreBasedTests {
    /// A Swift SDK for an Apple OS produces Mach-O images. It is built with the bare-metal Mach-O platform, which takes the Darwin specs, like armv7em-apple-none-macho.
    @Test(.requireSDKs(.host), .requirePlatform("none"), .requireHostOS(.macOS))
    func machOSwiftSDKOnTheBareMetalPlatformUsesMachOBehavior() async throws {
        try await withTemporaryDirectory { tmpDir in
            let swiftCompilerPath = try await self.swiftCompilerPath
            let swiftVersion = try await self.swiftVersion

            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            let triple = "\(arch)-apple-macos15.0"

            let testProject = try await TestProject(
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
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
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
            // Use a dedicated core for this test so the SDKs it registers do not impact other tests
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, testProject)

            let sdkManifestPath = tmpDir.join("swift-sdk.json")
            let swiftSDKRoot = tmpDir.join("Root.sdk")
            try await localFS.writeFileContents(sdkManifestPath, waitForNewTimestamp: false, body: { stream in
                stream.write("""
                {
                    "schemaVersion" : "4.0",
                    "targetTriples" : {
                        "\(triple)" : {
                            "sdkRootPath" : "Root.sdk",
                            "swiftResourcesPath" : "swift.xctoolchain/usr/lib/swift",
                            "swiftStaticResourcesPath" : "swift.xctoolchain/usr/lib/swift"
                        }
                    }
                }
                """)
            })

            let destination = try RunDestinationInfo(sdkManifestPath: sdkManifestPath, triple: triple, targetArchitecture: arch, supportedArchitectures: [arch], disableOnlyActiveArch: false, core: core)
            let parameters = BuildParameters(configuration: "Debug", activeRunDestination: destination)

            await tester.checkBuild(parameters, runDestination: nil, targetName: "MyTool", fs: localFS) { results in
                // swift-autolink-extract only understands ELF objects.
                results.checkNoTask(.matchTargetName("MyTool"), .matchRuleType("SwiftAutolinkExtract"))

                // The deployment target of the Swift SDK is the version of its triple.
                results.checkTask(.matchTargetName("MyTool"), .matchRuleType("SwiftDriver Compilation")) { task in
                    task.checkCommandLineContains(["-target", triple])
                }

                // The Darwin clang driver finds the SDK with -isysroot; --sysroot is the GNU spelling.
                results.checkTask(.matchTargetName("MyTool"), .matchRuleType("CompileC")) { task in
                    task.checkCommandLineContains(["-isysroot", swiftSDKRoot.str])
                    task.checkCommandLineContains(["-target", triple])
                    task.checkCommandLineDoesNotContain("--sysroot")
                }

                results.checkTask(.matchTargetName("MyTool"), .matchRuleType("Ld")) { task in
                    // ld64 rejects --gc-sections, and a Mach-O image has no test host to export symbols for.
                    task.checkCommandLineDoesNotContain("--gc-sections")
                    task.checkCommandLineDoesNotContain("-rdynamic")
                }

                results.checkNoDiagnostics()
            }
        }
    }
}

@Suite
fileprivate struct SwiftSDKBuildTargetInfoTests: CoreBasedTests {
    /// Swift SDKs are their own platform: a Swift SDK for an Apple OS must not share the platform of the host.
    @Test(.requireHostOS(.macOS))
    func swiftSDKForAnAppleOSUsesTheBareMetalPlatform() async throws {
        let core = try await getCore()

        let swiftSDK = try core.buildTargetInfo(triple: "arm64-apple-macos15.0", isSwiftSDK: true)
        #expect(swiftSDK.platformName == "none-macho")
        #expect(swiftSDK.deploymentTargetSettingName == nil)
        #expect(swiftSDK.buildProductsDirectorySuffix == "-none-macho-arm64")

        // The platform of a toolchain SDK is unchanged.
        let toolchain = try core.buildTargetInfo(triple: "arm64-apple-macos15.0")
        #expect(toolchain.platformName == "macosx")
        #expect(toolchain.deploymentTargetSettingName != nil)
    }

    /// Only Swift SDKs for Apple platforms move to the bare-metal platform; the others keep the specs of their own platform.
    @Test(.requireHostOS(.macOS))
    func swiftSDKForOtherPlatformsKeepsItsPlatform() async throws {
        let core = try await getCore()

        let linux = try core.buildTargetInfo(triple: "x86_64-unknown-linux-gnu", isSwiftSDK: true)
        #expect(linux.platformName == "linux")

        let bareMetal = try core.buildTargetInfo(triple: "armv7em-apple-none-macho", isSwiftSDK: true)
        #expect(bareMetal.platformName == "none-macho")
    }
}
