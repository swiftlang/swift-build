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

private import Foundation
@_spi(Testing) package import SWBCore
package import SWBUtil
import SWBTaskConstruction
import SWBTaskExecution
import SWBServiceCore

#if USE_STATIC_PLUGIN_INITIALIZATION
private import SWBAndroidPlatform
private import SWBApplePlatform
private import SWBGenericUnixPlatform
private import SWBQNXPlatform
private import SWBUniversalPlatform
private import SWBWebAssemblyPlatform
private import SWBWindowsPlatform
#endif

/// Testing endpoints
extension Core {
    /// Get an uninitialized Core suitable for testing the Core implementation.
    ///
    /// This core is uninitialized, and is not expected to be suitable for general use. It is useful for performance testing specific parts of the Core loading mechanisms.
    static func createTestingCore() async throws -> (Core, [Diagnostic]) {
        let hostOperatingSystem = try ProcessInfo.processInfo.hostOperatingSystem()
        let developerPath: Core.DeveloperPath
        if hostOperatingSystem == .macOS {
            developerPath = .xcode(try await Xcode.getActiveDeveloperDirectoryPath())
        } else {
            developerPath = .fallback(Path.root)
        }
        let delegate = TestingCoreDelegate()
        return await (try Core(delegate: delegate, hostOperatingSystem: hostOperatingSystem, pluginManager: PluginManager(skipLoadingPluginIdentifiers: []), developerPath: developerPath, resourceSearchPaths: [], inferiorProductsPath: nil, additionalContentPaths: [], environment: [:], buildServiceModTime: Date(), connectionMode: .inProcess), delegate.diagnostics)
    }

    /// Get an initialized Core suitable for testing.
    ///
    /// This function requires there to be no errors during loading the core.
    package static func createInitializedTestingCore(skipLoadingPluginsNamed: Set<String>, registerExtraPlugins: @PluginExtensionSystemActor (PluginManager) -> Void, simulatedInferiorProductsPath: Path? = nil, environment: [String:String] = [:], delegate: TestingCoreDelegate? = nil) async throws -> Core {
        // When this code is being loaded directly via unit tests, find the running Xcode path.
        //
        // This is a "well known" launch parameter set in Xcode's schemes.
        let developerPath: DeveloperPath?
        if let xcodeDeveloperDirPath = getEnvironmentVariable("XCODE_DEVELOPER_DIR_PATH").map(Path.init) {
            developerPath = .xcode(xcodeDeveloperDirPath)
        } else {
            // In the context of auto-generated package schemes, try to infer the active Xcode.
            let potentialDeveloperPath = getEnvironmentVariable("PATH")?.components(separatedBy: String(Path.pathEnvironmentSeparator)).first.map(Path.init)?.dirname.dirname
            let versionInfo = potentialDeveloperPath?.dirname.join("version.plist")
            if let versionInfo = versionInfo, (try? PropertyList.fromPath(versionInfo, fs: localFS))?.dictValue?["ProjectName"] == "IDEApplication" {
                developerPath = potentialDeveloperPath.map { .xcode($0) }
            } else {
                developerPath = nil
            }
        }

        // Unset variables which may interfere with testing in Swift CI
        for variable in ["SWIFT_EXEC", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC", "SWIFT_DRIVER_SWIFT_EXEC"] {
            try POSIX.unsetenv(variable)
        }

        // When this code is being loaded directly via unit tests *and* we detect the products directory we are running in is for Xcode, then we should run using inferior search paths.
        let inferiorProductsPath: Path? = self.inferiorProductsPath()

        // Compute additional content paths.
        var additionalContentPaths = [Path]()
        if let simulatedInferiorProductsPath {
            additionalContentPaths.append(simulatedInferiorProductsPath)
        }

        let pluginManager = await PluginManager(skipLoadingPluginIdentifiers: skipLoadingPluginsNamed)

        @PluginExtensionSystemActor func extraPluginRegistration(pluginPaths: [Path]) {
            pluginManager.registerExtensionPoint(SpecificationsExtensionPoint())
            pluginManager.registerExtensionPoint(SettingsBuilderExtensionPoint())
            pluginManager.registerExtensionPoint(SDKRegistryExtensionPoint())
            pluginManager.registerExtensionPoint(PlatformInfoExtensionPoint())
            pluginManager.registerExtensionPoint(ToolchainRegistryExtensionPoint())
            pluginManager.registerExtensionPoint(EnvironmentExtensionPoint())
            pluginManager.registerExtensionPoint(InputFileGroupingStrategyExtensionPoint())
            pluginManager.registerExtensionPoint(TaskProducerExtensionPoint())
            pluginManager.registerExtensionPoint(DeveloperDirectoryExtensionPoint())
            pluginManager.registerExtensionPoint(DiagnosticToolingExtensionPoint())
            pluginManager.registerExtensionPoint(SDKVariantInfoExtensionPoint())
            pluginManager.registerExtensionPoint(FeatureAvailabilityExtensionPoint())
            pluginManager.registerExtensionPoint(TaskActionExtensionPoint())

            pluginManager.register(BuiltinSpecsExtension(), type: SpecificationsExtensionPoint.self)

            pluginManager.register(BuiltinTaskActionsExtension(), type: TaskActionExtensionPoint.self)

            for path in pluginPaths {
                pluginManager.load(at: path)
            }

            #if USE_STATIC_PLUGIN_INITIALIZATION
            if !skipLoadingPluginsNamed.contains("com.apple.dt.SWBAndroidPlatformPlugin") {
                SWBAndroidPlatform.initializePlugin(pluginManager)
            }
            if !skipLoadingPluginsNamed.contains("com.apple.dt.SWBApplePlatformPlugin") {
                SWBApplePlatform.initializePlugin(pluginManager)
            }
            if !skipLoadingPluginsNamed.contains("com.apple.dt.SWBGenericUnixPlatformPlugin") {
                SWBGenericUnixPlatform.initializePlugin(pluginManager)
            }
            if !skipLoadingPluginsNamed.contains("com.apple.dt.SWBQNXPlatformPlugin") {
                SWBQNXPlatform.initializePlugin(pluginManager)
            }
            if !skipLoadingPluginsNamed.contains("com.apple.dt.SWBUniversalPlatformPlugin") {
                SWBUniversalPlatform.initializePlugin(pluginManager)
            }
            if !skipLoadingPluginsNamed.contains("com.apple.dt.SWBWebAssemblyPlatformPlugin") {
                SWBWebAssemblyPlatform.initializePlugin(pluginManager)
            }
            if !skipLoadingPluginsNamed.contains("com.apple.dt.SWBWindowsPlatformPlugin") {
                SWBWindowsPlatform.initializePlugin(pluginManager)
            }
            #endif

            registerExtraPlugins(pluginManager)
        }

        let delegate = delegate ?? TestingCoreDelegate()
        guard let core = await Core.getInitializedCore(delegate, pluginManager: pluginManager, developerPath: developerPath, inferiorProductsPath: inferiorProductsPath, extraPluginRegistration: extraPluginRegistration, additionalContentPaths: additionalContentPaths, environment: environment, buildServiceModTime: Date(), connectionMode: .inProcess) else {
            throw CoreInitializationError(diagnostics: delegate.diagnostics)
        }

        return core
    }
}

/// Performance testing endpoints.
extension Core {
    package static func perfTestSpecRegistration() async throws {
        // Create the core.
        let (core, _) = try await Core.createTestingCore()

        // Force the spec registry to load.
        await core.initializeSpecRegistry()

        let _ = core.specRegistry
    }

    package static func perfTestSpecLoading() async throws {
        // Create the core.
        let (core, _) = try await Core.createTestingCore()

        // Force the spec registry to load.
        await core.initializeSpecRegistry()

        // 'loadAllSpecs' uses the platform registry, and needs to be initalized since core.platformRegistry is a delayed init property.
        await core.initializePlatformRegistry()

        core.loadAllSpecs()
    }
}

package struct CoreInitializationError: Error, CustomStringConvertible, LocalizedError {
    package let diagnostics: [Diagnostic]

    init(diagnostics: [Diagnostic]) {
        self.diagnostics = diagnostics
    }

    package var description: String {
        "Unable to create core due to \(diagnostics.filter { $0.behavior == .error }.count) errors"
    }

    package var errorDescription: String? {
        description
    }
}

package final class TestingCoreDelegate: CoreDelegate, Sendable {
    private let _diagnosticsEngine = DiagnosticsEngine()
    package let enableSerializedDiagnosticsParsing: Bool
    package let enableOptimizationRemarksParsing: Bool

    package init() {
        self.enableSerializedDiagnosticsParsing = true
        self.enableOptimizationRemarksParsing = true
    }

    package var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return .init(_diagnosticsEngine)
    }

    package var diagnostics: [Diagnostic] {
        return _diagnosticsEngine.diagnostics
    }

    package var hasErrors: Bool {
        return _diagnosticsEngine.hasErrors
    }

    package var errors: [(String, String)] {
        return _diagnosticsEngine.diagnostics.pathMessageTuples(.error)
    }

    package var warnings: [(String, String)] {
        return _diagnosticsEngine.diagnostics.pathMessageTuples(.warning)
    }
}
