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

import Testing

import SWBTestSupport
@_spi(Testing) import SWBUtil

import Foundation

@_spi(Testing) import SWBCore
import SWBServiceCore

@Suite fileprivate struct CoreTests: CoreBasedTests {
    @Test
    func corePaths() async throws {
        let core = try await getCore()
        switch try ProcessInfo.processInfo.hostOperatingSystem() {
        case .macOS:
            XCTAssertMatch(core.developerPath.path.str, .suffix(".app/Contents/Developer"))
        case .windows:
            XCTAssertMatch(core.developerPath.path.str, .suffix("\\AppData\\Local\\Programs\\Swift"))
        default:
            #expect(core.developerPath.path.str == "/")
        }
    }

    @Test(.requireSDKs(.macOS))
    func platformLoading_macOS() async throws {
        let core = try await getCore()

        let identifier = "com.apple.platform.macosx"
        if let platform = core.platformRegistry.lookup(identifier: identifier) {
            #expect(platform.signingContext is MacSigningContext)

            let sdkCanonicalName = try #require(platform.sdkCanonicalName)
            let publicSDK = try #require(core.sdkRegistry.lookup(sdkCanonicalName))
            let macOSSDKVariant = try #require(publicSDK.defaultVariant)
            #expect(macOSSDKVariant.deviceFamilies.list == [
                .init(name: "mac", displayName: "Mac")
            ])

            let macCatalystSDKVariant = try #require(publicSDK.variant(for: MacCatalystInfo.sdkVariantName))
            #expect(macCatalystSDKVariant.deviceFamilies.list == [
                .init(identifier: 2, name: "ipad", displayName: "iPad"),
                .init(identifier: 6, name: "mac", displayName: "Mac")
            ])
        }
        else {
            Issue.record("did not load platform '\(identifier)'")
        }
    }

    @Test(.requireSDKs(.iOS))
    func platformLoading_iOS() async throws {
        let core = try await getCore()

        do {
            let identifier = "com.apple.platform.iphoneos"
            if let platform = core.platformRegistry.lookup(identifier: identifier) {
                #expect(platform.signingContext is DeviceSigningContext)

                let sdkCanonicalName = try #require(platform.sdkCanonicalName)
                let publicSDK = try #require(core.sdkRegistry.lookup(sdkCanonicalName))
                let defaultVariant = try #require(publicSDK.defaultVariant)
                #expect(defaultVariant.deviceFamilies.list == [
                    .init(identifier: 1, name: "iphone", displayName: "iPhone"),
                    .init(identifier: 2, name: "ipad", displayName: "iPad"),
                ])
            }
            else {
                Issue.record("did not load platform '\(identifier)'")
            }
        }

        do {
            let identifier = "com.apple.platform.iphonesimulator"
            if let platform = core.platformRegistry.lookup(identifier: identifier) {
                #expect(platform.signingContext is SimulatorSigningContext)

                let sdkCanonicalName = try #require(platform.sdkCanonicalName)
                let publicSDK = try #require(core.sdkRegistry.lookup(sdkCanonicalName))
                let defaultVariant = try #require(publicSDK.defaultVariant)
                #expect(defaultVariant.deviceFamilies.list == [
                    DeviceFamily(identifier: 1, name: "iphone", displayName: "iPhone"),
                    DeviceFamily(identifier: 2, name: "ipad", displayName: "iPad"),
                ])
            }
            else {
                Issue.record("did not load platform '\(identifier)'")
            }
        }
    }

    @Test(.requireSDKs(.tvOS))
    func platformLoading_tvOS() async throws {
        let core = try await getCore()

        do {
            let identifier = "com.apple.platform.appletvos"
            if let platform = core.platformRegistry.lookup(identifier: identifier) {
                #expect(platform.signingContext is DeviceSigningContext)

                let sdkCanonicalName = try #require(platform.sdkCanonicalName)
                let publicSDK = try #require(core.sdkRegistry.lookup(sdkCanonicalName))
                let defaultVariant = try #require(publicSDK.defaultVariant)
                #expect(defaultVariant.deviceFamilies.list == [
                    DeviceFamily(identifier: 3, name: "tv", displayName: "Apple TV")
                ])
            }
            else {
                Issue.record("did not load platform '\(identifier)'")
            }
        }

        do {
            let identifier = "com.apple.platform.appletvsimulator"
            if let platform = core.platformRegistry.lookup(identifier: identifier) {
                #expect(platform.signingContext is SimulatorSigningContext)

                let sdkCanonicalName = try #require(platform.sdkCanonicalName)
                let publicSDK = try #require(core.sdkRegistry.lookup(sdkCanonicalName))
                let defaultVariant = try #require(publicSDK.defaultVariant)
                #expect(defaultVariant.deviceFamilies.list == [
                    DeviceFamily(identifier: 3, name: "tv", displayName: "Apple TV")
                ])
            }
            else {
                Issue.record("did not load platform '\(identifier)'")
            }
        }
    }

    @Test(.requireSDKs(.watchOS))
    func platformLoading_watchOS() async throws {
        let core = try await getCore()

        do {
            let identifier = "com.apple.platform.watchos"
            if let platform = core.platformRegistry.lookup(identifier: identifier) {
                #expect(platform.signingContext is DeviceSigningContext)

                let sdkCanonicalName = try #require(platform.sdkCanonicalName)
                let publicSDK = try #require(core.sdkRegistry.lookup(sdkCanonicalName))
                let defaultVariant = try #require(publicSDK.defaultVariant)
                #expect(defaultVariant.deviceFamilies.list == [
                    DeviceFamily(identifier: 4, name: "watch", displayName: "Apple Watch")
                ])
            }
            else {
                Issue.record("did not load platform '\(identifier)'")
            }
        }

        do {
            let identifier = "com.apple.platform.watchsimulator"
            if let platform = core.platformRegistry.lookup(identifier: identifier) {
                #expect(platform.signingContext is SimulatorSigningContext)

                let sdkCanonicalName = try #require(platform.sdkCanonicalName)
                let publicSDK = try #require(core.sdkRegistry.lookup(sdkCanonicalName))
                let defaultVariant = try #require(publicSDK.defaultVariant)
                #expect(defaultVariant.deviceFamilies.list == [
                    DeviceFamily(identifier: 4, name: "watch", displayName: "Apple Watch")
                ])
            }
            else {
                Issue.record("did not load platform '\(identifier)'")
            }
        }
    }

    @Test(.requireSDKs(.xrOS))
    func platformLoading_visionOS() async throws {
        let core = try await getCore()

        do {
            let identifier = "com.apple.platform.xros"
            if let platform = core.platformRegistry.lookup(identifier: identifier) {
                #expect(platform.signingContext is DeviceSigningContext)

                let sdkCanonicalName = try #require(platform.sdkCanonicalName)
                let publicSDK = try #require(core.sdkRegistry.lookup(sdkCanonicalName))
                let defaultVariant = try #require(publicSDK.defaultVariant)
                #expect(defaultVariant.deviceFamilies.list == [
                    DeviceFamily(identifier: 7, name: "vision", displayName: "Apple Vision")
                ])
            }
            else {
                Issue.record("did not load platform '\(identifier)'")
            }
        }

        do {
            let identifier = "com.apple.platform.xrsimulator"
            if let platform = core.platformRegistry.lookup(identifier: identifier) {
                #expect(platform.signingContext is SimulatorSigningContext)

                let sdkCanonicalName = try #require(platform.sdkCanonicalName)
                let publicSDK = try #require(core.sdkRegistry.lookup(sdkCanonicalName))
                let defaultVariant = try #require(publicSDK.defaultVariant)
                #expect(defaultVariant.deviceFamilies.list == [
                    DeviceFamily(identifier: 7, name: "vision", displayName: "Apple Vision")
                ])
            }
            else {
                Issue.record("did not load platform '\(identifier)'")
            }
        }
    }


    @Test(.requireHostOS(.macOS))
    func toolchainLoading() async throws {
        // Validate that we loaded the default toolchain.
        let defaultToolchain = try #require(await getCore().toolchainRegistry.lookup("default"), "no default toolchain")
        #expect(defaultToolchain.identifier == ToolchainRegistry.defaultToolchainIdentifier)
    }

    final class Delegate : CoreDelegate {
        private let _diagnosticsEngine = DiagnosticsEngine()

        var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
            return .init(_diagnosticsEngine)
        }

        var diagnostics: [Diagnostic] {
            return _diagnosticsEngine.diagnostics
        }

        var hasErrors: Bool {
            return _diagnosticsEngine.hasErrors
        }

        var errors: [(String, String)] {
            return _diagnosticsEngine.diagnostics.pathMessageTuples(.error)
        }

        var warnings: [(String, String)] {
            return _diagnosticsEngine.diagnostics.pathMessageTuples(.warning)
        }
    }

    final class CoreDelegateResults: DiagnosticsCheckingResult {
        public var checkedErrors: Bool = false
        public var checkedWarnings: Bool = false
        public var checkedNotes: Bool = false
        public var checkedRemarks: Bool = false

        private var diagnostics: [Diagnostic]

        public init(_ diagnostics: [Diagnostic]) {
            self.diagnostics = diagnostics
        }

        public func getDiagnostics(_ forKind: DiagnosticKind) -> [String] {
            return diagnostics.filter { $0.behavior == forKind }.map { $0.formatLocalizedDescription(.debugWithoutBehavior) }
        }

        func getDiagnosticMessage(_ pattern: SWBTestSupport.StringPattern, kind: DiagnosticKind, checkDiagnostic: (Diagnostic) -> Bool) -> String? {
            for (index, event) in diagnostics.enumerated() {
                guard event.behavior == kind else {
                    continue
                }
                let message = event.formatLocalizedDescription(.debugWithoutBehavior)
                guard pattern ~= message else {
                    continue
                }
                guard checkDiagnostic(event) else {
                    continue
                }
                diagnostics.remove(at: index)
                return message
            }
            return nil
        }

        public func check(_ pattern: StringPattern, kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation, checkDiagnostic: (Diagnostic) -> Bool) -> Bool {
            let found = (getDiagnosticMessage(pattern, kind: kind, checkDiagnostic: checkDiagnostic) != nil)

            if !found, failIfNotFound {
                Issue.record("Unable to find \(kind.name): '\(pattern)' (other \(kind.name)s: \(getDiagnostics(kind)))", sourceLocation: sourceLocation)
            }
            return found
        }

        public func check(_ patterns: [StringPattern], diagnostics: [String], kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation) -> Bool {
            Issue.record("\(type(of: self)).check() for multiple patterns is not yet implemented", sourceLocation: sourceLocation)
            return false
        }
    }

    @Test
    func coreInvalidInferiorProductsPath() async throws {
        let delegate = TestingCoreDelegate()
        let core = try await Core.createInitializedTestingCore(skipLoadingPluginsNamed: [], registerExtraPlugins: { _ in }, simulatedInferiorProductsPath: .root.join("invalid"), delegate: delegate)

        let ignoredPlatforms = Set(["Linux"].map { $0 + ".platform" })

        // Ignore some SDK or toolchain related errors.
        // Also ignore warnings about invalid settings in sparse SDKs, as there are several existing SDKs like this.
        let errors = delegate.errors.filter { !ignoredPlatforms.contains($0.0) && !$0.0.hasSuffix(".xctoolchain") && !$0.1.hasSuffix("is not allowed in sparse SDK") }
        #expect(errors.isEmpty)

        let buildSystemSpec = core.coreSettings.coreBuildSystemSpec
        #expect(buildSystemSpec != nil)
    }

    @Test(.skipHostOS(.linux, "#expect(core == nil) crashes on Linux"))
    func coreLoadErrors() async throws {
        // Validate that the core fails if there are loading errors.
        try await withTemporaryDirectory { tmpDirPath in
            let fakePlatformPath = tmpDirPath.join("Platforms/Fake.platform")
            try localFS.createDirectory(fakePlatformPath, recursive: true)
            try await localFS.writePlist(fakePlatformPath.join("Info.plist"), .plDict([
                "Description": .plString("Fake"),
                "FamilyName": .plString("Fake"),
                "FamilyIdentifier": .plString("Fake"),
                "Identifier": .plString("com.apple.FakePlatform"),
                "Name": .plString("fake"),
                "Type": .plString("Platform"),
            ]))

            let delegate = Delegate()
            let pluginManager = await PluginManager(skipLoadingPluginIdentifiers: [])
            await pluginManager.registerExtensionPoint(SpecificationsExtensionPoint())
            await pluginManager.register(BuiltinSpecsExtension(), type: SpecificationsExtensionPoint.self)
            let core = await Core.getInitializedCore(delegate, pluginManager: pluginManager, developerPath: .fallback(tmpDirPath), buildServiceModTime: Date(), connectionMode: .inProcess)
            #expect(core == nil)

            let results = CoreDelegateResults(delegate.diagnostics)
            results.checkError(.prefix("missing required default toolchain"))
            results.checkNoDiagnostics()
        }
    }

    @Test(.skipIfEnvironmentVariableSet(key: .externalToolchainsDir))
    func externalToolchainsDir() async throws {
        try await withTemporaryDirectory { tmpDir in
            let originalToolchain = try await toolchainPathsCount()

            try await testExternalToolchainPath(withSetEnv: nil, expecting: [], originalToolchain)
            try await testExternalToolchainPath(withSetEnv: tmpDir.join("tmp/Foobar/MyDir").str, expecting: [tmpDir.join("tmp/Foobar/MyDir").str], originalToolchain)
            try await testExternalToolchainPath(withSetEnv: nil, expecting: [], originalToolchain)
            try await testExternalToolchainPath(withSetEnv: [tmpDir.join("tmp/MetalToolchain1.0").str, tmpDir.join("tmp/MetalToolchain2.0").str, tmpDir.join("tmp/MetalToolchain3.0").str].joined(separator: String(Path.pathEnvironmentSeparator)), expecting: [
                tmpDir.join("tmp/MetalToolchain1.0").str,
                tmpDir.join("tmp/MetalToolchain2.0").str,
                tmpDir.join("tmp/MetalToolchain3.0").str,
            ], originalToolchain)
            try await testExternalToolchainPath(withSetEnv: nil, expecting: [], originalToolchain)
            try await testExternalToolchainPath(withSetEnv: "", expecting: [], originalToolchain)

            // Environment overrides
            try await testExternalToolchainPath(withSetEnv: nil, expecting: [], originalToolchain) // Clear

            try await testExternalToolchainPath(environmentOverrides: ["Hello":"world"], expecting: [], originalToolchain)
            try await testExternalToolchainPath(environmentOverrides: ["EXTERNAL_TOOLCHAINS_DIR": tmpDir.join("tmp/Foobar/MyDir").str], expecting: [tmpDir.join("tmp/Foobar/MyDir").str], originalToolchain)
            try await testExternalToolchainPath(environmentOverrides: [:], expecting: [], originalToolchain)
            try await testExternalToolchainPath(environmentOverrides: [
                "EXTERNAL_TOOLCHAINS_DIR" : [tmpDir.join("tmp/MetalToolchain1.0").str, tmpDir.join("tmp/MetalToolchain2.0").str, tmpDir.join("tmp/MetalToolchain3.0").str].joined(separator: String(Path.pathEnvironmentSeparator)),
            ], expecting: [
                tmpDir.join("tmp/MetalToolchain1.0").str,
                tmpDir.join("tmp/MetalToolchain2.0").str,
                tmpDir.join("tmp/MetalToolchain3.0").str,
            ], originalToolchain)
            try await testExternalToolchainPath(environmentOverrides: [:], expecting: [], originalToolchain)
        }
    }

    func toolchainPathsCount() async throws -> Int {
        let delegate = Delegate()
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
        let core = await Core.getInitializedCore(delegate, pluginManager: pluginManager, inferiorProductsPath: Path.root.join("invalid"), environment: [:], buildServiceModTime: Date(), connectionMode: .inProcess)
        for diagnostic in delegate.diagnostics {
            if diagnostic.formatLocalizedDescription(.debug).hasPrefix("warning: found previously-unknown deployment target macro ") {
                continue
            }
            Issue.record("\(diagnostic.formatLocalizedDescription(.debug))")
        }
        return try #require(core?.toolchainPaths).count
    }

    func testExternalToolchainPath(withSetEnv externalToolchainPathsString: String?, expecting expectedPathStrings: [String], _ originalToolchainCount: Int) async throws {
        var env = Environment.current.filter { $0.key != .externalToolchainsDir }
        if let externalToolchainPathsString {
            env[.externalToolchainsDir] = externalToolchainPathsString
        }

        try await withEnvironment(env, clean: true) {
            #expect(getEnvironmentVariable(.externalToolchainsDir) == externalToolchainPathsString)

            try await testExternalToolchainPath(environmentOverrides: [:], expecting: expectedPathStrings, originalToolchainCount)
        }
    }

    func testExternalToolchainPath(environmentOverrides: [String:String], expecting expectedPathStrings: [String], _ originalToolchainCount: Int) async throws {
        let delegate = Delegate()
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
        let core = await Core.getInitializedCore(delegate, pluginManager: pluginManager, inferiorProductsPath: Path.root.join("invalid"), environment: environmentOverrides, buildServiceModTime: Date(), connectionMode: .inProcess)
        for diagnostic in delegate.diagnostics {
            if diagnostic.formatLocalizedDescription(.debug).hasPrefix("warning: found previously-unknown deployment target macro ") {
                continue
            }
            Issue.record("\(diagnostic.formatLocalizedDescription(.debug))")
        }
        let toolchainPaths = try #require(core?.toolchainPaths)
        for expectedPathString in expectedPathStrings {
            #expect(toolchainPaths.contains(where: { paths in
                paths.0 == Path(expectedPathString) && paths.strict == false
            }), "Unable to find \(expectedPathString)")
        }

        #expect(toolchainPaths.count == originalToolchainCount + expectedPathStrings.count)
    }
}
