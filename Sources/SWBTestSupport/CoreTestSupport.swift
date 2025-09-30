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
            developerPath = .swiftToolchain(.root, xcodeDeveloperPath: nil)
        }
        let delegate = TestingCoreDelegate()
        return await (try Core(delegate: delegate, hostOperatingSystem: hostOperatingSystem, pluginManager: MutablePluginManager(skipLoadingPluginIdentifiers: []).finalize(), developerPath: developerPath, resourceSearchPaths: [], inferiorProductsPath: nil, additionalContentPaths: [], environment: [:], buildServiceModTime: Date(), connectionMode: .inProcess), delegate.diagnostics)
    }

    /// Get an initialized Core suitable for testing.
    ///
    /// This function requires there to be no errors during loading the core.
    package static func createInitializedTestingCore(skipLoadingPluginsNamed: Set<String>, registerExtraPlugins: @PluginExtensionSystemActor (MutablePluginManager) -> Void, simulatedInferiorProductsPath: Path? = nil, environment: [String:String] = [:], delegate: TestingCoreDelegate? = nil, configurationDelegate: TestingCoreConfigurationDelegate? = nil) async throws -> Core {
        // When this code is being loaded directly via unit tests, find the running Xcode path.
        //
        // This is a "well known" launch parameter set in Xcode's schemes.
        let developerPath: DeveloperPath?
        if let xcodeDeveloperDirPath = getEnvironmentVariable("XCODE_DEVELOPER_DIR_PATH").map(Path.init) {
            developerPath = .xcode(xcodeDeveloperDirPath)
        } else {
            // In the context of auto-generated package schemes, try to infer the active Xcode.
            let potentialDeveloperPath = getEnvironmentVariable(.path)?.components(separatedBy: String(Path.pathEnvironmentSeparator)).first.map(Path.init)?.dirname.dirname
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

        // Handle Xcodes with an unbundled Metal toolchain by querying `xcodebuild` if needed.
        //
        // If the given environment already contains `EXTERNAL_TOOLCHAINS_DIR` and `TOOLCHAINS`, we're assuming that we do not have to obtain any toolchain information.
        var environment = environment
        if configurationDelegate?.loadMetalToolchain == true {
            if (try? ProcessInfo.processInfo.hostOperatingSystem()) == .macOS, !(environment.contains("EXTERNAL_TOOLCHAINS_DIR") && environment.contains("TOOLCHAINS")) {
                let activeDeveloperPath: Path
                if let developerPath {
                    activeDeveloperPath = developerPath.path
                } else {
                    activeDeveloperPath = try await Xcode.getActiveDeveloperDirectoryPath()
                }
                let defaultToolchainPath = activeDeveloperPath.join("Toolchains/XcodeDefault.xctoolchain")

                if !localFS.exists(defaultToolchainPath.join("usr/metal/current")) {
                    struct MetalToolchainInfo: Decodable {
                        let buildVersion: String
                        let status: String
                        let toolchainIdentifier: String
                        let toolchainSearchPath: String
                    }

                    let result = try await Process.getOutput(url: URL(fileURLWithPath: activeDeveloperPath.join("usr/bin/xcodebuild").str), arguments: ["-showComponent", "metalToolchain", "-json"], environment: ["DEVELOPER_DIR": activeDeveloperPath.str])
                    if result.exitStatus != .exit(0) {
                        throw StubError.error("xcodebuild failed: \(String(data: result.stdout, encoding: .utf8) ?? "")\n\(String(data: result.stderr, encoding: .utf8) ?? "")")
                    }

                    let metalToolchainInfo = try JSONDecoder().decode(MetalToolchainInfo.self, from: result.stdout)
                    environment.addContents(of: [
                        "TOOLCHAINS": "\(metalToolchainInfo.toolchainIdentifier) $(inherited)",
                        "EXTERNAL_TOOLCHAINS_DIR": metalToolchainInfo.toolchainSearchPath,
                    ])
                }
            }
        }

        // When this code is being loaded directly via unit tests *and* we detect the products directory we are running in is for Xcode, then we should run using inferior search paths.
        let inferiorProductsPath: Path? = self.inferiorProductsPath()

        // Compute additional content paths.
        var additionalContentPaths = [Path]()
        if let simulatedInferiorProductsPath {
            additionalContentPaths.append(simulatedInferiorProductsPath)
        }

        let pluginManager = await MutablePluginManager(skipLoadingPluginIdentifiers: skipLoadingPluginsNamed)

        @PluginExtensionSystemActor func extraPluginRegistration(pluginManager: MutablePluginManager, pluginPaths: [Path]) {
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

            let staticPluginInitializers: [String: PluginInitializationFunction]

            // This MUST be a compile-time check because the module dependencies on the plugins are conditional.
            // Minimize the amount of code that is conditionally compiled to avoid breaking the build during refactoring.
            #if USE_STATIC_PLUGIN_INITIALIZATION
            staticPluginInitializers = [
                "Android": SWBAndroidPlatform.initializePlugin,
                "Apple": SWBApplePlatform.initializePlugin,
                "GenericUnix": SWBGenericUnixPlatform.initializePlugin,
                "QNX": SWBQNXPlatform.initializePlugin,
                "Universal": SWBUniversalPlatform.initializePlugin,
                "WebAssembly": SWBWebAssemblyPlatform.initializePlugin,
                "Windows": SWBWindowsPlatform.initializePlugin,
            ]
            #else
            staticPluginInitializers = [:]
            #endif

            if useStaticPluginInitialization {
                for (infix, initializer) in staticPluginInitializers where !skipLoadingPluginsNamed.contains("com.apple.dt.SWB\(infix)PlatformPlugin") {
                    initializer(pluginManager)
                }
            }

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

/// Individual classes may pass an instance of this protocol to `CoreBasedTests.makeCore()` to configure which special elements of the testing core they need.  `Core.createInitializedTestingCore()` (above) will configure the core based on what's passed here.
///
/// This allows tests which don't care about those elements to not fail because of errors trying to load them.
package struct TestingCoreConfigurationDelegate: Sendable {
    /// Only tests which are exercising Metal should need to load the Metal toolchain, so only those tests will fail if loading the toolchain fails.
    package let loadMetalToolchain: Bool

    package init(loadMetalToolchain: Bool = false) {
        self.loadMetalToolchain = loadMetalToolchain
    }
}
