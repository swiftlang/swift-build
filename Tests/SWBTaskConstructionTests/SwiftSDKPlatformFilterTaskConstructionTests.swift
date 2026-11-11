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
fileprivate struct SwiftSDKPlatformFilterTaskConstructionTests: CoreBasedTests {
    /// Platform filter conditions, as SwiftPM emits them for package targets, match on the operating system of the Swift SDK's triple and not on
    /// the name of the platform it is built with. A Swift SDK for macOS built on the bare-metal Mach-O platform therefore still gets the settings
    /// that are scoped to macOS, such as the "@rpath" install name base of dynamic libraries.
    @Test(.requireSDKs(.host), .requirePlatform("none-macho"), .requireHostOS(.macOS))
    func swiftSDKForMacOSMatchesTheMacOSPlatformFilter() async throws {
        try await withTemporaryDirectory { tmpDir in
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            let triple = "\(arch)-apple-macos15.0"

            let package = TestPackageProject(
                "aPackage",
                groupTree: TestGroup("Sources", children: [TestFile("lib.c")]),
                targets: [
                    TestStandardTarget(
                        "MyLib",
                        type: .dynamicLibrary,
                        buildConfigurations: [
                            TestBuildConfiguration("Debug", buildSettings: [
                                "PRODUCT_NAME": "$(TARGET_NAME)",
                                "SDKROOT": "auto",
                                "SUPPORTED_PLATFORMS": "$(AVAILABLE_PLATFORMS)",
                                "DYLIB_INSTALL_NAME_BASE[__platform_filter=macos]": "@rpath",
                            ]),
                        ],
                        buildPhases: [
                            TestSourcesBuildPhase(["lib.c"]),
                        ]),
                ])
            let workspace = TestWorkspace("Workspace", projects: [package])
            // Use a dedicated core so the SDKs it registers do not impact other tests
            let core = try await Self.makeCore()
            let tester = try TaskConstructionTester(core, workspace)

            let sdkManifestPath = tmpDir.join("swift-sdk.json")
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

            await tester.checkBuild(parameters, runDestination: nil, targetName: "MyLib", fs: localFS) { results in
                results.checkTask(.matchTargetName("MyLib"), .matchRuleType("Ld")) { task in
                    task.checkCommandLineMatches([.anySequence, "-install_name", .prefix("@rpath/"), .anySequence])
                }
            }
        }
    }
}
