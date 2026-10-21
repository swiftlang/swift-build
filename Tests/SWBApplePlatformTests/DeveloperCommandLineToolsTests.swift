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
}
