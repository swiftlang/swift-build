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
@_spi(Testing) import SWBCore
import SWBTestSupport
import SWBUtil

@Suite fileprivate struct DeveloperCommandLineToolsTests: CoreBasedTests {
    @Test
    func toolchainDefinesToolchainDir() async throws {
        struct Context: ToolchainRegistryExtensionAdditionalToolchainsContext {
            var hostOperatingSystem: OperatingSystem
            var developerPath: Core.DeveloperPath
            var toolchainRegistry: ToolchainRegistry
            var fs: any FSProxy
        }

        let core = try await getCore()
        let commandLineToolsPath = Path.root.join("Library").join("Developer").join("CommandLineTools")
        let context = Context(hostOperatingSystem: .macOS, developerPath: .xcode(commandLineToolsPath), toolchainRegistry: core.toolchainRegistry, fs: PseudoFS())

        var toolchains: [Toolchain] = []
        for toolchainExtension in core.pluginManager.extensions(of: ToolchainRegistryExtensionPoint.self) {
            toolchains += (try? await toolchainExtension.additionalToolchains(context: context)) ?? []
        }

        let toolchain = try #require(toolchains.filter { $0.path == commandLineToolsPath }.only)
        #expect(toolchain.identifier == ToolchainRegistry.defaultToolchainIdentifier)
        #expect(toolchain.defaultSettingsWhenPrimary["TOOLCHAIN_DIR"] == .plString(commandLineToolsPath.str))
    }

    @Test(.requireSDKs(.macOS))
    func sdkDropsPlatformRelativeTestingSearchPaths() async throws {
        struct Context: SDKRegistryExtensionAdditionalSDKsContext, @unchecked Sendable {
            var hostOperatingSystem: OperatingSystem
            var developerPath: Core.DeveloperPath
            var platformRegistry: PlatformRegistry
            var fs: any FSProxy
        }

        let core = try await getCore()
        let fs = PseudoFS()
        let commandLineToolsPath = Path.root.join("Library").join("Developer").join("CommandLineTools")
        let sdkPath = commandLineToolsPath.join("SDKs").join("MacOSX.sdk")
        try fs.createDirectory(sdkPath, recursive: true)
        try await fs.writePlist(sdkPath.join("SDKSettings.plist"), .plDict([
            "CanonicalName": .plString("macosx"),
            "DefaultProperties": .plDict([
                "PLATFORM_NAME": .plString("macosx"),
                "TEST_FRAMEWORK_SEARCH_PATHS": .plString("$(inherited) $(PLATFORM_DIR)/Developer/Library/Frameworks"),
                "TEST_LIBRARY_SEARCH_PATHS": .plString("$(inherited) $(PLATFORM_DIR)/Developer/usr/lib"),
            ]),
        ]))

        let context = Context(hostOperatingSystem: .macOS, developerPath: .xcode(commandLineToolsPath), platformRegistry: core.platformRegistry, fs: fs)
        var sdks: [(path: Path, platform: SWBCore.Platform?, data: [String: PropertyListItem])] = []
        for sdkExtension in core.pluginManager.extensions(of: SDKRegistryExtensionPoint.self) {
            sdks += (try? await sdkExtension.additionalSDKs(context: context)) ?? []
        }

        let sdk = try #require(sdks.filter { $0.path == sdkPath }.only)
        let defaultProperties = try #require(sdk.data["DefaultProperties"]?.dictValue)
        #expect(defaultProperties["PLATFORM_NAME"] == .plString("macosx"))
        #expect(defaultProperties["TEST_FRAMEWORK_SEARCH_PATHS"] == nil)
        #expect(defaultProperties["TEST_LIBRARY_SEARCH_PATHS"] == nil)
    }

    @Test
    func platformDefinesTestingSearchPaths() async throws {
        struct Context: PlatformInfoExtensionAdditionalPlatformsContext {
            var hostOperatingSystem: OperatingSystem
            var developerPath: Core.DeveloperPath
            var fs: any FSProxy
        }

        let core = try await getCore()
        let fs = PseudoFS()
        let commandLineToolsPath = Path.root.join("Library").join("Developer").join("CommandLineTools")
        let sdkPath = commandLineToolsPath.join("SDKs").join("MacOSX.sdk")
        try fs.createDirectory(sdkPath, recursive: true)
        try await fs.writePlist(sdkPath.join("SDKSettings.plist"), .plDict(["Version": .plString("27.0")]))

        let context = Context(hostOperatingSystem: .macOS, developerPath: .xcode(commandLineToolsPath), fs: fs)
        var platforms: [(path: Path, data: [String: PropertyListItem])] = []
        for platformExtension in core.pluginManager.extensions(of: PlatformInfoExtensionPoint.self) {
            platforms += (try? platformExtension.additionalPlatforms(context: context)) ?? []
        }

        let platform = try #require(platforms.filter { $0.path == commandLineToolsPath }.only)
        let defaultProperties = try #require(platform.data["DefaultProperties"]?.dictValue)
        #expect(defaultProperties["TEST_FRAMEWORK_SEARCH_PATHS"] == .plString("$(inherited) $(DEVELOPER_DIR)/Library/Developer/Frameworks"))
        #expect(defaultProperties["TEST_LIBRARY_SEARCH_PATHS"] == .plString("$(inherited) $(DEVELOPER_DIR)/Library/Developer/usr/lib"))
    }
}
