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

public import SWBUtil
import struct SWBProtocol.RunDestinationInfo
import SWBMacro

public protocol TargetGraph: Sendable {
    var workspaceContext: WorkspaceContext { get }

    var allTargets: OrderedSet<ConfiguredTarget> { get }

    func dependencies(of target: ConfiguredTarget) -> [ConfiguredTarget]
}

/// The delegate used when constructing a target graph.
public protocol TargetDependencyResolverDelegate: AnyObject, TargetDiagnosticProducingDelegate {
    /// Emit a diagnostic for target dependency resolution.
    func emit(_ diagnostic: Diagnostic)

    /// Called to report a status message on the resolver progress.
    func updateProgress(statusMessage: String, showInLog: Bool)
}

/// A structure of properties which should be superimposed, that is, imposed on all compatible versions of a target in the build graph.  Applying them will coalesce targets in the dependency graph which are otherwise identical except for the presence of these properties.
struct SuperimposedProperties: Hashable, CustomStringConvertible {
    let mergeableLibrary: Bool

    var description: String {
        return "mergeableLibrary: \(mergeableLibrary)"
    }

    /// Returns the overriding build settings dictionary for these properties as appropriate for the given `ConfiguredTarget`.
    func overrides(_ configuredTarget: ConfiguredTarget, _ settings: Settings) -> [String: String] {
        var overrides = [String: String]()

        if mergeableLibrary, settings.productType?.autoConfigureAsMergeableLibrary(settings.globalScope) ?? false {
            overrides[BuiltinMacros.MERGEABLE_LIBRARY.name] = "YES"
        }

        return overrides
    }

    /// Return an effective set of superimposed properties based on a specific target-dependency pair.
    func effectiveProperties(target configuredTarget: ConfiguredTarget, dependency: ConfiguredTarget, dependencyResolver: DependencyResolver) -> SuperimposedProperties {
        let mergeableLibrary = {
            // If mergeableLibrary is enabled, we only apply it if the dependency is in the target's Link Binary build phase.
            // Note that this doesn't check (for example) linkages defined in OTHER_LDFLAGS, because those are already specifying concrete linkages, and this is used by the automatic merged binary workflow which isn't going to edit those linkages.  Projects which want to specify linkages via OTHER_LDFLAGS for merged binaries will need to use manual configuration.
            if self.mergeableLibrary {
                if let target = configuredTarget.target as? BuildPhaseTarget, let frameworksBuildPhase = target.frameworksBuildPhase {
                    guard let dependencyProductName = (dependency.target as? StandardTarget)?.productReference.name else {
                        return false
                    }
                    let targetSettings = dependencyResolver.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
                    let platformFilter = PlatformFilter.init(targetSettings.globalScope)
                    for buildFile in frameworksBuildPhase.filteredBuildFiles(platformFilter) {
                        guard let buildFilePath = dependencyResolver.resolveBuildFilePath(buildFile, settings: targetSettings, dynamicallyBuildingTargets: dependencyResolver.dynamicallyBuildingTargets) else {
                            continue
                        }
                        let buildFileName = buildFilePath.basename
                        if buildFileName == dependencyProductName {
                            // If this build file in the Link Binary phase matches the name of the dependency's product, then we have a match and we can mark it as a mergeable library.
                            return true
                        }
                    }
                }
            }
            return false
        }()
        return type(of: self).init(mergeableLibrary: mergeableLibrary)
    }
}

/// A set of parameters a target can be specialized upon.
///
/// This structure is both used to convey specialization upon a =`Target` based on context, and to identify whether a `ConfiguredTarget` is compatible with a set of parameters for specialization or some other purpose.
struct SpecializationParameters: Hashable, CustomStringConvertible {

    // FIXME: We should make specialization overrides a separate dictionary in the BuildParameters so we can get rid of this list and simplify BuildParameters.withoutImposedOverrides().
    //
    /// All of the settings that can be potentially imposed through specialization.
    static func potentialImposedSettingNames(core: Core) -> Set<String> {
        var macros: Set<String> = [
            BuiltinMacros.SDKROOT.name,
            BuiltinMacros.SDK_VARIANT.name,
            BuiltinMacros.SUPPORTED_PLATFORMS.name,
            BuiltinMacros.TOOLCHAINS.name,
        ]
        @preconcurrency @PluginExtensionSystemActor func sdkVariantInfoExtensions() -> [any SDKVariantInfoExtensionPoint.ExtensionProtocol] {
            core.pluginManager.extensions(of: SDKVariantInfoExtensionPoint.self)
        }
        for sdkVariantInfoExtension in sdkVariantInfoExtensions() {
            macros.formUnion(sdkVariantInfoExtension.supportsMacCatalystMacroNames)
        }
        return macros
    }


    enum SpecializationSource: CustomStringConvertible {
        case synthesized
        case workspace
        case target(name: String)

        var description: String {
            switch self {
            case .synthesized:
                return "synthesized"
            case .workspace:
                return "workspace"
            case .target(let name):
                return "target '\(name)'"
            }
        }
    }

    /// The entity providing the parameters. Mainly used for diagnosing problems.
    let source: SpecializationSource

    // Properties which are used in isCompatible() to determine whether a ConfiguredTarget can be used with this specialization.

    /// The desired platform.
    let platform: Platform?
    /// The desired SDK variant.
    let sdkVariant: SDKVariant?
    /// The desired supported platforms
    let supportedPlatforms: [String]?
    /// The desired toolchain
    let toolchain: [String]?
    /// Whether or not to use a suffixed SDK.
    let canonicalNameSuffix: String?

    // Other properties.

    /// Properties which should be imposed on all configured instances of a `Target` which are compatible with certain parameters.
    ///
    /// This is used both to convey these properties as part of specialization while walking the dependency graph, and to represent properties which should be so globally imposed on other instances of the `Target` after the graph has been constructed.
    let superimposedProperties: SuperimposedProperties?

    /// Any diagnostics generated in creating the struct. Clients may choose to emit these for better debugging if something goes wrong.
    let diagnostics: [Diagnostic]

    var description: String {
        let sourceString: String
        switch source {
        case .synthesized:
            sourceString = "(synthesized)"
        default:
            sourceString = "imposed by \(source)"
        }

        return "Specialization parameters \(sourceString): platform '\(platform?.identifier ?? "nil")' sdkVariant '\(sdkVariant?.name ?? "nil")' supportedPlatforms: '\(supportedPlatforms?.joined(separator: " ") ?? "nil")' toolchain: '\(toolchain?.joined(separator: " ") ?? "nil")'" +
            // Hide the suffix if it is not present.
        (canonicalNameSuffix != nil ? " suffix: \(String(describing: canonicalNameSuffix))" : "")
    }

    private func effectiveToolchainOverride(originalParameters: BuildParameters, workspaceContext: WorkspaceContext) -> [String]? {
        guard let toolchain else { return nil }

        // Check if the given toolchain is already the one that would be selected by default and do not impose it if that is the case.
        let defaultToolchain = sdkRoot.map { try? workspaceContext.core.sdkRegistry.lookup($0, activeRunDestination: originalParameters.activeRunDestination)?.toolchains }
        if (defaultToolchain??.first ?? ToolchainRegistry.defaultToolchainIdentifier) != toolchain.first {
            return toolchain
        } else {
            return nil
        }
    }

    private var sdkRoot: String? {
        guard let platform else { return nil }
        let sdkRootPublic = platform.sdkCanonicalName

        if let canonicalNameSuffix, !canonicalNameSuffix.isEmpty {
            return sdkRootPublic.map { "\($0).\(canonicalNameSuffix)" }
        } else {
            return sdkRootPublic
        }
    }

    /// Check if a configured target can be used when this specialization is required.
    func isCompatible(with configuredTarget: ConfiguredTarget, settings: Settings, workspaceContext: WorkspaceContext) -> Bool {
        let toolchain = effectiveToolchainOverride(originalParameters: configuredTarget.parameters, workspaceContext: workspaceContext)
        return (platform == nil || platform === settings.platform) &&
            (sdkVariant == nil || sdkVariant?.name == settings.sdkVariant?.name) &&
            (toolchain == nil || toolchain == settings.globalScope.evaluate(BuiltinMacros.EFFECTIVE_TOOLCHAINS_DIRS)) &&
        (canonicalNameSuffix == nil || canonicalNameSuffix?.nilIfEmpty == settings.sdk?.canonicalNameSuffix)
    }

    /// Return an effective set of specialization parameters based on a specific target-dependency pair.
    /// - remark: Right now this is only used for filtering superimposed properties.
    func effectiveParameters(target: ConfiguredTarget, dependency: ConfiguredTarget, dependencyResolver: DependencyResolver) -> SpecializationParameters {
        let effectiveSuperimposedProperties = superimposedProperties?.effectiveProperties(target: target, dependency: dependency, dependencyResolver: dependencyResolver)
        guard effectiveSuperimposedProperties != superimposedProperties else {
            return self
        }
        return type(of: self).init(source: source, platform: platform, sdkVariant: sdkVariant, supportedPlatforms: supportedPlatforms, toolchain: toolchain, canonicalNameSuffix: canonicalNameSuffix, superimposedProperties: effectiveSuperimposedProperties)
    }

    /// Compute a derived set of build parameters with the specialization imposed on them.
    func imposed(on parameters: BuildParameters, workspaceContext: WorkspaceContext) -> BuildParameters {
        var overrides = parameters.overrides
        if let sdkRoot {
            overrides["SDKROOT"] = sdkRoot
        }
        if let sdkVariant {
            overrides["SDK_VARIANT"] = sdkVariant.name
            overrides["SUPPORTS_MACCATALYST"] = sdkVariant.name == MacCatalystInfo.sdkVariantName ? "YES" : "NO"
        }
        if let supportedPlatforms {
            if let platform = parameters.activeRunDestination?.platform {
                // If the specialization matches the platform of the active run destination, we do not need to impose it.
                if !supportedPlatforms.contains(platform) {
                    overrides["SUPPORTED_PLATFORMS"] = supportedPlatforms.joined(separator: " ")
                }
            } else {
                overrides["SUPPORTED_PLATFORMS"] = supportedPlatforms.joined(separator: " ")
            }
        }
        if let toolchain = effectiveToolchainOverride(originalParameters: parameters, workspaceContext: workspaceContext) {
            overrides["TOOLCHAINS"] = toolchain.joined(separator: " ")
        }
        return parameters.mergingOverrides(overrides)
    }

    init(source: SpecializationSource, platform: Platform?, sdkVariant: SDKVariant?, supportedPlatforms: [String]?, toolchain: [String]?, canonicalNameSuffix: String?, superimposedProperties: SuperimposedProperties? = nil, diagnostics: [Diagnostic] = []) {
        self.source = source
        self.platform = platform
        self.sdkVariant = sdkVariant
        self.supportedPlatforms = supportedPlatforms
        self.toolchain = toolchain
        self.canonicalNameSuffix = canonicalNameSuffix
        self.superimposedProperties = superimposedProperties
        self.diagnostics = diagnostics
    }

    fileprivate init(workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, parameters: BuildParameters) {
        var diagnostics = [Diagnostic]()
        let platformName: String?
        // This overrides the default platform used for specialization if `-sdk` has been passed via the commandline.
        let sdkRoot = buildRequestContext.potentialOverride(for: "SDKROOT", buildParameters: parameters)
        let overridingSdk: SDK?
        if let sdkRoot {
            overridingSdk = try? workspaceContext.core.sdkRegistry.lookup(nameOrPath: sdkRoot.value, basePath: Path("/"), activeRunDestination: parameters.activeRunDestination)
        }
        else {
            overridingSdk = nil
        }
        // This seems like an unfortunate way to get from the SDK to its platform.  But SettingsBuilder.computeBoundProperties() creates a scope to evaluate the PLATFORM_NAME defined in the SDK's default properties, so maybe there isn't a clearly better way.
        if let overridingSdk, let overridingPlatform = workspaceContext.core.platformRegistry.platforms.filter({ $0.sdks.contains(where: { $0.canonicalName == overridingSdk.canonicalName }) }).first {
            platformName = overridingPlatform.name
        } else {
            platformName = parameters.activeRunDestination?.platform
        }
        if platformName == nil {
            if let overridingSdk = overridingSdk {
                let platformNames = workspaceContext.core.platformRegistry.platforms.map { $0.name }
                diagnostics.append(Diagnostic(behavior: .warning, location: .unknown, data: DiagnosticData("Could not find a platform name for workspace specialization parameter for overriding SDK '\(overridingSdk.canonicalName)' among loaded platforms '\(platformNames.joined(separator: " "))'s.")))
            }
            else if let sdkRoot = sdkRoot {
                diagnostics.append(Diagnostic(behavior: .warning, location: .unknown, data: DiagnosticData("Could not find an SDK for workspace specialization parameters for overriding SDKROOT '\(sdkRoot.value)' from \(sdkRoot.source).")))
            }
            // Otherwise there was no overriding SDK provided, and there is no active run destination (or somehow there's a destination without a platform).  This is valid, but it's not clear to me what this means for specialization parameters.
        }
        let sdkSuffix: String?
        if let sdk = parameters.activeRunDestination?.sdk {
            if let suffix = try? workspaceContext.sdkRegistry.lookup(sdk, activeRunDestination: parameters.activeRunDestination)?.canonicalNameSuffix, !suffix.isEmpty {
                sdkSuffix = suffix
            } else {
                // Treat a run destination that uses the public SDK as one that does not express an opinion about internal-ness instead of one that *requires* the public SDK.
                sdkSuffix = nil
            }
        } else {
            sdkSuffix = nil
        }
        self.init(workspaceContext: workspaceContext, platformName: platformName, sdkVariantName: parameters.activeRunDestination?.sdkVariant, canonicalNameSuffix: sdkSuffix, diagnostics: diagnostics)
    }

    fileprivate init(workspaceContext: WorkspaceContext, platformName: String?, sdkVariantName: String?, canonicalNameSuffix: String?, diagnostics: [Diagnostic] = []) {
        var diagnostics = diagnostics
        let platform: Platform?
        if let platformName {
            platform = workspaceContext.core.platformRegistry.lookup(name: platformName)
            if platform == nil {
                let platformNames = workspaceContext.core.platformRegistry.platforms.map { $0.name }
                diagnostics.append(Diagnostic(behavior: .warning, location: .unknown, data: DiagnosticData("Could not find a platform named '\(platformName)' from loaded platforms '\(platformNames.joined(separator: " "))' for workspace specialization parameters.")))
            }
        }
        else {
            platform = nil
        }
        let defaultVariant: SDKVariant?
        if let sdkVariantName, let sdkVariant = platform?.sdks.compactMap({ $0.variant(for: sdkVariantName) }).first {
            defaultVariant = sdkVariant
        } else {
            defaultVariant = platform?.defaultSDKVariant
        }
        // If we are using an overriding platform instead of the default, impose supported platforms as well.
        let supportedPlatforms: [String]?
        if let platform, platformName != nil {
            supportedPlatforms = SpecializationParameters.supportedPlatforms(for: platform, registry: workspaceContext.core.platformRegistry)
        } else {
            supportedPlatforms = nil
        }
        self.init(source: .workspace, platform: platform, sdkVariant: defaultVariant, supportedPlatforms: supportedPlatforms, toolchain: nil, canonicalNameSuffix: canonicalNameSuffix, diagnostics: diagnostics)
    }

    static func `default`(workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, parameters: BuildParameters) -> SpecializationParameters {
        return SpecializationParameters(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: parameters)
    }

    static func supportedPlatforms(for platform: Platform?, registry: PlatformRegistry) -> [String] {
        return registry.platforms.filter { $0.familyName == platform?.familyName }.map { $0.name }
    }

    static func == (lhs: SpecializationParameters, rhs: SpecializationParameters) -> Bool {
        return lhs.platform?.identifier == rhs.platform?.identifier && lhs.sdkVariant?.name == rhs.sdkVariant?.name && lhs.supportedPlatforms == rhs.supportedPlatforms && lhs.toolchain == rhs.toolchain && lhs.canonicalNameSuffix == rhs.canonicalNameSuffix && lhs.superimposedProperties == rhs.superimposedProperties
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(platform?.identifier)
        hasher.combine(sdkVariant?.name)
        hasher.combine(supportedPlatforms)
        hasher.combine(toolchain)
        hasher.combine(canonicalNameSuffix)
        hasher.combine(superimposedProperties)
    }

    public func emitDiagnostics(to delegate: any TargetDependencyResolverDelegate) {
        for diag in diagnostics {
            delegate.emit(diag)
        }
    }
}

extension BuildRequestContext {

    /// Look through the various overrides in lookup order for an assignment for the given `key`, and return it (and the level it was found at, for reporting/debugging purposes).  Return `nil` if it's not overridden at any level.
    @_spi(Testing) public func potentialOverride(for macroName: String, buildParameters: BuildParameters) -> (value: String, source: BuildParameters.OverrideLevel)? {
        if let path = buildParameters.environmentConfigOverridesPath {
            let info = getCachedMacroConfigFile(path, context: .environmentConfiguration)
            if let macro = info.table.namespace.lookupMacroDeclaration(macroName), let value = MacroEvaluationScope(table: info.table).evaluateAsString(macro).nilIfEmpty {
                return (value, .environmentConfigOverridesPath(path: path, table: info.table))
            }
        }
        if let path = buildParameters.commandLineConfigOverridesPath {
            let info = getCachedMacroConfigFile(path, context: .commandLineConfiguration)
            if let macro = info.table.namespace.lookupMacroDeclaration(macroName), let value = MacroEvaluationScope(table: info.table).evaluateAsString(macro).nilIfEmpty {
                return (value, .commandLineConfigOverridesPath(path: path, table: info.table))
            }
        }

        let overrideSources: [BuildParameters.OverrideLevel] = [
            .environmentConfigOverrides(dict: buildParameters.environmentConfigOverrides),
            .commandLineConfigOverrides(dict: buildParameters.commandLineConfigOverrides),
            .commandLineOverrides(dict: buildParameters.commandLineOverrides),
            .buildParametersOverrides(dict: buildParameters.overrides),
        ].compactMap({ $0 })
        for overrideSource in overrideSources {
            switch overrideSource {
            case .environmentConfigOverrides(dict: let dict),
                 .commandLineConfigOverrides(dict: let dict),
                 .commandLineOverrides(dict: let dict),
                 .buildParametersOverrides(dict: let dict):
                if let value = dict[macroName] {
                    return (value, overrideSource)
                }
            case .environmentConfigOverridesPath,
                 .commandLineConfigOverridesPath:
                // These cases were handled before this loop.
                continue
            }
        }
        return nil
    }
}

extension DependencyResolver {
    nonisolated func specializationParameters(_ configuredTarget: ConfiguredTarget, workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext) -> SpecializationParameters {
        SpecializationParameters(configuredTarget, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, makeAggregateTargetsTransparentForSpecialization: makeAggregateTargetsTransparentForSpecialization)
    }
}

extension SpecializationParameters {
    init(_ configuredTarget: ConfiguredTarget, workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, makeAggregateTargetsTransparentForSpecialization: Bool) {
        if configuredTarget.target.type == .aggregate && makeAggregateTargetsTransparentForSpecialization {
            self.init(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: buildRequest.parameters)
        } else {
            let configuredTargetSettings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)

            let toolchainOverrideFromParameters: Toolchain?
            if let toolchainOverride = buildRequestContext.potentialOverride(for: "TOOLCHAINS", buildParameters: buildRequest.parameters) {
                toolchainOverrideFromParameters = workspaceContext.core.toolchainRegistry.lookup(toolchainOverride.value)
            } else {
                toolchainOverrideFromParameters = nil
            }

            let effectiveToolchains = configuredTargetSettings.toolchains
            let needsToSpecializeToolchain: Bool
            if let toolchainOverride = buildRequest.parameters.toolchainOverride {
                // If the effective toolchain is equal to the override, we don't need to specialize it.
                needsToSpecializeToolchain = effectiveToolchains.first != workspaceContext.core.toolchainRegistry.lookup(toolchainOverride)
                // `xcodebuild -toolchain` does not affect `toolchainOverride`, so we need to check this as well.
            } else if let toolchainOverride = toolchainOverrideFromParameters {
                // If the effective toolchain is equal to the override, we don't need to specialize it.
                needsToSpecializeToolchain = effectiveToolchains.first != toolchainOverride
            } else {
                // If the effective toolchain is simply the default, we don't need to specialize it, unless we are building for a specialized SDK.
                let defaultToolchain = workspaceContext.core.toolchainRegistry.defaultToolchain
                needsToSpecializeToolchain = configuredTargetSettings.sdk?.canonicalName.nilIfEmpty != nil || effectiveToolchains != [defaultToolchain]
            }
            let toolchain = needsToSpecializeToolchain ? effectiveToolchains : nil

            // Compute superimposed properties.
            let scope = configuredTargetSettings.globalScope
            // If this target has AUTOMATICALLY_MERGE_DEPENDENCIES set, then its direct dependencies are configured as mergeable libraries.
            let mergeableLibrary = scope.evaluate(BuiltinMacros.AUTOMATICALLY_MERGE_DEPENDENCIES)
            let superimposedProperties = SuperimposedProperties(mergeableLibrary: mergeableLibrary)

            let canonicalNameSuffix: String?
            if let sdk = configuredTargetSettings.sdk {
                canonicalNameSuffix = sdk.canonicalNameSuffix ?? ""
            } else {
                canonicalNameSuffix = nil
            }

            self.init(source: .target(name: configuredTarget.target.name), platform: configuredTargetSettings.platform, sdkVariant: configuredTargetSettings.sdkVariant, supportedPlatforms: SpecializationParameters.supportedPlatforms(for: configuredTargetSettings.platform, registry: workspaceContext.core.platformRegistry), toolchain: toolchain?.map { $0.identifier }, canonicalNameSuffix: canonicalNameSuffix, superimposedProperties: superimposedProperties, diagnostics: [])
        }
    }

    var withoutToolchainImposition: SpecializationParameters {
        // FIXME: Strictly speaking we should remove any diagnostics related to the toolchain here.
        return SpecializationParameters(source: self.source, platform: self.platform, sdkVariant: self.sdkVariant, supportedPlatforms: self.supportedPlatforms, toolchain: nil, canonicalNameSuffix: self.canonicalNameSuffix, superimposedProperties: self.superimposedProperties, diagnostics: self.diagnostics)
    }
}

@_spi(Testing) public actor DependencyResolver {
    let buildRequest: BuildRequest
    let buildRequestContext: BuildRequestContext
    let workspaceContext: WorkspaceContext
    nonisolated let delegate: any TargetDependencyResolverDelegate

    /// Target-specific build parameters from the build request, accessible by target.
    let buildParametersByTarget: [Target: BuildParameters]

    /// Configured targets for targets in the workspace context mapped by target.  There may be multiple configured targets for a given target, each one configured with different parameters.
    var configuredTargetsByTarget = [Target: Set<ConfiguredTarget>]()

    func updateConfiguredTargetsByTarget(_ update: (_ configuredTargetsByTarget: inout [Target: Set<ConfiguredTarget>]) -> Void) {
        update(&configuredTargetsByTarget)
    }

    /// Top-level targets get defaults imposed, in case that they are themselves using "auto" anywhere.
    let defaultImposedParameters: SpecializationParameters

    /// Properties we discover that we want to globally impose on all configurations of a target that are compatible with a specialization.
    /// - remark: The use of `SpecializationParameters` is a convenience since it already supports the matching we want.  We can replace it with a custom matcher for just this purpose if we ever find that it's no longer suitable.
    var superimposedSpecializations: [Target: Set<SpecializationParameters>] = [:]

    struct PlatformBuildParameters {
        /// The build parameters for a platform. This includes the discriminator in overrides which is important for having a unique GUID for a target that was configured for multiple platforms.
        let buildParams: BuildParameters

        /// The platform's specialization parameters.
        let specializationParams: SpecializationParameters
    }

    /// Cached build and specialization parameters created for each platform. This is populated only for an index
    /// workspace build.
    let platformBuildParametersForIndex: [PlatformBuildParameters]

    /// Cached parameters for the host platform. This is only populated for an index workspace build.
    let hostParametersForIndex: PlatformBuildParameters?

    /// Targets which should build dynamically according to the build request.
    /// This is only used by Playgrounds and previews.
    let dynamicallyBuildingTargets: Set<Target>

    // TODO: Parameterize this.
    let disableConcurrentDependencyResolution = UserDefaults.disableConcurrentDependencyResolution
    let makeAggregateTargetsTransparentForSpecialization = UserDefaults.makeAggregateTargetsTransparentForSpecialization

    init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: any TargetDependencyResolverDelegate) {
        self.buildRequest = buildRequest
        self.buildRequestContext = buildRequestContext
        self.workspaceContext = workspaceContext
        self.delegate = delegate

        if buildRequest.enableIndexBuildArena {
            // For the index build, multiple build parameters are applied during configuration of a target (to configure for multiple platforms) and the build parameters for each target in the build request is not relevant.
            // Keep this dictionary empty so that `LinkageDependencyResolver` fallbacks to using the build parameters of the configured targets, which are the relevant ones.
            self.buildParametersByTarget = [:]
        } else {
            var buildParametersByTarget = [Target:BuildParameters]()
            for targetInfo in buildRequest.buildTargets {
                buildParametersByTarget[targetInfo.target] = targetInfo.parameters
            }
            self.buildParametersByTarget = buildParametersByTarget
        }

        self.defaultImposedParameters = SpecializationParameters.default(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: buildRequest.parameters)

        if buildRequest.enableIndexBuildArena {
            let hostOS = (try? workspaceContext.core.hostOperatingSystem.xcodePlatformName) ?? "unknown"

            // Create the build parameters for each available platform.
            var platformBuildParameters: [PlatformBuildParameters] = []
            var hostBuildParameters: PlatformBuildParameters? = nil
            for platform in workspaceContext.core.platformRegistry.platforms {
                // Find the corresponding SDK for this platform
                let potentialSDKNames = [platform.sdkCanonicalName].compactMap { $0 } + workspaceContext.core.sdkRegistry.supportedSDKCanonicalNameSuffixes().compactMap {
                    if let sdkBaseName = platform.sdkCanonicalName {
                        return "\(sdkBaseName).\($0)"
                    } else {
                        return nil
                    }
                }
                guard let matchingSDK = potentialSDKNames
                    .compactMap({ try? workspaceContext.core.sdkRegistry.lookup($0, activeRunDestination: nil) }).first else {
                    continue
                }

                let archName: String = platform.determineDefaultArchForIndexArena(preferredArch: workspaceContext.systemInfo?.nativeArchitecture, using: workspaceContext.core) ?? "unknown_arch"

                for sdkVariant in matchingSDK.variants.keys.sorted() {
                    let runDestination = RunDestinationInfo(platform: platform.name, sdk: matchingSDK.canonicalName, sdkVariant: sdkVariant, targetArchitecture: archName, supportedArchitectures: [archName], disableOnlyActiveArch: false, hostTargetedPlatform: nil)
                    let buildParams = buildRequest.parameters.replacing(activeRunDestination: runDestination, activeArchitecture: archName)
                    let specializationParams = SpecializationParameters.default(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: buildParams)
                    platformBuildParameters.append(PlatformBuildParameters(buildParams: buildParams, specializationParams: specializationParams))

                    if runDestination.platform == hostOS && runDestination.sdkVariant == matchingSDK.defaultVariant?.name  {
                        hostBuildParameters = platformBuildParameters.last
                    }
                }
            }

            self.platformBuildParametersForIndex = platformBuildParameters
            self.hostParametersForIndex = hostBuildParameters
        } else {
            self.platformBuildParametersForIndex = []
            self.hostParametersForIndex = nil
        }

        self.dynamicallyBuildingTargets = Set(buildRequest.buildTargets.filter {
            workspaceContext.workspace.project(for: $0.target).isPackage && buildRequestContext.getCachedSettings($0.parameters, target: $0.target).globalScope.evaluate(BuiltinMacros.PACKAGE_BUILD_DYNAMICALLY)
        }.map {
            $0.target
        })
    }

    /// Add the superimposed overrides in `specialization` to be imposed on the target in `configuredTarget` and other instances of that target which match this `configuredTarget`.
    func addSuperimposedProperties(for configuredTarget: ConfiguredTarget, superimposedProperties: SuperimposedProperties?) {
        guard let superimposedProperties else {
            return
        }
        // Create SpecializationParameters for the purpose of matching targets to which these properties should be applied when postprocessing the dependency graph
        let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
        let superimposedSpecialization = SpecializationParameters(source: .synthesized, platform: settings.platform, sdkVariant: settings.sdkVariant, supportedPlatforms: nil, toolchain: nil, canonicalNameSuffix: nil, superimposedProperties: superimposedProperties)
        superimposedSpecializations[configuredTarget.target, default: Set<SpecializationParameters>()].insert(superimposedSpecialization)
    }

    /// Resolve the path for a particular build file.
    nonisolated func resolveBuildFilePath(_ buildFile: BuildFile, settings: Settings, dynamicallyBuildingTargets: Set<Target>) -> Path? {
        // FIXME: This is normalizing over file references and product references, but that doesn't make any sense in the context of resolving implicit dependencies. It would make much more sense for us to directly interpret the target relationship when dealing with a build file which directly references a target, rather than do so via path expansion.
        guard let reference = try? workspaceContext.workspace.resolveBuildableItemReference(buildFile.buildableItem, dynamicallyBuildingTargets: dynamicallyBuildingTargets) else { return nil }
        return settings.filePathResolver.resolveAbsolutePath(reference)
    }

    /// Return the configured version(s) of a top-level target. For a normal build it will return only one version but for the index-build it may return multiple, one for each of the target's supported platforms.
    func lookupTopLevelConfiguredTarget(_ targetInfo: BuildRequest.BuildTargetInfo) -> [ConfiguredTarget] {
        guard !Task.isCancelled else { return [] }
        let (target, parameters) = (targetInfo.target, targetInfo.parameters)
        if !buildRequest.enableIndexBuildArena {
            // Top-level targets get defaults imposed, in case that they are themselves using "auto" anywhere.
            return [lookupConfiguredTarget(target, parameters: parameters, imposedParameters: defaultImposedParameters, isTopLevelLookup: true)]
        }

        // Aggregate targets are only configured as dependencies.
        guard target.type != .aggregate else { return [] }

        let isFromPackage = workspaceContext.workspace.project(for: target).isPackage
        if isFromPackage {
            // Configure top-level package targets using the run-destination of the build request.
            return [lookupConfiguredTarget(target, parameters: parameters, imposedParameters: defaultImposedParameters, isTopLevelLookup: true)]
        }

        var configuredTargets: [ConfiguredTarget] = []
        let unconfiguredSettings = buildRequestContext.getCachedSettings(targetInfo.parameters, target: target)
        let unconfiguredSupportedPlatforms = unconfiguredSettings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS)

        for platformParams in platformBuildParametersForIndex {
            // Before forming all new settings for this platform, do a fast check using `SUPPORTED_PLATFORMS` of `unconfiguredSettings`.
            // This significantly cuts down the work that this function is doing.
            if platformParams.buildParams.activeRunDestination?.sdkVariant == MacCatalystInfo.sdkVariantName {
                // macCatalyst has various special rules, check it by forming new settings normally, below.
                // Carve out once small exception for host tools, which should never build for Catalyst.
                if let standardTarget = target as? StandardTarget, ProductTypeIdentifier(standardTarget.productTypeIdentifier).isHostBuildTool {
                    continue
                }
            } else {
                if let platformName = platformParams.buildParams.activeRunDestination?.platform, unconfiguredSupportedPlatforms.count > 0 {
                    guard unconfiguredSupportedPlatforms.contains(platformName) else { continue }
                }
            }

            guard isTargetSuitableForPlatformForIndex(target, parameters: platformParams.buildParams, imposedParameters: platformParams.specializationParams) else {
                continue
            }
            // Configure the target for this platform.
            let configuredTarget = lookupConfiguredTarget(target, parameters: platformParams.buildParams, imposedParameters: platformParams.specializationParams, isTopLevelLookup: true)
            configuredTargets.append(configuredTarget)
        }
        return configuredTargets
    }

    /// Determines whether a target should be configured for the given platform in the index arena.
    ///
    /// The arena is used for two purposes:
    ///   1. To retrieve settings for a given target
    ///   2. To produce products of source dependencies for compilation purposes (it does not produce binaries)
    ///
    /// Thus, in general if a target doesn't support a platform, we don't want to configure it for that platform. If a
    /// dependency is not supported for the platform of the dependent, presumably the dependent will not be able
    /// to use its products for compilation purposes, since the source products will be put in a different platform
    /// directory and/or they will not be usable by the dependent (e.g. the module will not be importable from a
    /// different platform). If the dependency was intended to be usable from that platform for compilation purposes,
    /// it would be a supported platform.
    ///
    /// There's an exception for this for a dependent host tool, which are required for compilation and must therefore
    /// be configured (and registered as a dependency) regardless.
    nonisolated func isTargetSuitableForPlatformForIndex(_ target: Target, parameters: BuildParameters, imposedParameters: SpecializationParameters?, dependencies: OrderedSet<ConfiguredTarget>? = nil) -> Bool {
        if !buildRequest.enableIndexBuildArena {
            return true
        }

        // Host tools case, always supported we'll override the parameters with that of the host regardless.
        if target.isHostBuildTool || dependencies?.contains(where: { $0.target.isHostBuildTool }) == true {
            return true
        }

        guard let runDestination = parameters.activeRunDestination else { return false }

        // Filter any overrides from the parameters, because they can shadow any original "auto" values.
        let filteredParameters = parameters.withoutOverrides
        var settings = buildRequestContext.getCachedSettings(filteredParameters, target: target)

        if settings.enableTargetPlatformSpecialization, let imposedParameters {
            // This is for targets that have SDKROOT set to 'auto' (like Swift Packages) and get settings "imposed" on them.
            settings = buildRequestContext.getCachedSettings(imposedParameters.imposed(on: filteredParameters, workspaceContext: workspaceContext), target: target)
        }

        guard let targetPlatform = settings.platform else {
            return false
        }
        if targetPlatform.name != runDestination.platform {
            return false
        }
        if settings.sdkVariant?.name != runDestination.sdkVariant {
            return false
        }

        let supportedPlatforms = settings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS)
        if !supportedPlatforms.isEmpty && !supportedPlatforms.contains(targetPlatform.name) {
            return false
        }

        return true
    }

    func compatibleConfiguredTarget(_ dependency: Target, for parameters: BuildParameters, baseTarget: Target) -> ConfiguredTarget? {
        guard let configuredTargetsForDependency = configuredTargetsByTarget[dependency] else {
            return nil
        }

        // Check compatibility with the `baseTarget`, so get the settings for it.
        let settings = buildRequestContext.getCachedSettings(parameters, target: baseTarget)
        let platform = Ref(settings.platform)
        let sdkVariant = settings.sdkVariant?.name
        let sdk = settings.sdk
        let unimposedSettingsOfDependency = buildRequestContext.getCachedSettings(parameters.withoutOverrides, target: dependency)
        let dependencyHasAutoSDKRoot = unimposedSettingsOfDependency.enableTargetPlatformSpecialization

        let compatibleTargets = configuredTargetsForDependency.filter { ct in
            if ct.specializeGuidForActiveRunDestination && parameters.activeRunDestination != ct.parameters.activeRunDestination {
                return false
            }
            let dependencySettings = buildRequestContext.getCachedSettings(ct.parameters, target: ct.target)
            let dependencyPlatform = dependencySettings.platform
            let dependencySdkVariant = dependencySettings.sdkVariant?.name
            guard Ref(dependencyPlatform) == platform && dependencySdkVariant == sdkVariant else { return false }
            // For dependencies with 'auto' SDKROOT, they get their SDK 'imposed', including if it is internal vs public SDK, not just what platform it is.
            // For such dependencies also confirm that the existing configured dependency matches 'internal vs public' for the SDK.
            if dependencyHasAutoSDKRoot, let dependencySDK = dependencySettings.sdk, let dependentSDK = sdk, dependencySDK !== dependentSDK {
                return false
            }
            return true
        }

        // Make sure the returned target is stable
        return compatibleTargets.only ?? Array(compatibleTargets).sorted().first
    }

    /// Find the configured target for a build request item.
    func lookupConfiguredTarget(_ targetInfo: BuildRequest.BuildTargetInfo) -> ConfiguredTarget {
        return lookupConfiguredTarget(targetInfo.target, parameters: targetInfo.parameters, superimposedProperties: nil)
    }

    /// Method to return the configured version of a target, using the specified parameters.
    func lookupConfiguredTarget(_ forTarget: Target, parameters: BuildParameters, superimposedProperties: SuperimposedProperties?) -> ConfiguredTarget {
        let target = workspaceContext.workspace.dynamicTarget(for: forTarget, dynamicallyBuildingTargets: dynamicallyBuildingTargets)

        do {
            // Look up the configured version in our cache.  Return it if it is compatible with the parameters we were passed.
            if let configuredTarget = compatibleConfiguredTarget(target, for: parameters, baseTarget: target) {
                addSuperimposedProperties(for: configuredTarget, superimposedProperties: superimposedProperties)
                return configuredTarget
            }

            // Check whether the new configured target uses the same platform as a previous one, because that's a bug.
            if let previousConfiguredTargets = configuredTargetsByTarget[target] {
                let currentSettings = buildRequestContext.getCachedSettings(parameters, target: target)

                var hasMultipleTargets = false
                for previousConfiguredTarget in previousConfiguredTargets {
                    let previousSettings = buildRequestContext.getCachedSettings(previousConfiguredTarget.parameters, target: previousConfiguredTarget.target)
                    if currentSettings.platform?.displayName == previousSettings.platform?.displayName && currentSettings.sdkVariant?.name == previousSettings.sdkVariant?.name {
                        // Allow multiple configured targets with separate run destinations (this is only the case for
                        // the workspace build description today).
                        if previousConfiguredTarget.specializeGuidForActiveRunDestination && parameters.activeRunDestination != previousConfiguredTarget.parameters.activeRunDestination {
                            continue
                        }
                        // We allow multiple configured targets with different SDK suffixes, this gets sorted out at the very
                        // end of computing the dependency graph.
                        if currentSettings.sdk?.canonicalNameSuffix != previousSettings.sdk?.canonicalNameSuffix {
                            continue
                        }

                        let data = DiagnosticData("multiple configured targets of '\(target.name)' are being created for \(currentSettings.platform?.displayName ?? "")")
                        delegate.emit(Diagnostic(behavior: .error, location: .unknown, data: data))
                        hasMultipleTargets = true
                    }
                }

                // If we are trying to create an invalid configured target, return an existing one instead.
                if hasMultipleTargets {
                    let configuredTarget = previousConfiguredTargets.first!
                    addSuperimposedProperties(for: configuredTarget, superimposedProperties: superimposedProperties)
                    return configuredTarget
                }
            }

            // At this point we know there is not a configured target for this target and parameters in our cache, so create one and return it.
            let configuredTarget = ConfiguredTarget(parameters: parameters, target: target, specializeGuidForActiveRunDestination: buildRequest.enableIndexBuildArena)
            configuredTargetsByTarget[configuredTarget.target, default: []].insert(configuredTarget)
            addSuperimposedProperties(for: configuredTarget, superimposedProperties: superimposedProperties)
            return configuredTarget
        }
    }

    /// Method to return the configured version of a target, using the specified parameters.
    func lookupConfiguredTarget(_ forTarget: Target, parameters: BuildParameters, imposedParameters: SpecializationParameters?, isTopLevelLookup: Bool = false) -> ConfiguredTarget {
        // Forward non-specialized requests.
        guard let specialization = imposedParameters else {
            return lookupConfiguredTarget(forTarget, parameters: parameters, superimposedProperties: nil)
        }

        var parameters = parameters
        if buildRequest.enableIndexBuildArena {
            // Avoid forced propagation of "auto" overrides to targets that don't need them. If this is a host tool,
            // force its parameters to the host platform to avoid creating duplicate configured targets after it has
            // been specialized.
            let platformParams: BuildParameters
            if forTarget.isHostBuildTool {
                platformParams = hostParametersForIndex?.buildParams ?? parameters
            } else {
                platformParams = parameters
            }
            parameters = buildRequest.parameters.replacing(activeRunDestination: platformParams.activeRunDestination, activeArchitecture: platformParams.activeArchitecture)
        }

        // If we have an existing target compatible with the specialization parameters, we always return it.
        //
        // This is unfortunate, because it introduces an ordering dependency on the computation, but it is critical for correctness because we want to ensure that we only create new targets when it results in a meaningful difference, not just because the hash of the build parameters differs.
        //
        // Checking !isTopLevelLookup prevents incorrectly returning a "compatible" target when looking up a top level target where the run destination may be influencing the platform to become iOS vs Mac Catalyst. Previously, this only worked by accident due to concurrency, where top level lookups never returned an existing target due to configuredTargetsByTarget virtually always being empty due to the thread interaction.
        if let configuredTargets = configuredTargetsByTarget[forTarget], !isTopLevelLookup {
            for ct in configuredTargets {
                if ct.specializeGuidForActiveRunDestination && parameters.activeRunDestination != ct.parameters.activeRunDestination { continue }
                let parametersWithoutRunDestination = ct.parameters.replacing(activeRunDestination: nil, activeArchitecture: nil)
                let settings = buildRequestContext.getCachedSettings(parametersWithoutRunDestination, target: ct.target)
                if specialization.isCompatible(with: ct, settings: settings, workspaceContext: workspaceContext) {
                    if imposedParameters?.superimposedProperties != nil {
                        addSuperimposedProperties(for: ct, superimposedProperties: imposedParameters?.superimposedProperties)
                    }
                    return ct
                }
            }
        }

        // Filter any overrides from the parameters, because they can shadow any original "auto" values.
        let filteredParameters = parameters.withoutOverrides

        // Determine which parameters this target allows specialization for.
        let settings = buildRequestContext.getCachedSettings(filteredParameters, target: forTarget)
        let supportedPlatforms = settings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS)
        let shouldImposePlatform = settings.enableTargetPlatformSpecialization

        var imposedSupportedPlatforms: [String]?
        let specializationIsSupported: Bool
        if let specializedSupportedPlatforms = specialization.supportedPlatforms {
            // If `SDKROOT` is automatic, specialize supported platforms, but only if there is a non-empty intersection with the current value.
            specializationIsSupported = !Set(supportedPlatforms).intersection(specializedSupportedPlatforms).isEmpty
            imposedSupportedPlatforms = specializationIsSupported && shouldImposePlatform ? specialization.supportedPlatforms : nil
        } else {
            imposedSupportedPlatforms = nil
            specializationIsSupported = false
        }

        let imposedPlatform: Platform?
        if shouldImposePlatform {
            if specializationIsSupported {
                imposedPlatform = specialization.platform
            } else {
                // There may be an existing `SUPPORTED_PLATFORMS` override in the parameters passed down by the client, so we want to make sure to provide our own, even if it might not be strictly necessary.
                imposedSupportedPlatforms = supportedPlatforms

                let hostPlatform = settings.globalScope.evaluate(BuiltinMacros.HOST_PLATFORM)
                let runDestinationPlatform = buildRequest.parameters.activeRunDestination?.platform
                let supportedPlatformsWithoutSimulators = Set(supportedPlatforms.compactMap { self.workspaceContext.core.platformRegistry.lookup(name: $0) }.filter { !$0.isSimulator }.map { $0.name })

                // If the given specialization is unsupported, we still need to impose a platform.
                if let onlyPlatform = supportedPlatformsWithoutSimulators.only {
                    imposedPlatform = workspaceContext.core.platformRegistry.lookup(name: onlyPlatform)
                } else if let runDestinationPlatform = runDestinationPlatform, supportedPlatforms.contains(runDestinationPlatform) {
                    imposedPlatform = workspaceContext.core.platformRegistry.lookup(name: runDestinationPlatform)
                } else if supportedPlatforms.contains(hostPlatform) {
                    imposedPlatform = workspaceContext.core.platformRegistry.lookup(name: hostPlatform)
                } else {
                    // If neither the run destination nor the host are supported, we cannot deterministically chose a platform if there is more than one supported and we have to emit a diagnostic. For now, this is a warning and we retain the previous (before Xcode 14) behavior of specializing the platform anyway without touching supported platforms, but in the future, we should make this an error.
                    imposedPlatform = specialization.platform
                    imposedSupportedPlatforms = nil

                    if let specializedSupportedPlatforms = specialization.supportedPlatforms, let imposedPlatform = imposedPlatform {
                        let data = DiagnosticData("Target '\(forTarget.name)' does not support any of the imposed platforms '\(specializedSupportedPlatforms.joined(separator: " "))' and a single platform could not be chosen from its own supported platforms '\(supportedPlatforms.joined(separator: " "))'. For backwards compatibility, it will be built for \(imposedPlatform.displayName).")
                        delegate.emit(Diagnostic(behavior: .warning, location: .unknown, data: data))
                    } else {
                        // Since imposing a platform implies imposing `SUPPORTED_PLATFORMS` as well, I think this is only reachable if the imposed platform is nil.
                        // We emit extra diagnostics about the imposed parameters here because it's likely something strange has happened if we get here.
                        specialization.emitDiagnostics(to: delegate)
                        let data = DiagnosticData("Could not choose a single platform for target '\(forTarget.name)' from the supported platforms '\(supportedPlatforms.joined(separator: " "))'. \(imposedParameters?.description ?? "(No specialization parameters.)")")
                        let warnOnly = UserDefaults.platformSpecializationWarnOnly
                        delegate.emit(Diagnostic(behavior: warnOnly ? .warning : .error, location: .unknown, data: data))
                    }
                }
            }
        } else {
            imposedPlatform = nil
        }

        let imposedSdkVariant: SDKVariant?
        if shouldImposePlatform {
            // Never impose an SDK variant on a host tool, they should always build against the default variant.
            // Ideally, this should be replaced by a check that a variant (e.g. Mac Catalyst) is not imposed on
            // a target which doesn't support building for that variant. This is complicated by the fact that
            // iOS targets get SUPPORTS_MACCATALYST by default, but SDKROOT=auto targets get an inconsistent view.

            if specializationIsSupported && !forTarget.isHostBuildTool {
                imposedSdkVariant = specialization.sdkVariant ?? imposedPlatform?.defaultSDKVariant
            } else {
                imposedSdkVariant = imposedPlatform?.defaultSDKVariant
            }
        }
        else {
            imposedSdkVariant = nil
        }

        // Compute whether the target has expressed an opinion about requiring a suffixed sdk.
        let imposedCanonicalNameSuffix: String?
        if shouldImposePlatform {
            let initialFilteredSpecialization = SpecializationParameters(source: .synthesized, platform: imposedPlatform, sdkVariant: imposedSdkVariant, supportedPlatforms: imposedSupportedPlatforms, toolchain: nil, canonicalNameSuffix: nil)
            let initialSettings = buildRequestContext.getCachedSettings(initialFilteredSpecialization.imposed(on: parameters, workspaceContext: workspaceContext), target: forTarget)
            let specializationSDKOptions = initialSettings.globalScope.evaluate(BuiltinMacros.SPECIALIZATION_SDK_OPTIONS)
            if specializationIsSupported {
                // If specialization explicitly requires public, but the target itself requires internal, emit an error.
                if let sdkSuffixFromSpecialization = specialization.canonicalNameSuffix, sdkSuffixFromSpecialization.isEmpty, !specializationSDKOptions.isEmpty {
                    let specializationSuffix: String
                    switch specialization.source {
                    case .synthesized:
                        specializationSuffix = ""
                    case .workspace:
                        specializationSuffix = " because of the active run destination"
                    case let .target(name):
                        specializationSuffix = " by target '\(name)'"
                    }
                    let data = DiagnosticData("Target '\(forTarget.name)' requires the \(specializationSDKOptions.joined(separator: " ")) SDK, but is being specialized for the public SDK\(specializationSuffix).")

                    // Avoid an error in the index arena case, since indexing is blocked on
                    // having a build description, severely hampering semantic functionality.
                    let behavior: Diagnostic.Behavior = buildRequest.enableIndexBuildArena ? .warning : .error

                    delegate.emit(Diagnostic(behavior: behavior, location: .unknown, data: data, childDiagnostics: {
                        switch specialization.source {
                        case .synthesized, .workspace:
                            []
                        case let .target(name):
                            [Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Consider changing target '\(name)' to build using an \(specializationSDKOptions.joined(separator: " ")) SDK."))]
                        }
                    }()))
                }

                // Since we are imposing a platform, we also need to impose internal-ness (from either the client or `SPECIALIZATION_SDK_OPTIONS`).
                let suffixes = OrderedSet(([specialization.canonicalNameSuffix] + specializationSDKOptions).compactMap { $0?.nilIfEmpty })
                if suffixes.isEmpty {
                    imposedCanonicalNameSuffix = ""
                } else if let suffix = suffixes.only {
                    imposedCanonicalNameSuffix = suffix
                } else {
                    delegate.error("cannot impose multiple sdk suffixes on target '\(forTarget.name)': \(suffixes.joined(separator: ", "))")
                    imposedCanonicalNameSuffix = ""
                }
            } else {
                let suffixes = OrderedSet(specializationSDKOptions)
                if suffixes.isEmpty {
                    imposedCanonicalNameSuffix = nil
                } else if let suffix = suffixes.only {
                    imposedCanonicalNameSuffix = suffix
                } else {
                    delegate.error("cannot impose multiple sdk suffixes on target '\(forTarget.name)': \(suffixes.joined(separator: ", "))")
                    imposedCanonicalNameSuffix = nil
                }
            }
        } else {
            imposedCanonicalNameSuffix = nil
        }

        // If we are imposing a platform, we also need to impose the toolchain, but skip it if the explicit setting already matches what we would impose.
        let imposedToolchain: [String]?
        if shouldImposePlatform && specializationIsSupported {
            let specializationWithoutToolchainImposition = SpecializationParameters(source: .synthesized, platform: imposedPlatform, sdkVariant: imposedSdkVariant, supportedPlatforms: imposedSupportedPlatforms, toolchain: nil, canonicalNameSuffix: imposedCanonicalNameSuffix)
            let settingsWithToolchainImposition = buildRequestContext.getCachedSettings(specializationWithoutToolchainImposition.imposed(on: parameters, workspaceContext: workspaceContext), target: forTarget)
            let configuredToolchains = settingsWithToolchainImposition.toolchains.map({ $0.identifier })
            if let specializedToolchains = specialization.toolchain, configuredToolchains == specializedToolchains {
                imposedToolchain = nil
            } else {
                imposedToolchain = specialization.toolchain
            }
        } else {
            imposedToolchain = nil
        }

        let fromPackage =  workspaceContext.workspace.project(for: forTarget).isPackage
        let filteredSpecialization = SpecializationParameters(source: .synthesized, platform: imposedPlatform, sdkVariant: imposedSdkVariant, supportedPlatforms: imposedSupportedPlatforms, toolchain: imposedToolchain, canonicalNameSuffix: imposedCanonicalNameSuffix, superimposedProperties: specialization.superimposedProperties)

        // Otherwise, we need to create a new specialization; do so by imposing the specialization on the build parameters.
        // NOTE: If the target doesn't support specialization, then unless the target comes from a package, then it's important to **not** impart those settings unless they are coming from overrides. Doing so has the side-effect of causing dependencies of downstream targets to be specialized incorrectly (e.g. a specialized target shouldn't cause its own dependencies to be specialized).
        // FIXME: rdar://80907686 (BuildParameters are ConfiguredTargets is problematic)
        // Ideally, this code shouldn't live here, but there are issues tracked in (rdar://80907686) that we need to work through.
        if settings.enableTargetPlatformSpecialization || settings.enableBuildRequestOverrides || fromPackage {
            return lookupConfiguredTarget(forTarget, parameters: filteredSpecialization.imposed(on: parameters, workspaceContext: workspaceContext), superimposedProperties: filteredSpecialization.superimposedProperties)
        }
        else {
            let nonimposedParameters = fromPackage ? parameters : parameters.withoutImposedOverrides(buildRequest, core: workspaceContext.core)
            return lookupConfiguredTarget(forTarget, parameters: filteredSpecialization.imposed(on: nonimposedParameters, workspaceContext: workspaceContext), superimposedProperties: filteredSpecialization.superimposedProperties)
        }
    }

    /// Get the resolved explicit dependencies for an individual target.  This does not include any implicit dependencies.
    @_spi(Testing) public nonisolated func explicitDependencies(for configuredTarget: ConfiguredTarget) -> [Target] {
        let scope = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target).globalScope

        let platformFilteringContext: any PlatformFilteringContext = PlatformFilter(scope)
        let excludedExplicitDependencies = scope.evaluate(BuiltinMacros.EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES)
        let includedExplicitDependencies = scope.evaluate(BuiltinMacros.INCLUDED_EXPLICIT_TARGET_DEPENDENCIES)

        func isExcludedByName(_ targetName: String) -> Bool {
            guard !excludedExplicitDependencies.isEmpty else { return false }

            func matchesPattern(inList patterns: [String]) -> Bool {
                for pattern in patterns {
                    if (try? fnmatch(pattern: pattern, input: targetName)) ?? false {
                        return true
                    }
                }
                return false
            }

            return matchesPattern(inList: excludedExplicitDependencies) && !matchesPattern(inList: includedExplicitDependencies)
        }

        return configuredTarget.target.dependencies.compactMap { dependency in
            if !platformFilteringContext.currentPlatformFilter.matches(dependency.platformFilters) {
                emitSkippedTargetDependencyDiagnostic(.platformFilter, platformFilteringContext, configuredTarget, dependency)
                return nil
            }

            guard let target = workspaceContext.workspace.target(for: dependency.guid) else {
                // If a target has a direct dependency GUID which is missing, then it is silently skipped.
                //
                // FIXME: We should probably emit a hard error here for package dependencies.
                emitSkippedTargetDependencyDiagnostic(.notFound, platformFilteringContext, configuredTarget, dependency)
                return nil
            }

            let actualTarget = workspaceContext.workspace.dynamicTarget(for: target, dynamicallyBuildingTargets: dynamicallyBuildingTargets)

            if isExcludedByName(actualTarget.name) {
                emitSkippedTargetDependencyDiagnostic(.excludedTargetDependency, platformFilteringContext, configuredTarget, dependency)
                return nil
            }

            return actualTarget
        }
    }

    nonisolated private func hasPackageDependencies(_ configuredTarget: ConfiguredTarget) -> Bool {
        return explicitDependencies(for: configuredTarget).contains {
            workspaceContext.workspace.project(for: $0).isPackage
        }
    }

    nonisolated func emitUnsupportedAggregateTargetDiagnostic(for configuredTarget: ConfiguredTarget) {
        // If the aggregate has no target dependencies from packages, do not emit it.
        guard hasPackageDependencies(configuredTarget) else {
            return
        }

        let data = DiagnosticData("unsupported configuration: the aggregate target '\(configuredTarget.target.name)' has package dependencies, but targets that build for different platforms depend on it")
        delegate.emit(Diagnostic(behavior: .error, location: .unknown, data: data))
    }

    /// The reason _why_ an explicit target dependency was skipped in the current build context.
    public enum TargetDependencySkipReason: Sendable {
        /// The target dependency was skipped because its platform filters did not match that of the current build context.
        case platformFilter

        /// The target dependency was skipped because it was listed in `EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES`.
        case excludedTargetDependency

        /// The target dependency was skipped because it was not found.
        /// This behavior exists for compatibility with the historical behavior of Xcode projects,
        /// where dependencies are allowed to be silently missing due to the use case of missing project references.
        case notFound
    }

    nonisolated func emitSkippedTargetDependencyDiagnostic(_ skipReason: TargetDependencySkipReason, _ context: any PlatformFilteringContext, _ configuredTarget: ConfiguredTarget, _ targetDependency: TargetDependency) {
        guard workspaceContext.userPreferences.enableDebugActivityLogs else {
            return
        }

        switch skipReason {
        case .platformFilter:
            let filterString = targetDependency.platformFilters.sorted().map(\.comparisonString).joined(separator: ", ").nilIfEmpty ?? "<none>"
            let currentFilterString = context.currentPlatformFilter?.comparisonString.nilIfEmpty ?? "<none>"

            // Only try to show the dependency name (and not the GUID), because the GUID is not likely to be useful if we know the dependency is skipped due to platform filters (since they can be clearly seen).
            delegate.emit(.overrideTarget(configuredTarget), SWBUtil.Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Skipping target dependency '\(targetDependency.name ?? "(null)")' because its platform filter (\(filterString)) does not match the platform filter of the current context (\(currentFilterString)).")))
        case .excludedTargetDependency:
            // Only try to show the dependency name (and not the GUID) because the GUID is not likely to be useful if we know the dependency is skipped due to EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES.
            delegate.emit(.overrideTarget(configuredTarget), SWBUtil.Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Skipping target dependency '\(targetDependency.name ?? "(null)")' because it is listed in EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES.")))
        case .notFound:
            let targetDependencyInfix = targetDependency.guid.nilIfEmpty.map { guid in "target with GUID '\(guid)'" } ?? "such target"

            // Always try to show both the dependency name and GUID, because the GUID of a missing dependency is likely useful for debugging purposes.
            delegate.emit(.overrideTarget(configuredTarget), SWBUtil.Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Skipping target dependency '\(targetDependency.name ?? "(null)")' because there is no \(targetDependencyInfix) in the workspace (it may exist in a project pointed to by a missing project reference).")))
        }
    }
}

extension DependencyResolver {
    /// A wrapper around `TaskGroup.concurrentPerform()` to provide a mechanism to easily change the parallel discovery for debugging purposes.
    func concurrentPerform(iterations: Int, maximumParallelism: Int, fn: @Sendable @escaping (Int) async -> Void) async {
        if disableConcurrentDependencyResolution {
            for n in 0..<iterations {
                await fn(n)
            }
        }
        else {
            await TaskGroup.concurrentPerform(iterations: iterations, maximumParallelism: maximumParallelism, execute: fn)
        }
    }

    /// A wrapper used to convert `concurrentMap` calls to iterative `map` calls for easier debugging.
    func concurrentMap<Element: Sendable, T: Sendable, S: Sendable>(maximumParallelism: Int, _ items: S, _ transform: @Sendable @escaping (Element) async -> [T]) async -> [T] where S: Sequence<Element> {
        if disableConcurrentDependencyResolution {
            return await items.asyncMap(transform).flatMap { $0 }
        }
        else {
            return await items.concurrentMap(maximumParallelism: maximumParallelism, transform).flatMap { $0 }
        }
    }
}

extension Platform {
    var defaultSDKVariant: SDKVariant? {
        guard let sdkCanonicalName else { return nil }
        // FIXME: Do we need a better way to find the "right" SDK here? Seems to work fine for macOS right now.
        return sdks.filter { $0.isBaseSDK && $0.canonicalName.hasPrefix(sdkCanonicalName) }.first?.defaultVariant
    }
}

fileprivate extension Target {
    var isHostBuildTool: Bool {
        guard let standardTarget = self as? StandardTarget else { return false }
        return ProductTypeIdentifier(standardTarget.productTypeIdentifier).isHostBuildTool
    }
}
