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

public import Foundation

import SWBLibc
public import SWBUtil
public import SWBCAS
public import SWBServiceCore
import SWBMacro

/// Delegate protocol used to parameterize creation of a `Core` object and to report diagnostics.
public protocol CoreDelegate: DiagnosticProducingDelegate, Sendable {
    /// Whether to enable parsing optimization remarks in Swift Build directly.
    /// This is true for testing cores or if the corresponding `SWBFeatureFlag` is enabled.
    var enableOptimizationRemarksParsing: Bool { get }

    var hasErrors: Bool { get }
}

public extension CoreDelegate {
    var enableOptimizationRemarksParsing: Bool { return SWBFeatureFlag.enableOptimizationRemarksParsing.value }
}

/// This object wraps access to all of the core objects which are loaded as part of Xcode, such as the build system specifications.
///
/// Clients are expected to generally expected to only allocate and use one Core instance, obtained via \see getInitializedCore().
//
// FIXME: This class is a little split-brained. For performance testings and infrastructure layering purposes, we want to lazily initialize the properties like the plugin managers and the spec loading. However, for diagnostic and external API perspectives, we really just want clients to get one Core that fails if there are any loading errors. For now, we do this by exporting the getInitializedCore() API but leaving the possibility of manually constructing a Core for performance tests. We could clean this up if we moved the various initialization logic bits (i.e., how we set up the SpecRegistry paths) out into different classes.
public final class Core: Sendable {
    /// Get a configured instance of the core.
    ///
    /// - returns: An initialized Core instance on which all discovery and loading will have been completed. If there are errors during that process, they will be logged to `stderr` and no instance will be returned. Otherwise, the initialized object is returned.
    public static func getInitializedCore(_ delegate: any CoreDelegate, pluginManager: PluginManager, developerPath: DeveloperPath? = nil, resourceSearchPaths: [Path] = [], inferiorProductsPath: Path? = nil, extraPluginRegistration: @PluginExtensionSystemActor (_ pluginPaths: [Path]) -> Void = { _ in }, additionalContentPaths: [Path] = [], environment: [String:String] = [:], buildServiceModTime: Date, connectionMode: ServiceHostConnectionMode) async -> Core? {
        // Enable macro expression interning during loading.
        return await MacroNamespace.withExpressionInterningEnabled {
            let hostOperatingSystem: OperatingSystem
            do {
                hostOperatingSystem = try ProcessInfo.processInfo.hostOperatingSystem()
            } catch {
                delegate.error("Could not determine host operating system: \(error)")
                return nil
            }

            #if USE_STATIC_PLUGIN_INITIALIZATION
            // In a package context, plugins are statically linked into the build system.
            // Load specs from service plugins if requested since we don't have a Service in certain tests
            // Here we don't have access to `core.pluginPaths` like we do in the call below,
            // but it doesn't matter because it will return an empty array when USE_STATIC_PLUGIN_INITIALIZATION is defined.
            await extraPluginRegistration([])
            #endif

            let resolvedDeveloperPath: DeveloperPath
            do {
                if let resolved = developerPath {
                    resolvedDeveloperPath = resolved
                } else {
                    let values = try await Set(pluginManager.extensions(of: DeveloperDirectoryExtensionPoint.self).asyncMap { try await $0.fallbackDeveloperDirectory(hostOperatingSystem: hostOperatingSystem) }).compactMap { $0 }
                    switch values.count {
                    case 0:
                        delegate.error("Could not determine path to developer directory because no extensions provided a fallback value")
                        return nil
                    case 1:
                        let path = values[0]
                        if path.str.hasSuffix(".app/Contents/Developer") {
                            resolvedDeveloperPath = .xcode(path)
                        } else {
                            resolvedDeveloperPath = .fallback(values[0])
                        }
                    default:
                        delegate.error("Could not determine path to developer directory because multiple extensions provided conflicting fallback values: \(values.sorted().map { $0.str }.joined(separator: ", "))")
                        return nil
                    }
                }
            } catch {
                delegate.error("Could not determine path to developer directory: \(error)")
                return nil
            }

            let core: Core
            do {
                core = try await Core(delegate: delegate, hostOperatingSystem: hostOperatingSystem, pluginManager: pluginManager, developerPath: resolvedDeveloperPath, resourceSearchPaths: resourceSearchPaths, inferiorProductsPath: inferiorProductsPath, additionalContentPaths: additionalContentPaths, environment: environment, buildServiceModTime: buildServiceModTime, connectionMode: connectionMode)
            } catch {
                delegate.error("\(error)")
                return nil
            }

            if UserDefaults.enablePluginManagerLogging {
                let plugins = await core.pluginManager.pluginsByIdentifier
                delegate.emit(Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Loaded \(plugins.count) plugins"), childDiagnostics: plugins.sorted(byKey: <).map { (identifier, plugin) in
                    Diagnostic(behavior: .note, location: .path(plugin.path), data: DiagnosticData("Loaded plugin: \(identifier) from \(plugin.path.str)"))
                }))
            }

            for diagnostic in await core.pluginManager.loadingDiagnostics {
                // Only emit "severe" diagnostics (warning, error) from the plugin manager if the logging dwrite isn't set.
                if UserDefaults.enablePluginManagerLogging || [.error, .warning].contains(diagnostic.behavior) {
                    delegate.emit(diagnostic)
                }
            }

            #if !USE_STATIC_PLUGIN_INITIALIZATION
            // In a package context, plugins are statically linked into the build system.
            // Load specs from service plugins if requested since we don't have a Service in certain tests
            await extraPluginRegistration(core.pluginPaths)
            #endif

            await core.initializeSpecRegistry()

            await core.initializePlatformRegistry()

            await core.initializeToolchainRegistry()

            // Force loading SDKs.
            let sdkRegistry = core.sdkRegistry

            struct Context: SDKRegistryExtensionAdditionalSDKsContext {
                var hostOperatingSystem: OperatingSystem
                var platformRegistry: PlatformRegistry
                var fs: any FSProxy
            }

            for `extension` in await pluginManager.extensions(of: SDKRegistryExtensionPoint.self) {
                do {
                    try await sdkRegistry.registerSDKs(extension: `extension`, context: Context(hostOperatingSystem: hostOperatingSystem, platformRegistry: core.platformRegistry, fs: localFS))
                } catch {
                    delegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("\(error)")))
                }
            }

            // Force loading all specs.
            core.loadAllSpecs()

            // Force loading the SDK extended info, including late binding of build settings (since we want to have all definitions from specs registered before we bind these settings).
            core.sdkRegistry.loadExtendedInfo(core.specRegistry.internalMacroNamespace)

            // Force loading the platform extended info, including late binding of build settings.
            core.platformRegistry.loadExtendedInfo(core.specRegistry.internalMacroNamespace)

            // FIXME: <rdar://problem/36364112> We should also perform late binding of the toolchains' settings here.  Presently this is done when a Settings object which uses a toolchain is constructed.

            // Force loading the CoreSettings (which can emit errors about missing required specs).
            let _ = core.coreSettings

            // If there were any loading errors, discard the core.
            if delegate.hasErrors {
                return nil
            }

            return core
        }
    }

    /// The configured delegate.
    @_spi(Testing) public let delegate: any CoreDelegate

    let _registryDelegate: UnsafeDelayedInitializationSendableWrapper<CoreRegistryDelegate> = .init()
    /// The self-referencing delegate to convey information about the core to registry subsystems.
    var registryDelegate: CoreRegistryDelegate {
        _registryDelegate.value
    }

    /// The host operating system.
    public let hostOperatingSystem: OperatingSystem

    public let pluginManager: PluginManager

    public enum DeveloperPath: Sendable, Hashable {
        // A path to an Xcode install's "/Contents/Developer" directory
        case xcode(Path)

        // A path to the root of a Swift toolchain, optionally paired with the developer path of an installed Xcode
        case swiftToolchain(Path, xcodeDeveloperPath: Path?)

        // A fallback resolved path.
        case fallback(Path)

        public var path: Path {
            switch self {
            case .xcode(let path), .swiftToolchain(let path, xcodeDeveloperPath: _), .fallback(let path):
                return path
            }
        }
    }

    /// The path to the "Developer" directory.
    public let developerPath: DeveloperPath

    /// Additional search paths to be used when looking up resource bundles.
    public let resourceSearchPaths: [Path]

    /// The path to the inferior Xcode build directory, if used.
    public let inferiorProductsPath: Path?

    /// Additional paths in which to locate content.
    ///
    /// This is used for testing.  Presently only specifications are searched for in these paths.
    ///
    /// If necessary this would be an array of an enum which declares which kind of content should be looked for in the given path.
    public let additionalContentPaths: [Path]

    /// Additional override environment variables
    public let environment: [String:String]

    /// The Xcode application version, as a string.
    public let xcodeVersionString: String

    /// The Xcode application version.
    public let xcodeVersion: Version

    /// The Xcode product build version, as a string.
    public let xcodeProductBuildVersionString: String

    /// The Xcode product build version.
    public let xcodeProductBuildVersion: ProductBuildVersion

    /// The modification date of the SWBBuildService.bundle and its embedded frameworks.
    public let buildServiceModTime: Date

    public let connectionMode: ServiceHostConnectionMode

    @_spi(Testing) public init(delegate: any CoreDelegate, hostOperatingSystem: OperatingSystem, pluginManager: PluginManager, developerPath: DeveloperPath, resourceSearchPaths: [Path], inferiorProductsPath: Path?, additionalContentPaths: [Path], environment: [String:String], buildServiceModTime: Date, connectionMode: ServiceHostConnectionMode) async throws {
        self.delegate = delegate
        self.hostOperatingSystem = hostOperatingSystem
        self.pluginManager = pluginManager
        self.developerPath = developerPath
        self.resourceSearchPaths = resourceSearchPaths
        self.inferiorProductsPath = inferiorProductsPath
        self.additionalContentPaths = additionalContentPaths
        self.buildServiceModTime = buildServiceModTime
        self.connectionMode = connectionMode
        self.environment = environment

        switch developerPath {
        case .xcode(let path):
            let versionPath = path.dirname.join("version.plist")

            // Load the containing app (Xcode or Playgrounds) version information, if available.
            //
            // We make this optional so tests do not need to provide it.
            if let info = try XcodeVersionInfo.versionInfo(versionPath: versionPath) {
                self.xcodeVersion = info.shortVersion

                // If the ProductBuildVersion key is missing, we use "UNKNOWN" as the value.
                self.xcodeProductBuildVersion = info.productBuildVersion ?? ProductBuildVersion(major: 0, train: "A", build: 0, buildSuffix: "")
                self.xcodeProductBuildVersionString = info.productBuildVersion?.description ?? "UNKNOWN"
            } else {
                // Set an arbitrary version for testing purposes.
                self.xcodeVersion = Version(99, 99, 99)
                self.xcodeProductBuildVersion = ProductBuildVersion(major: 99, train: "T", build: 999)
                self.xcodeProductBuildVersionString = xcodeProductBuildVersion.description
            }
        case .swiftToolchain, .fallback:
            // FIXME: Eliminate this requirment for Swift toolchains
            self.xcodeVersion = Version(99, 99, 99)
            self.xcodeProductBuildVersion = ProductBuildVersion(major: 99, train: "T", build: 999)
            self.xcodeProductBuildVersionString = xcodeProductBuildVersion.description
        }

        self.xcodeVersionString = self.xcodeVersion.description

        self.stopAfterOpeningLibClang = UserDefaults.stopAfterOpeningLibClang

        self.toolchainPaths = {
            var toolchainPaths = [(Path, strict: Bool)]()

            switch developerPath {
            case .xcode(let path):
                toolchainPaths.append((path.join("Toolchains"), strict: path.str.hasSuffix(".app/Contents/Developer")))
            case .swiftToolchain(let path, xcodeDeveloperPath: let xcodeDeveloperPath):
                toolchainPaths.append((path, strict: true))
                if let xcodeDeveloperPath {
                    toolchainPaths.append((xcodeDeveloperPath.join("Toolchains"), strict: xcodeDeveloperPath.str.hasSuffix(".app/Contents/Developer")))
                }
            case .fallback(let path):
                toolchainPaths.append((path.join("Toolchains"), strict: false))
            }

            // FIXME: We should support building the toolchain locally (for `inferiorProductsPath`).

            toolchainPaths.append((Path("/Library/Developer/Toolchains"), strict: false))

            if let homeString = getEnvironmentVariable("HOME")?.nilIfEmpty {
                let userToolchainsPath = Path(homeString).join("Library/Developer/Toolchains")
                toolchainPaths.append((userToolchainsPath, strict: false))
            }

            if let externalToolchainDirs = getEnvironmentVariable("EXTERNAL_TOOLCHAINS_DIR") ?? environment["EXTERNAL_TOOLCHAINS_DIR"] {
                let envPaths = externalToolchainDirs.split(separator: Path.pathEnvironmentSeparator)
                for envPath in envPaths {
                    toolchainPaths.append((Path(envPath), strict: false))
                }
            }

            return toolchainPaths
        }()

        _registryDelegate.initialize(to: CoreRegistryDelegate(core: self))
    }

    /// The shared core settings object.
    @_spi(Testing) public lazy var coreSettings: CoreSettings = {
        return CoreSettings(self)
    }()

    /// The list of plugin search paths.
    @_spi(Testing) public lazy var pluginPaths: [Path] = {
        #if USE_STATIC_PLUGIN_INITIALIZATION
        // In a package context, plugins are statically linked into the build system.
        return []
        #else

        var result = [Path]()

        // If we are inferior, then search the built products directory first.
        //
        // FIXME: This is error prone, as it won't validate that any of these are installed in the expected location.
        // FIXME: If we remove, move or rename something in the built Xcode, then this will still find the old item in the installed Xcode.
        if let inferiorProductsPath = self.inferiorProductsPath {
            result.append(inferiorProductsPath)
        }

        guard let coreFrameworkPath = try? Bundle(for: Self.self).bundleURL.filePath.dirname else {
            return result
        }

        // Search paths relative to SWBCore itself.
        do {
            func appendInferior(_ path: Path) {
                if !developerPath.dirname.isAncestor(of: path) {
                    result.append(path)
                }
            }

            // flat layout, when SWBCore is directly nested under BUILT_PRODUCTS_DIR
            appendInferior(coreFrameworkPath)

            // flat layout, when SWBCore is nested in SWBBuildServiceBundle in SwiftBuild.framework in BUILT_PRODUCTS_DIR
            appendInferior(coreFrameworkPath.join("../../../../../../.."))
        }

        // In the superior or a hierarchical build, look for plugins in the build service bundle relative to SWBCore.framework.
        let pluginPath = coreFrameworkPath.join("../PlugIns")
        result.append(pluginPath)
        for subdirectory in (try? localFS.listdir(pluginPath)) ?? [] {
            let subdirectoryPath = pluginPath.join(subdirectory)
            if localFS.isDirectory(subdirectoryPath) {
                result.append(subdirectoryPath)
            }
        }

        return result.map { $0.normalize() }
        #endif
    }()

    /// The list of SDK search paths.
    @_spi(Testing) public lazy var sdkPaths: [(Path, Platform?)] = {
        return self.platformRegistry.platforms.flatMap { platform in platform.sdkSearchPaths.map { ($0, platform) } }
    }()

    /// The list of toolchain search paths.
    @_spi(Testing) public var toolchainPaths: [(Path, strict: Bool)]

    /// The platform registry.
    let _platformRegistry: UnsafeDelayedInitializationSendableWrapper<PlatformRegistry> = .init()
    public var platformRegistry: PlatformRegistry {
        _platformRegistry.value
    }

    @PluginExtensionSystemActor public var loadedPluginPaths: [Path] {
        pluginManager.pluginsByIdentifier.values.map(\.path)
    }

    /// The SDK registry for Xcode's builtin SDKs. Clients should generally use `WorkspaceContext.sdkRegistry` to include dynamically discovered SDKs.
    public lazy var sdkRegistry: SDKRegistry = {
        return SDKRegistry(delegate: self.registryDelegate, searchPaths: self.sdkPaths, type: .builtin, hostOperatingSystem: hostOperatingSystem)
    }()

    /// The toolchain registry.
    public private(set) var toolchainRegistry: ToolchainRegistry! = nil

    private let libclangRegistry = Registry<Path, (Libclang?, Version?)>()
    private let stopAfterOpeningLibClang: Bool

    public func lookupLibclang(path: Path) -> (libclang: Libclang?, version: Version?) {
        libclangRegistry.getOrInsert(path) {
            let libclang = Libclang(path: path.str)
            libclang?.leak()
            if stopAfterOpeningLibClang {
                Debugger.pause()
            }
            let libclangVersion: Version?
            if let versionString = libclang?.getVersionString(),
               let match = try? #/\(clang-(?<clang>[0-9]+(?:\.[0-9]+){0,})\)/#.firstMatch(in: versionString) {
                libclangVersion = try? Version(String(match.clang))
            } else {
                libclangVersion = nil
            }
            return (libclang, libclangVersion)
        }
    }

    private let casPlugin: LockedValue<ToolchainCASPlugin?> = .init(nil)
    public func lookupCASPlugin() -> ToolchainCASPlugin? {
        return casPlugin.withLock { casPlugin in
            if casPlugin == nil {
                switch developerPath {
                case .xcode(let path):
                    let pluginPath = path.join("usr/lib/libToolchainCASPlugin.dylib")
                    let plugin = try? ToolchainCASPlugin(dylib: pluginPath)
                    casPlugin = plugin
                case .swiftToolchain, .fallback:
                    // Unimplemented
                    break
                }
            }
            return casPlugin
        }
    }

    /// The specification registry.
    public var specRegistry: SpecRegistry {
        guard let specRegistry = _specRegistry else {
            // FIXME: We should structure the initialization path better and remove reliance on `lazy var` so that this can be handled more cleanly.
            preconditionFailure("Spec registry not initialized.")
        }
        return specRegistry
    }

    private var _specRegistry: SpecRegistry?

    @_spi(Testing) public func initializePlatformRegistry() async {
        var searchPaths: [Path]
        let fs = localFS
        if let onlySearchAdditionalPlatformPaths = getEnvironmentVariable("XCODE_ONLY_EXTRA_PLATFORM_FOLDERS"), onlySearchAdditionalPlatformPaths.boolValue {
            searchPaths = []
        } else {
            switch developerPath {
            case .xcode(let path):
                let platformsDir = path.join("Platforms")
                searchPaths = [platformsDir]
            case .swiftToolchain(_, let xcodeDeveloperDirectoryPath):
                if let xcodeDeveloperDirectoryPath {
                    searchPaths = [xcodeDeveloperDirectoryPath.join("Platforms")]
                } else {
                    searchPaths = []
                }
            case .fallback:
                searchPaths = []
            }
        }
        if let additionalPlatformSearchPaths = getEnvironmentVariable("XCODE_EXTRA_PLATFORM_FOLDERS") {
            for searchPath in additionalPlatformSearchPaths.split(separator: Path.pathEnvironmentSeparator) {
                searchPaths.append(Path(searchPath))
            }
        }
        searchPaths += UserDefaults.additionalPlatformSearchPaths
        _platformRegistry.initialize(to: await PlatformRegistry(delegate: self.registryDelegate, searchPaths: searchPaths, hostOperatingSystem: hostOperatingSystem, fs: fs))
    }


    private func initializeToolchainRegistry() async {
        self.toolchainRegistry = await ToolchainRegistry(delegate: self.registryDelegate, searchPaths: self.toolchainPaths, fs: localFS, hostOperatingSystem: hostOperatingSystem)
    }

    @_spi(Testing) public func initializeSpecRegistry() async {
        precondition(_specRegistry == nil)

        var domainInclusions: [String: [String]] = [:]

        // Compute the complete list of search paths (and default domains).
        var searchPaths = additionalContentPaths.map { ($0, "") }

        // Find all plugin provided specs.
        for ext in await self.pluginManager.extensions(of: SpecificationsExtensionPoint.self) {
            if let bundle = ext.specificationFiles(resourceSearchPaths: resourceSearchPaths) {
                for url in bundle.urls(forResourcesWithExtension: "xcspec", subdirectory: nil) ?? [] {
                    do {
                        try searchPaths.append(((url as URL).filePath, ""))
                    } catch {
                        self.registryDelegate.error(error)
                    }
                }
            }

            // Get the information on "domain composition".
            for (domain, includes) in ext.specificationDomains() {
                if let existingIncludes = domainInclusions[domain], existingIncludes != includes {
                    self.registryDelegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Conflicting definitions for spec domain composition in domain: \(domain): \(existingIncludes) vs \(includes)")))
                }
                domainInclusions[domain] = includes
            }
        }

        _specRegistry = await SpecRegistry(self.pluginManager, self.registryDelegate, searchPaths, domainInclusions, [:])
    }

    /// Force all specs to be loaded.
    @_spi(Testing) public func loadAllSpecs() {
        // Load all platform domain specs first, as they provide the canonical definitions of build settings.
        for domain in specRegistry.proxiesByDomain.keys {
            for proxy in specRegistry.findProxiesInSubregistry(BuildSystemSpec.self, domain: domain) {
                let _ = proxy.load(specRegistry)
            }
        }

        // Load all command line tool specs next, they may also define a build setting.
        for domain in specRegistry.proxiesByDomain.keys {
            for proxy in specRegistry.findProxiesInSubregistry(CommandLineToolSpec.self, domain: domain) {
                let _ = proxy.load(specRegistry)
            }
        }

        // Load all proxies.
        for domainRegistry in specRegistry.proxiesByDomain.values {
            for proxy in domainRegistry.proxiesByIdentifier.values {
                let _ = proxy.load(specRegistry)
            }
        }

        // Register domains for all installed platforms.  This handles the case where there's a platform which is installed but which doesn't have any specs of its own (all its specs are inherited from another platform), the registry won't try to create a domain for it after it's been frozen.
        for platform in platformRegistry.platforms {
            _ = specRegistry.lookupProxy("", domain: platform.name)
        }

        // Freeze the specification registry.
        specRegistry.freeze()
    }

    /// Dump information on the registered platforms.
    public func getPlatformsDump() -> String {
        var result = ""
        for platform in platformRegistry.platforms {
            result += "\(platform)\n"
        }
        return result
    }

    /// Dump information on the registered SDKs.
    public func getSDKsDump() -> String {
        var result = ""
        for sdk in sdkRegistry.allSDKs.sorted(by: \.canonicalName) {
            result += "\(sdk)\n"
        }
        return result
    }

    /// Dump information on the registered spec proxies.
    public func getSpecsDump(conformingTo: String?) -> String {
        var result = ""
        for (domain,domainRegistry) in specRegistry.proxiesByDomain.sorted(byKey: <) {
            let domainName = domain.isEmpty ? "(default)" : domain
            result += "-- Domain: \(domainName) --\n"

            // Print the specs grouped by type.
            var byType: [String: [SpecProxy]] = [:]
            for spec in domainRegistry.proxiesByIdentifier.values {
                byType[spec.type.typeName, default: []].append(spec)
            }

            for (typeName, specs) in byType.sorted(byKey: <) {
                result += "  Type: \(typeName)\n"
                for spec in specs.sorted(by: \.identifier) {
                    let show = conformingTo.map { specRegistry.getSpec(spec.identifier, domain: spec.domain)?.conformsTo(identifier: $0) == true } ?? true
                    if show {
                        result += "    Name: \(spec.identifier) -- \(spec.path)\n"
                    }
                }
                result += "\n"
            }
        }
        return result
    }

    /// Dump information on the registered build settings.
    public func getBuildSettingsDescriptionDump() throws -> String {
        struct SpecDump: Codable {
            struct BuildOptionDump: Codable {
                let name: String
                let displayName: String?
                let categoryName: String?
                let description: String?
            }

            let spec: String
            let path: String?
            let options: [BuildOptionDump]
        }

        let specs: [SpecDump] = specRegistry.domains.flatMap { domain -> [SpecDump] in
            let allSpecs = specRegistry.findSpecs(BuildSettingsSpec.self, domain: domain, includeInherited: false)
                + specRegistry.findSpecs(BuildSystemSpec.self, domain: domain, includeInherited: false)
                + specRegistry.findSpecs(CommandLineToolSpec.self, domain: domain, includeInherited: false)
            return allSpecs.map { spec in
                SpecDump(
                    spec: spec.identifier,
                    path: spec.proxyPath.str,
                    options: spec.flattenedBuildOptions.values.sorted(by: \.name).map { option in
                        .init(name: option.name, displayName: option.localizedName != option.name ? option.localizedName : nil, categoryName: option.localizedCategoryName, description: option.localizedDescription)
                })
            }
        }

        let encoder = JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return try String(decoding: encoder.encode(specs), as: UTF8.self)
    }

    /// Dump information on the registered toolchains.
    public func getToolchainsDump() async -> String {
        var result = ""
        for (_,toolchain) in toolchainRegistry.toolchainsByIdentifier.sorted(byKey: <) {
            result += "\(toolchain)\n"
        }
        return result
    }

    public func productTypeSupportsMacCatalyst(productTypeIdentifier: String) throws -> Bool {
        do {
            let productTypeSpec = try specRegistry.getSpec(productTypeIdentifier, domain: "macosx") as ProductTypeSpec
            return productTypeSupportsPlatform(productType: productTypeSpec, platformName: "macosx")
        } catch SpecLoadingError.notFound {
            return false
        }
    }
}

extension PlatformInfoLookup {
    public func productTypeSupportsPlatform(productType productTypeSpec: ProductTypeSpec, platform: Platform?) -> Bool {
        productTypeSupportsPlatform(productType: productTypeSpec, platformName: platform?.name ?? "")
    }

    fileprivate func productTypeSupportsPlatform(productType productTypeSpec: ProductTypeSpec, platformName: String) -> Bool {
        if productTypeSpec.supportedPlatforms.isEmpty {
            return true
        }
        return productTypeSpec.supportedPlatforms.contains(platformName)
    }
}

extension Core: PlatformInfoLookup {
    public func lookupPlatformInfo(platform buildPlatform: BuildVersion.Platform) -> (any PlatformInfoProvider)? {
        func sdkMatchesBuildPlatform(_ sdk: SDK) -> Bool {
            sdk.isBaseSDK && !sdk.variants.isEmpty && sdk.variants.values.contains(where: { sdk.targetBuildVersionPlatform(sdkVariant: $0) == buildPlatform }) && sdk.cohortPlatforms.isEmpty
        }

        // Find the platform name of all SDKs containing a variant whose platform ID matches our platform.
        let platformNames: Set<String> = {
            var platformNames = Set<String>()
            for platform in platformRegistry.platforms {
                for sdk in platform.sdks where sdkMatchesBuildPlatform(sdk) {
                    platformNames.insert(platform.name)
                }
            }
            return platformNames
        }()

        // If we found a match, look up the SDK -- we'll deterministically get the latest version of that SDK,
        // and it should have only one variant whose platform ID matches our platform.
        if let platformName = platformNames.only, let platform = platformRegistry.lookup(name: platformName) {
            let potentialSDKNames = [platform.sdkCanonicalName].compactMap { $0 } + sdkRegistry.supportedSDKCanonicalNameSuffixes().compactMap {
                if let sdkBaseName = platform.sdkCanonicalName {
                    return "\(sdkBaseName).\($0)"
                } else {
                    return nil
                }
            }
            if let sdk = potentialSDKNames.compactMap({ try? sdkRegistry.lookup($0, activeRunDestination: nil) }).first {
                return sdk.variants.values.filter { sdk.targetBuildVersionPlatform(sdkVariant: $0) == buildPlatform }.only
            }
        }

        return nil
    }
}

extension Core {
    /// Compute the inferior products path to use when initializing a `Core`, based on whether the environment variable `__XCODE_BUILT_PRODUCTS_DIR_PATHS` is set.
    public static func inferiorProductsPath() -> Path? {
        var inferiorProductsPath: Path? = nil
        if let builtProductsDirPaths = getEnvironmentVariable("__XCODE_BUILT_PRODUCTS_DIR_PATHS") {
            // FIXME: We currently assume the first path is the actual products, and ignore all others (for other platforms). This is bogus.
            let productsPath = Path(builtProductsDirPaths.split(":").0)
            // NASTY HACK: If the productsPath is the CodeCoverage directory, then we try to find the 'real' products dir, since Xcode itself doesn't build into that folder.  This scenario happens when running Swift Build unit tests on the desktop.
            let productsPathParts = productsPath.str.split(separator: "/").map(String.init)
            for subpathElementsToRemove in [["Intermediates.noindex", "CodeCoverage"]] {
                // Look for subpath elements to remove, and if they're there, create a new path without them and see if it qualifies as a built products dir.
                if let range = productsPathParts.firstRange(of: subpathElementsToRemove) {
                    var productsPathParts = productsPathParts
                    productsPathParts.removeSubrange(range)
                    let revisedProductsPath = Path((productsPath.isAbsolute ? Path.pathSeparatorString : "") + productsPathParts.joined(separator: Path.pathSeparatorString))
                    if localFS.exists(revisedProductsPath.join("DevToolsCore.framework")) {
                        inferiorProductsPath = revisedProductsPath
                    }
                }
            }
            // If we haven't yet found a built products dir in a modified location, then just check the one we got from __XCODE_BUILT_PRODUCTS_DIR_PATHS.
            if inferiorProductsPath == nil {
                if localFS.exists(productsPath.join("DevToolsCore.framework")) {
                    inferiorProductsPath = productsPath
                }
            }
        }
        return inferiorProductsPath
    }
}

extension Core {
    func warning(_ path: Path, _ message: String) { return delegate.warning(path, message) }
    func error(_ path: Path, _ message: String) { return delegate.error(path, message) }
}

/// The delegate used to convey information to registry subsystems about the core, including a channel for those registries to report diagnostics.  This struct is created by the core itself and refers to the core.  It exists as a struct separate from core to avoid creating an ownership cycle between the core and the registry objects.
///
/// Although primarily used by registries during the loading of the core, this delegate is persisted since registries may need to report additional information after loading.  For example, new toolchains may be downloaded.
struct CoreRegistryDelegate : PlatformRegistryDelegate, SDKRegistryDelegate, SpecRegistryDelegate, ToolchainRegistryDelegate, SpecRegistryProvider {
    unowned let core: Core

    var diagnosticsEngine: DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return core.delegate.diagnosticsEngine
    }

    var specRegistry: SpecRegistry {
        return core.specRegistry
    }

    var platformRegistry: PlatformRegistry? {
        return core.platformRegistry
    }

    var namespace: MacroNamespace {
        return specRegistry.internalMacroNamespace
    }

    var pluginManager: PluginManager {
        core.pluginManager
    }

    var developerPath: Core.DeveloperPath {
        core.developerPath
    }
}
