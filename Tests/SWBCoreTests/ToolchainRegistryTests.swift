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
import SWBUtil

@_spi(Testing) import SWBCore
import SWBServiceCore

@Suite fileprivate struct ToolchainRegistryTests: CoreBasedTests {
    let fs: any FSProxy = localFS

    /// Helper function for scanning test inputs.
    ///
    /// - parameter inputs: A list of test inputs, in the form (name, testData). These inputs will be written to files in a temporary directory for testing.
    /// - parameter perform: A block that runs with the registry that results from scanning the inputs, as well as the list of warnings and errors. Each warning and error is a pair of the path basename and the diagnostic message.
    private func withRegistryForTestInputs(strict: Bool = true,
                                           _ inputs: [(String, PropertyListItem?)],
                                           infoPlistName: String = "ToolchainInfo.plist",
                                           postProcess: (Path) throws -> Void = { _ in },
                                           perform: (ToolchainRegistry, [(String, String)], [(String, String)]) throws -> Void) async throws {
        try await withTemporaryDirectory { tmpDirPath in

            for (name, dataOpt) in inputs {
                let itemPath = tmpDirPath.join(name).join(infoPlistName)
                try fs.createDirectory(itemPath.dirname, recursive: true)

                // Write the test data to the path, if present.
                if let data = dataOpt {
                    try await fs.writePlist(itemPath, data)
                }
            }

            try postProcess(tmpDirPath)

            class TestDataDelegate : ToolchainRegistryDelegate {
                private let _diagnosticsEngine = DiagnosticsEngine()

                init(pluginManager: PluginManager) {
                    self.pluginManager = pluginManager
                }

                var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
                    return .init(_diagnosticsEngine)
                }

                var warnings: [(String, String)] {
                    return _diagnosticsEngine.diagnostics.pathMessageTuples(.warning)
                }

                var errors: [(String, String)] {
                    return _diagnosticsEngine.diagnostics.pathMessageTuples(.error)
                }

                var pluginManager: PluginManager

                var platformRegistry: PlatformRegistry? {
                    nil
                }
            }

            let pluginManager = await PluginManager(skipLoadingPluginIdentifiers: [])
            await pluginManager.registerExtensionPoint(DeveloperDirectoryExtensionPoint())
            await pluginManager.registerExtensionPoint(SpecificationsExtensionPoint())
            await pluginManager.registerExtensionPoint(ToolchainRegistryExtensionPoint())
            await pluginManager.register(BuiltinSpecsExtension(), type: SpecificationsExtensionPoint.self)
            struct MockDeveloperDirectoryExtensionPoint: DeveloperDirectoryExtension {
                func fallbackDeveloperDirectory(hostOperatingSystem: OperatingSystem) async throws -> Path? {
                    .root
                }
            }
            struct MockToolchainExtension: ToolchainRegistryExtension {
                func additionalToolchains(context: any ToolchainRegistryExtensionAdditionalToolchainsContext) async throws -> [Toolchain] {
                    guard context.toolchainRegistry.lookup(ToolchainRegistry.defaultToolchainIdentifier) == nil else {
                        return []
                    }
                    return [Toolchain(identifier: ToolchainRegistry.defaultToolchainIdentifier, displayName: "Mock", version: Version(), aliases: ["default"], path: .root, frameworkPaths: [], libraryPaths: [], defaultSettings: [:], overrideSettings: [:], defaultSettingsWhenPrimary: [:], executableSearchPaths: [], testingLibraryPlatformNames: [], fs: context.fs)]
                }
            }
            await pluginManager.register(MockDeveloperDirectoryExtensionPoint(), type: DeveloperDirectoryExtensionPoint.self)
            await pluginManager.register(MockToolchainExtension(), type: ToolchainRegistryExtensionPoint.self)
            let coreDelegate = TestingCoreDelegate()
            let core = await Core.getInitializedCore(coreDelegate, pluginManager: pluginManager, inferiorProductsPath: Path.root.join("invalid"), environment: [:], buildServiceModTime: Date(), connectionMode: .inProcess)
            guard let core else {
                let errors = coreDelegate.diagnostics.filter { $0.behavior == .error }
                for error in errors {
                    Issue.record(Comment(rawValue: error.formatLocalizedDescription(.debugWithoutBehavior)))
                }
                if errors.isEmpty {
                    Issue.record("Failed to initialize core but no errors were provided")
                }
                return
            }
            let delegate = TestDataDelegate(pluginManager: core.pluginManager)
            let registry = await ToolchainRegistry(delegate: delegate, searchPaths: [(tmpDirPath, strict: strict)], fs: fs, hostOperatingSystem: core.hostOperatingSystem)
            try perform(registry, delegate.warnings, delegate.errors)
        }
    }

    func _testLoadingIssues(strict: Bool) async throws {
        try await withRegistryForTestInputs(strict: strict, [
            ("unused", nil),
            ("a.xctoolchain", nil),
            ("b.xctoolchain", []),
            ("c.xctoolchain", ["bad": "bad"]),
            ("d.xctoolchain", ["Identifier": "d"]),
            ("e.xctoolchain", ["Identifier": "d"]),
            ("default.xctoolchain", ["Identifier": ToolchainRegistry.defaultToolchainIdentifier]),
            ("swift.xctoolchain", ["CFBundleIdentifier": "org.swift.3020161115a", "Aliases": ["swift"]]),
            ("swift-latest.xctoolchain", ["CFBundleIdentifier": "org.swift.latest"]),
        ]) { registry, warnings, errors in
            #expect(registry.toolchainsByIdentifier.keys.sorted(by: <) == [ToolchainRegistry.defaultToolchainIdentifier, "d", "org.swift.3020161115a"])

            if strict {
                #expect(warnings.isEmpty)
            }
            else {
                #expect(errors.isEmpty)
            }

            let issues = strict ? errors : warnings

            #expect(issues.count == 4)
            #expect(issues[0].0 == "a.xctoolchain")
            #expect(issues[0].1.hasPrefix("failed to load toolchain: could not find Info.plist in "))
            #expect(issues[1].0 == "b.xctoolchain")
            #expect(issues[1].1 == "failed to load toolchain: expected dictionary in toolchain data")
            #expect(issues[2].0 == "c.xctoolchain")
            #expect(issues[2].1 == "failed to load toolchain: invalid or missing 'Identifier' field")
            #expect(issues[3].0 == "e.xctoolchain")
            #expect(issues[3].1.hasPrefix("failed to load toolchain: toolchain 'd' already registered from "))

            #expect(registry.lookup("d") != nil)
            #expect(registry.lookup("d")!.identifier == "d")

            #expect(registry.lookup("default") != nil)
            #expect(registry.lookup("default")!.identifier == ToolchainRegistry.defaultToolchainIdentifier)
            #expect(registry.lookup("xcode")!.identifier == ToolchainRegistry.defaultToolchainIdentifier)
            #expect(registry.lookup("org.swift.3020161115a")!.identifier == "org.swift.3020161115a")
            #expect(registry.lookup("swift")!.identifier == "org.swift.3020161115a")
        }
    }

    @Test(.skipHostOS(.windows, "doesn't work well with auto-synthesized Windows toolchain, figure out how to handle this better"))
    func loadingErrors() async throws {
        try await _testLoadingIssues(strict: true)
    }

    @Test(.skipHostOS(.windows, "doesn't work well with auto-synthesized Windows toolchain, figure out how to handle this better"))
    func loadingWarnings() async throws {
        try await _testLoadingIssues(strict: false)
    }

    @Test
    func loadingDownloadableToolchain() async throws {
        let additionalToolchains: [String] = ["com.apple.dt.toolchain.XcodeDefault"]

        try await withRegistryForTestInputs([
            ("swift-newer.xctoolchain", ["CFBundleIdentifier": "org.swift.3020161115a", "Version": "3.0.220161211151", "Aliases": ["swift"]]),
            ("swift-older.xctoolchain", ["CFBundleIdentifier": "org.swift.3020161114a", "Version": "3.0.220161211141", "Aliases": ["swift"]]),
        ], infoPlistName: "Info.plist") { registry, _, errors in

            #expect(Set(registry.toolchainsByIdentifier.keys) == Set(["org.swift.3020161114a", "org.swift.3020161115a"] + additionalToolchains))
            #expect(errors.count == 0)
            #expect(registry.lookup("org.swift.3020161115a")?.identifier == "org.swift.3020161115a")
            #expect(registry.lookup("org.swift.3020161114a")?.identifier == "org.swift.3020161114a")

            // Alias lookup picks highest versioned toolchain when there's a conflict
            #expect(registry.lookup("swift")?.identifier == "org.swift.3020161115a")
        }
    }

    @Test
    func deriveDisplayName() throws {
        #expect(Toolchain.deriveDisplayName(identifier: ToolchainRegistry.defaultToolchainIdentifier) == "Xcode Default")
        #expect(Toolchain.deriveDisplayName(identifier: "com.apple.dt.toolchain.OSX13_3") == "OSX13_3")
        #expect(Toolchain.deriveDisplayName(identifier: "com.apple.dt.toolchain.iOS16_4") == "iOS16_4")
        #expect(Toolchain.deriveDisplayName(identifier: "OSSToolchain") == "OSSToolchain")
    }

    @Test
    func deriveAliases() {
        #expect(Toolchain.deriveAliases(path: Path("/Applications/Xcode.app/Contents/Developer/Toolchains/iOS11.0.xctoolchain"), identifier: "com.apple.dt.toolchain.iOS11_0") == Set<String>(["com.apple.dt.toolchain.ios11", "com.apple.dt.toolchain.ios", "ios11_0", "ios11.0", "ios11", "ios"]))

        #expect(Toolchain.deriveAliases(path: Path("/foo/bar.xctoolchain"), identifier: "foo.xyz") == Set<String>(["bar", "xyz"]))
    }

    @Test
    func deriveVersion() {
        #expect(Version(11, 0, 1) == Toolchain.deriveVersion(identifier: "com.apple.dt.toolchain.iOS11_0_1"))
    }

    @Test
    func swiftDeveloperToolchainSet() async throws {
        try await withRegistryForTestInputs([
            ("swift-org.xctoolchain", ["CFBundleIdentifier": "org.swift", "Version": "3.0.220161211141", "Aliases": ["swift"]]),
        ], infoPlistName: "Info.plist") { registry, _, errors in

            #expect(errors.count == 0)
            #expect(registry.lookup("org.swift")?.overrideSettings["SWIFT_DEVELOPMENT_TOOLCHAIN"]?.looselyTypedBoolValue == true)
        }
    }

    @Test
    func customBuildSettings() async throws {
        try await withRegistryForTestInputs([
            ("swift-org.xctoolchain", [
                "CFBundleIdentifier": "org.swift",
                "Version": "3.0.220161211141",
                "Aliases": ["swift"],
                "DefaultBuildSettings": ["dfoo": "DefaultValue"],
                "OverrideBuildSettings": ["ofoo": "OverrideValue"]]),
        ], infoPlistName: "Info.plist") { registry, _, errors in

            #expect(errors.count == 0)
            #expect(registry.lookup("org.swift")?.defaultSettings["dfoo"]?.stringValue == "DefaultValue")
            #expect(registry.lookup("org.swift")?.overrideSettings["ofoo"]?.stringValue == "OverrideValue")

            // Validate the settings are correct for rdar://46784630.
            #expect(registry.lookup("org.swift")?.overrideSettings["SWIFT_DEVELOPMENT_TOOLCHAIN"]?.looselyTypedBoolValue == true)
            #expect(registry.lookup("org.swift")?.overrideSettings["SWIFT_USE_DEVELOPMENT_TOOLCHAIN_RUNTIME"]?.looselyTypedBoolValue == true)
        }
    }
}
