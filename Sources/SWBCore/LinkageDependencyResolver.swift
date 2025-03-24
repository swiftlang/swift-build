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
import SWBMacro

/// A completely resolved graph of configured targets for use in a build.
public struct TargetLinkageGraph: TargetGraph {
    /// The workspace context this graph is for.
    public let workspaceContext: WorkspaceContext

    /// The build request the graph is for.
    public let buildRequest: BuildRequest

    /// The complete list of configured targets, in topological order.
    public let allTargets: OrderedSet<ConfiguredTarget>

    /// The mapping containing the immediate predecessors of each configured target, including implicit dependencies if enabled.
    private let targetDependencies: [ConfiguredTarget: [ResolvedTargetDependency]]

    /// Construct a new graph for the given build request.
    ///
    ///
    /// The result closure guarantees that all targets a target depends on appear in the returned array before that target.  Any detected dependency cycles will be broken.
    public init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: any TargetDependencyResolverDelegate) async {
        let (allTargets, targetDependencies) = await MacroNamespace.withExpressionInterningEnabled {
            await buildRequestContext.keepAliveSettingsCache {
                let resolver = LinkageDependencyResolver(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
                return await resolver.computeGraph()
            }
        }
        self.init(workspaceContext: workspaceContext, buildRequest: buildRequest, allTargets: allTargets, targetDependencies: targetDependencies)
    }

    public init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, allTargets: OrderedSet<ConfiguredTarget>, targetDependencies: [ConfiguredTarget: [ResolvedTargetDependency]]) {
        self.workspaceContext = workspaceContext
        self.buildRequest = buildRequest
        self.allTargets = allTargets
        self.targetDependencies = targetDependencies
    }

    /// Get the dependencies of a target in the graph.
    public func dependencies(of target: ConfiguredTarget) -> [ConfiguredTarget] {
        return targetDependencies[target]?.map({ $0.target }) ?? []
    }
}

fileprivate extension LinkageDependencyResolver {
    nonisolated var workspaceContext: WorkspaceContext {
        resolver.workspaceContext
    }

    nonisolated var buildRequest: BuildRequest {
        resolver.buildRequest
    }

    nonisolated var buildRequestContext: BuildRequestContext {
        resolver.buildRequestContext
    }

    nonisolated var delegate: any TargetDependencyResolverDelegate {
        resolver.delegate
    }
}

actor LinkageDependencyResolver {
    /// Sets of targets mapped by product name.
    private let targetsByProductName: [String: Set<StandardTarget>]

    /// Sets of targets mapped by product name stem.
    private let targetsByProductNameStem: [String: Set<StandardTarget>]

    internal let resolver: DependencyResolver

    init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: any TargetDependencyResolverDelegate) {
        var targetsByProductName = [String: Set<StandardTarget>]()
        var targetsByProductNameStem = [String: Set<StandardTarget>]()
        for case let target as StandardTarget in workspaceContext.workspace.allTargets {
            // FIXME: We are relying on the product reference name being constant here. This is currently true, given how our path resolver works, but it is possible to construct an Xcode project for which this doesn't work (Xcode doesn't, however, handle that situation very well). We should resolve this: <rdar://problem/29410050> Swift Build doesn't support product references with non-constant basenames

            // Add to the mapping by the full product name.
            let productName = target.productReference.name
            targetsByProductName[productName, default: []].insert(target)

            // Add to the mapping by the name stem, if different from the full product name; if it is the same, then lookups should instead end up using the full-name table we created above.
            if let stem = Path(productName).stem, stem != productName {
                targetsByProductNameStem[stem, default: []].insert(target)
            }
        }

        // Remember the mappings we created.
        self.targetsByProductName = targetsByProductName
        self.targetsByProductNameStem = targetsByProductNameStem

        resolver = DependencyResolver(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
    }

    fileprivate func computeGraph() async -> (allTargets: OrderedSet<ConfiguredTarget>, targetDependencies: [ConfiguredTarget: [ResolvedTargetDependency]]) {
        let topLevelTargetsToDiscover = await resolver.concurrentMap(maximumParallelism: 100, buildRequest.buildTargets) { [self] targetInfo async in await resolver.lookupTopLevelConfiguredTarget(targetInfo) }.compactMap { $0 }
        if !topLevelTargetsToDiscover.isEmpty {
            await resolver.concurrentPerform(iterations: topLevelTargetsToDiscover.count, maximumParallelism: 100) { [self] i in
                if Task.isCancelled { return }
                let configuredTarget = topLevelTargetsToDiscover[i]
                let imposedParameters = resolver.specializationParameters(configuredTarget, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
                let dependenciesOnPath = LinkageDependencies()
                await linkageDependencies(for: configuredTarget, imposedParameters: imposedParameters, dependenciesOnPath: dependenciesOnPath)
            }
        }

        var allTargets = OrderedSet<ConfiguredTarget>()
        for (target, dependencies) in dependenciesPerTarget {
            allTargets.insert(target, at: 0)
            for dependency in dependencies {
                allTargets.insert(dependency.target, at: 0)
            }
        }

        return (allTargets, dependenciesPerTarget)
    }

    private var dependenciesPerTarget = [ConfiguredTarget: [ResolvedTargetDependency]]()
    private var visitedDiscoveredTargets = Set<ConfiguredTarget>()

    private func linkageDependencies(for configuredTarget: ConfiguredTarget, imposedParameters: SpecializationParameters?, dependenciesOnPath: LinkageDependencies) async {
        // Track that we have visited this target.
        let visited = !visitedDiscoveredTargets.insert(configuredTarget).inserted

        if visited && configuredTarget.target.type == .aggregate && resolver.makeAggregateTargetsTransparentForSpecialization {
            let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
            if let imposedParameters = imposedParameters, !imposedParameters.isCompatible(with: configuredTarget, settings: settings, workspaceContext: workspaceContext) {
                resolver.emitUnsupportedAggregateTargetDiagnostic(for: configuredTarget)
            }
        }

        // If already visited, or we have been cancelled, bail out.
        if visited || Task.isCancelled {
            return
        }

        let linkageDependencies = await allLinkedDependencies(for: configuredTarget, imposedParameters: imposedParameters, resolver: resolver)
        dependenciesPerTarget[configuredTarget] = linkageDependencies

        // Even though we do not want to include target dependencies in the graph, we still need to traverse them.
        let linkedTargets = linkageDependencies.map { $0.target.target }
        let targetDependencies: [ResolvedTargetDependency] = await resolver.explicitDependencies(for: configuredTarget).asyncMap { target in
            guard !linkedTargets.contains(target) else {
                return nil
            }
            let buildParameters = resolver.buildParametersByTarget[target] ?? configuredTarget.parameters
            if await !resolver.isTargetSuitableForPlatformForIndex(target, parameters: buildParameters, imposedParameters: imposedParameters, dependencies: dependenciesOnPath.path) {
                return nil
            }
            let effectiveImposedParameters = imposedParameters?.effectiveParameters(target: configuredTarget, dependency: ConfiguredTarget(parameters: buildParameters, target: target), dependencyResolver: resolver)
            let configuredDependency = await resolver.lookupConfiguredTarget(target, parameters: buildParameters, imposedParameters: effectiveImposedParameters)
            return ResolvedTargetDependency(target: configuredDependency, reason: .explicit)
        }.compactMap { $0 }
        let dependencies = linkageDependencies + targetDependencies

        // If we have no dependencies, we are done.
        if dependencies.isEmpty {
            return
        }

        // Otherwise, dispatch discovery of all of the immediate dependencies in parallel.
        await resolver.concurrentPerform(iterations: dependencies.count, maximumParallelism: 100) { [self] i in
            let dependency = dependencies[i]
            let imposedParametersForDependency: SpecializationParameters?
            if resolver.makeAggregateTargetsTransparentForSpecialization {
                // Aggregate targets should be transparent for specialization.
                if let imposedParameters = imposedParameters, dependency.target.target.type == .aggregate {
                    imposedParametersForDependency = imposedParameters
                } else {
                    imposedParametersForDependency = resolver.specializationParameters(dependency.target, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
                }
            } else {
                imposedParametersForDependency = resolver.specializationParameters(dependency.target, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
            }
            await self.linkageDependencies(for: dependency.target, imposedParameters: imposedParametersForDependency, dependenciesOnPath: dependenciesOnPath)
        }
    }

    /// Compute the list of implicit dependencies of a target.
    func implicitDependencies(for configuredTarget: ConfiguredTarget, immediateDependencies: [ConfiguredTarget], imposedParameters: SpecializationParameters?, resolver: isolated DependencyResolver) async -> [ResolvedTargetDependency] {
        if workspaceContext.workspace.project(for: configuredTarget.target).isPackage {
            // Packages should never have implicit dependencies.
            return []
        } else {
            return await dependencies(for: configuredTarget, immediateDependencies: immediateDependencies, imposedParameters: imposedParameters, implicitOnly: true, resolver: resolver)
        }
    }

    func allLinkedDependencies(for configuredTarget: ConfiguredTarget, imposedParameters: SpecializationParameters?, resolver: isolated DependencyResolver) async -> [ResolvedTargetDependency] {
        return await dependencies(for: configuredTarget, immediateDependencies: [], imposedParameters: imposedParameters, implicitOnly: false, resolver: resolver)
    }

    /// Compute the list of dependencies of a target.
    func dependencies(for configuredTarget: ConfiguredTarget, immediateDependencies: [ConfiguredTarget], imposedParameters: SpecializationParameters?, implicitOnly: Bool, resolver: isolated DependencyResolver) async -> [ResolvedTargetDependency] {
        precondition(implicitOnly || immediateDependencies.count == 0)

        // For package targets and aggregate targets, we fall back to looking at target dependencies if we are asked for full dependency information.
        if !implicitOnly && (workspaceContext.workspace.project(for: configuredTarget.target).isPackage || configuredTarget.target.type == .aggregate) {
            return resolver.explicitDependencies(for: configuredTarget).map { candidateTarget in
                let buildParameters = resolver.buildParametersByTarget[candidateTarget] ?? configuredTarget.parameters
                let settings = buildRequestContext.getCachedSettings(buildParameters, target: candidateTarget)
                // Do not return executables as being linked.
                if settings.globalScope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_execute" {
                    return nil
                } else {
                    let effectiveImposedParameters = imposedParameters?.effectiveParameters(target: configuredTarget, dependency: ConfiguredTarget(parameters: buildParameters, target: candidateTarget), dependencyResolver: resolver)
                    let configuredDependency = resolver.lookupConfiguredTarget(candidateTarget, parameters: buildParameters, imposedParameters: effectiveImposedParameters)
                    return ResolvedTargetDependency(target: configuredDependency, reason: .explicit)
                }
            }.compactMap { $0 }
        }

        // Only build phase targets can contribute implicit dependencies.
        guard let target = configuredTarget.target as? BuildPhaseTarget else { return [] }

        let configuredTargetSettings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: target)

        // If this target doesn't define an implicit dependency domain, then don't perform this resolution.
        guard !configuredTargetSettings.globalScope.evaluate(BuiltinMacros.IMPLICIT_DEPENDENCY_DOMAIN).isEmpty else {
            if workspaceContext.userPreferences.enableDebugActivityLogs {
                delegate.emit(.overrideTarget(configuredTarget), SWBUtil.Diagnostic(behavior: .note, location: .buildSetting(BuiltinMacros.IMPLICIT_DEPENDENCY_DOMAIN), data: DiagnosticData("\(configuredTarget.target.name) not resolving implicit dependencies because IMPLICIT_DEPENDENCY_DOMAIN is empty.")))
            }
            return []
        }

        // If we're resolving implicit dependencies, build up the names of products of these targets, so we don't try to resolve implicit dependencies for any of them.
        let productNamesOfExplicitDependencies = Set<String>(immediateDependencies.compactMap{ ($0.target as? StandardTarget)?.productReference.name })

        // Get information about the configured target which we need to determine its implicit dependencies.
        let buildFileFilter = LinkageDependencyBuildFileFilteringContext(scope: configuredTargetSettings.globalScope)

        let packageProductDependencies = resolver.explicitDependencies(for: configuredTarget).filter({
            workspaceContext.workspace.project(for: $0).isPackage || $0.type == .packageProduct
        })

        // Go through the build phases.  The Frameworks and CopyFiles build phases are considered for implicit dependencies.
        actor ResolvedTargetDependencies {
            var value = [ResolvedTargetDependency]()

            func append(_ dependency: ResolvedTargetDependency) {
                value.append(dependency)
            }
        }
        let result = ResolvedTargetDependencies()
        for buildPhase in target.buildPhases {
            if Task.isCancelled { break }

            switch buildPhase {
            case let frameworksBuildPhase as FrameworksBuildPhase:
                for buildFile in frameworksBuildPhase.buildFiles {
                    // Skip this build file if it's excluded by EXCLUDED_SOURCE_FILE_NAMES or platform filters.
                    guard let buildFilePath = resolver.resolveBuildFilePath(buildFile, settings: configuredTargetSettings, dynamicallyBuildingTargets: resolver.dynamicallyBuildingTargets), !buildFileFilter.isExcluded(buildFilePath, filters: buildFile.platformFilters) else {
                        continue
                    }

                    // Skip this build file if its reference's file name is the same as the product of one of our explicit dependencies.  This effectively matches the build file to an explicit dependency.
                    let productName = buildFilePath.basename
                    guard !productNamesOfExplicitDependencies.contains(productName) else { continue }

                    // Start by matching against package product dependencies to avoid finding implicit dependencies with matching product names.
                    if case let .targetProduct(guid) = buildFile.buildableItem, !implicitOnly {
                        if let candidateTarget = packageProductDependencies.filter({ $0.guid == guid }).first {
                            let buildParameters = resolver.buildParametersByTarget[candidateTarget] ?? configuredTarget.parameters
                            let effectiveImposedParameters = imposedParameters?.effectiveParameters(target: configuredTarget, dependency: ConfiguredTarget(parameters: buildParameters, target: candidateTarget), dependencyResolver: resolver)
                            let implicitDependency = resolver.lookupConfiguredTarget(candidateTarget, parameters: buildParameters, imposedParameters: effectiveImposedParameters)
                            await result.append(ResolvedTargetDependency(target: implicitDependency, reason: .implicitBuildPhaseLinkage(filename: productName, buildableItem: buildFile.buildableItem, buildPhase: buildPhase.name)))
                            continue
                        }
                    }

                    // If we can find a target in the workspace which generates a product with the full name of this path, then use it.
                    if let implicitDependency = await implicitDependency(forProductName: productName, from: configuredTarget, imposedParameters: imposedParameters, source: .productReference(name: productName, buildFile: buildFile, buildPhase: buildPhase)) {
                        await result.append(ResolvedTargetDependency(target: implicitDependency, reason: .implicitBuildPhaseLinkage(filename: productName, buildableItem: buildFile.buildableItem, buildPhase: buildPhase.name)))
                        continue
                    }


                    // Look for a target which generates a product with the stem of this name.
                    //
                    // The purpose of this logic (at present) is to be able to resolve implicit dependencies when linking against the binary inside of an arbitrary bundle.  For example, this can be used for the Xcode workspace itself to deal with linking against the binary inside a .ideplugin.
                    if let stem = buildFilePath.stem, !productNamesOfExplicitDependencies.contains(where: { Path($0).stem == stem }), let implicitDependency = await implicitDependency(forProductNameStem: stem, buildFilePath: buildFilePath, from: configuredTarget, imposedParameters: imposedParameters, source: .productNameStem(stem, buildFile: buildFile, buildPhase: buildPhase)) {
                        await result.append(ResolvedTargetDependency(target: implicitDependency, reason: .implicitBuildPhaseLinkage(filename: productName, buildableItem: buildFile.buildableItem, buildPhase: buildPhase.name)))
                    }
                }

            case let copyFilesBuildPhase as CopyFilesBuildPhase:
                // Skip "Copy Files" if we are asked for full dependency information.
                if !implicitOnly { continue }

                for buildFile in copyFilesBuildPhase.buildFiles {
                    // Skip this build file if it's excluded by EXCLUDED_SOURCE_FILE_NAMES or platform filters.
                    guard let buildFilePath = resolver.resolveBuildFilePath(buildFile, settings: configuredTargetSettings, dynamicallyBuildingTargets: resolver.dynamicallyBuildingTargets), !buildFileFilter.isExcluded(buildFilePath, filters: buildFile.platformFilters) else {
                        continue
                    }

                    // Skip this build file if its reference's file name is the same as the product of one of our explicit dependencies.  This effectively matches the build file to an explicit dependency.
                    let productName = buildFilePath.basename
                    guard !productNamesOfExplicitDependencies.contains(productName) else { continue }

                    // If we can find a target in the workspace which generates a product with the full name of this path, then use it.
                    if let implicitDependency = await implicitDependency(forProductName: productName, from: configuredTarget, imposedParameters: imposedParameters, source: .productReference(name: productName, buildFile: buildFile, buildPhase: buildPhase)) {
                        await result.append(ResolvedTargetDependency(target: implicitDependency, reason: .implicitBuildPhaseLinkage(filename: productName, buildableItem: buildFile.buildableItem, buildPhase: buildPhase.name)))
                    }
                }

            default:
                // Skip all other build phase types.
                continue
            }
        }

        // Parse a subset of Other Linker Flags
        if !configuredTargetSettings.globalScope.evaluate(BuiltinMacros.IMPLICIT_DEPENDENCIES_IGNORE_LDFLAGS) {
            await LdLinkerSpec.processLinkerSettingsForLibraryOptions(settings: configuredTargetSettings) { macro, flag, stem in
                // Don't use -upward options because they seem theoretically more likely to cause a cycle.
                guard !flag.hasPrefix("-upward") else {
                    return
                }

                let productName = "\(stem).framework"

                // Skip this flag if its corresponding product name is the same as the product of one of our explicit dependencies.  This effectively matches the flag to an explicit dependency.
                if !productNamesOfExplicitDependencies.contains(productName), let implicitDependency = await implicitDependency(forProductName: productName, from: configuredTarget, imposedParameters: imposedParameters, source: .frameworkLinkerFlag(flag: flag, frameworkName: stem, buildSetting: macro)) {
                    await result.append(ResolvedTargetDependency(target: implicitDependency, reason: .implicitBuildSettingLinkage(settingName: macro.name, options: [flag, stem])))
                    return
                }
            } addLibrary: { macro, prefix, stem in
                // Don't use -upward options because they seem theoretically more likely to cause a cycle.
                guard !prefix.hasPrefix("-upward") else {
                    return
                }

                // Check for a product name following the Unix standard library naming convention "lib*{.dylib,.tbd,.so,.a}", trying each suffix in the same order as the linker. Note that we DON'T use product stem name matching because we don't want -lfoo to potentially match bundles such as foo.framework, or targets whose products' whose naming convention isn't compatible with what the -l style flags could potentially match.
                let productNames = Path.libraryExtensions.map { "lib\(stem).\($0)" }

                // Skip this flag if one of its possible corresponding product names is the same as the product of one of our explicit dependencies.  This effectively matches the flag to an explicit dependency.
                if productNamesOfExplicitDependencies.intersection(productNames).isEmpty {
                    for productName in productNames {
                        if let implicitDependency = await implicitDependency(forProductName: productName, from: configuredTarget, imposedParameters: imposedParameters, source: .libraryLinkerFlag(flag: prefix, libraryName: stem, buildSetting: macro)) {
                            await result.append(ResolvedTargetDependency(target: implicitDependency, reason: .implicitBuildSettingLinkage(settingName: macro.name, options: ["\(prefix)\(stem)"])))
                            // We only match one.
                            return
                        }
                    }
                }
            } addError: { error in
                // We presently don't report errors here.  It's unclear whether target dependency resolution is the right place to report issues with these settings or if they should be correctness-checked elsewhere.
            }
        }

        return await result.value
    }

    /// Check if `candidateDependency` is an appropriate implicit dependency for the target whose dependency we're resolving.
    private func implicitDependency(candidate candidateDependencyTarget: Target, parameters candidateParameters: BuildParameters, isValidFor configuredTarget: ConfiguredTarget, imposedParameters: SpecializationParameters?, resolver: isolated DependencyResolver) -> ConfiguredTarget? {

        // Package targets should never be returned as an implicit dependency.
        guard !workspaceContext.workspace.project(for: candidateDependencyTarget).isPackage else {
            return nil
        }

        // FIXME: Move settings into ConfiguredTarget.
        let configuredTargetSettings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
        let configuredTargetPlatform = configuredTargetSettings.platform

        // Don't make a target depend on itself.
        guard configuredTarget.target != candidateDependencyTarget else { return nil }

        // Get the settings for the candidate dependency, using the parameters from the target that is considering depending on it. Also, it is important to impose and build settings on the candidate settings as the target may have the generalized 'auto' settings and we need to realize these to a specific configuration.
        // NOTE: The non-imposed parameters are needed to be used as the target itself could have already been specialized, putting those settings into its build parameters.
        let nonimposedParameters = configuredTarget.parameters.withoutImposedOverrides(buildRequest, core: workspaceContext.core)
        var candidateDependencySettings = buildRequestContext.getCachedSettings(nonimposedParameters, target: candidateDependencyTarget)
        if let imposedParameters, candidateDependencySettings.enableTargetPlatformSpecialization {
            candidateDependencySettings = buildRequestContext.getCachedSettings(imposedParameters.imposed(on: nonimposedParameters, workspaceContext: workspaceContext), target: candidateDependencyTarget)
        }

        // Avoid calling `lookupConfiguredTarget()` until after we have verified that the candidate (target, parameters) pair is compatible.
        // Otherwise an incompatible and rejected target will still be added to `DependencyResolver.configuredTargetsByTarget` and may interfere with dependency resolution (see rdar://77509554).
        // We create the configured target object here mainly for passing information for the rejection diagnostic.
        let candidateDependency = ConfiguredTarget(parameters: candidateParameters, target: candidateDependencyTarget, specializeGuidForActiveRunDestination: buildRequest.enableIndexBuildArena)

        // If implicitDependency's settings define SUPPORTED_PLATFORMS, then it must include the platform that configuredTarget is configured for.
        let candidateDependencySupportedPlatforms = candidateDependencySettings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS)
        if let configuredTargetPlatform, candidateDependencySupportedPlatforms.count > 0 {
            guard candidateDependencySupportedPlatforms.contains(configuredTargetPlatform.name) else {
                emitImplicitDependencyRejectionDiagnostic(.supportedPlatforms(candidateDependency: candidateDependency, candidateSupportedPlatforms: candidateDependencySupportedPlatforms, currentTarget: configuredTarget, currentSupportedPlatform: configuredTargetPlatform.name))
                return nil
            }
        }

        // implicitDependency must build with an SDK from the same platform as configuredTarget.
        guard candidateDependencySettings.platform?.identifier == configuredTargetPlatform?.identifier else {
            emitImplicitDependencyRejectionDiagnostic(.platform(candidateDependency: candidateDependency, candidatePlatform: candidateDependencySettings.platform, currentTarget: configuredTarget, currentPlatform: configuredTargetPlatform))
            return nil
        }

        // The architectures of implicitDependency must be a superset of those for configuredTarget.
        let candidateDependencyArchs = Set(candidateDependencySettings.globalScope.evaluate(BuiltinMacros.ARCHS))
        let configuredTargetArchs = Set(configuredTargetSettings.globalScope.evaluate(BuiltinMacros.ARCHS))
        guard candidateDependencyArchs.isSuperset(of: configuredTargetArchs) else {
            emitImplicitDependencyRejectionDiagnostic(.architectures(candidateDependency: candidateDependency, candidateArchitectures: candidateDependencyArchs, currentTarget: configuredTarget, currentArchitectures: configuredTargetArchs))
            return nil
        }

        // If implicitDependency specifies an SDK variant, it must be the same as the one specified by the configuredTarget, unless the candidate is zippered.
        let candidateIsZippered = candidateDependencySettings.globalScope.evaluate(BuiltinMacros.IS_ZIPPERED) && candidateDependencySettings.platform?.familyName == "macOS"
        let candidateSDKVariant = candidateDependencySettings.sdkVariant
        let configuredTargetSDKVariant = configuredTargetSettings.sdkVariant
        // Ignore `candidateIsZippered` for index build, index build enforces separate build directories between macOS and macCatalyst. Zippered frameworks are configured separately for both macOS and macCatalyst so we should just check if the SDK variants are compatible here.
        guard (candidateIsZippered && !buildRequest.enableIndexBuildArena) || candidateSDKVariant?.name == configuredTargetSDKVariant?.name else {
            emitImplicitDependencyRejectionDiagnostic(.sdkVariant(candidateDependency: candidateDependency, candidateSDKVariant: candidateSDKVariant?.name, currentTarget: configuredTarget, currentSDKVariant: configuredTargetSDKVariant?.name))
            return nil
        }

        // configuredTarget and implicitDependency must define the same implicit dependency domain.
        // It is an error for either of them to have an empty domain.  (But we're a little permissive about this and only error out if we otherwise find a match, because this check is at the end of the filter logic.)
        let configuredTargetImplicitDependencyDomain = configuredTargetSettings.globalScope.evaluate(BuiltinMacros.IMPLICIT_DEPENDENCY_DOMAIN)
        let candidateDependencyImplicitDependencyDomain = candidateDependencySettings.globalScope.evaluate(BuiltinMacros.IMPLICIT_DEPENDENCY_DOMAIN)
        guard !candidateDependencyImplicitDependencyDomain.isEmpty else {
            emitImplicitDependencyRejectionDiagnostic(.emptyImplicitDependencyDomain(candidateDependency: candidateDependency, currentTarget: configuredTarget, currentDomain: configuredTargetImplicitDependencyDomain))
            return nil
        }
        guard configuredTargetImplicitDependencyDomain == candidateDependencyImplicitDependencyDomain else {
            emitImplicitDependencyRejectionDiagnostic(.implicitDependencyDomain(candidateDependency: candidateDependency, candidateDomain: candidateDependencyImplicitDependencyDomain, currentTarget: configuredTarget, currentDomain: configuredTargetImplicitDependencyDomain))
            return nil
        }

        // Compute the effective imposed parameters based on the target-dependency pair we have.
        let effectiveImposedParameters = imposedParameters?.effectiveParameters(target: configuredTarget, dependency: ConfiguredTarget(parameters: candidateParameters, target: candidateDependencyTarget), dependencyResolver: resolver)

        // If we passed all the tests, then we can validate the candidate.
        return resolver.lookupConfiguredTarget(candidateDependencyTarget, parameters: candidateParameters, imposedParameters: effectiveImposedParameters)
    }

    /// Search for an implicit dependency by full product name.
    nonisolated private func implicitDependency(forProductName productName: String, from configuredTarget: ConfiguredTarget, imposedParameters: SpecializationParameters?, source: ImplicitDependencySource) async -> ConfiguredTarget? {
        let candidateConfiguredTargets = await (targetsByProductName[productName] ?? []).asyncMap { [self] candidateTarget -> ConfiguredTarget? in
            // Prefer overriding build parameters from the build request, if present.
            let buildParameters = resolver.buildParametersByTarget[candidateTarget] ?? configuredTarget.parameters

            // Get a configured target for this target, and use it as the implicit dependency.
            if let candidateConfiguredTarget = await implicitDependency(candidate: candidateTarget, parameters: buildParameters, isValidFor: configuredTarget, imposedParameters: imposedParameters, resolver: resolver) {
                return candidateConfiguredTarget
            }

            return nil
        }.compactMap { $0 }.sorted()

        emitAmbiguousImplicitDependencyWarningIfNeeded(for: configuredTarget, dependencies: candidateConfiguredTargets, from: source)

        return candidateConfiguredTargets.first
    }

    /// Search for an implicit dependency by product name stem.
    nonisolated private func implicitDependency(forProductNameStem stem: String, buildFilePath: Path, from configuredTarget: ConfiguredTarget, imposedParameters: SpecializationParameters?, source: ImplicitDependencySource) async -> ConfiguredTarget? {
        let candidateConfiguredTargets = await (targetsByProductNameStem[stem] ?? []).asyncMap { [self] candidateStandardTarget -> ConfiguredTarget? in
            // Prefer overriding build parameters from the build request, if present.
            let buildParameters = resolver.buildParametersByTarget[candidateStandardTarget] ?? configuredTarget.parameters

            // All we look for here for a potential match is whether the path of the build file contains the filename of the candidate target's product.  For example, if the candidate target is producing Foo.bundle, then the build file should have Foo.bundle in it somewhere.
            let buildFilePathComponents = buildFilePath.str.split(separator: Path.pathSeparator).map(String.init)

            // FIXME: This logic has the same problem as above w.r.t. non-constant product basenames: <rdar://problem/29410050> Swift Build doesn't support product references with non-constant basenames
            let candidateProductBasename = candidateStandardTarget.productReference.name

            guard buildFilePathComponents.contains(candidateProductBasename) else {
                return nil
            }

            // Get a configured target for this target, and use it as the implicit dependency.
            if let candidateConfiguredTarget = await implicitDependency(candidate: candidateStandardTarget, parameters: buildParameters, isValidFor: configuredTarget, imposedParameters: imposedParameters, resolver: resolver) {
                return candidateConfiguredTarget
            }

            return nil
        }.compactMap { $0 }.sorted()

        emitAmbiguousImplicitDependencyWarningIfNeeded(for: configuredTarget, dependencies: candidateConfiguredTargets, from: source)

        return candidateConfiguredTargets.first
    }

    /// Enumerates possible reasons why an implicit dependency was chosen as a dependency of the target.
    private enum ImplicitDependencySource {
        /// The dependency's product name was compatible with a `-framework` style linker flag used by the target.
        case frameworkLinkerFlag(flag: String, frameworkName: String, buildSetting: MacroDeclaration)

        /// The dependency's product name was compatible with a `-l` style linker flag used by the target.
        case libraryLinkerFlag(flag: String, libraryName: String, buildSetting: MacroDeclaration)

        /// The dependency's product name matched the basename of a build file in the target's build phases.
        case productReference(name: String, buildFile: BuildFile, buildPhase: BuildPhase)

        /// The dependency's product name matched the basename of a build file in the target's build phases.
        case productNameStem(_ stem: String, buildFile: BuildFile, buildPhase: BuildPhase)

        var valueForDisplay: String {
            switch self {
            case let .frameworkLinkerFlag(flag, frameworkName, _):
                return "linker flags '\(flag) \(frameworkName)'"
            case let .libraryLinkerFlag(flag, libraryName, _):
                return "linker flag '\(flag)\(libraryName)'"
            case let .productReference(productName, _, _):
                return "product reference '\(productName)'"
            case let .productNameStem(stem, _, _):
                return "product bundle executable reference '\(stem)'"
            }
        }
    }

    nonisolated private func emitAmbiguousImplicitDependencyWarningIfNeeded(for configuredTarget: ConfiguredTarget, dependencies candidateConfiguredTargets: [ConfiguredTarget], from source: ImplicitDependencySource) {
        if candidateConfiguredTargets.count > 1 {
            let location: Diagnostic.Location
            switch source {
            case let .frameworkLinkerFlag(_, _, buildSetting),
                 let .libraryLinkerFlag(_, _, buildSetting):
                location = .buildSetting(buildSetting)
            case let .productReference(_, buildFile, buildPhase),
                 let .productNameStem(_, buildFile, buildPhase):
                location = .buildFile(buildFileGUID: buildFile.guid, buildPhaseGUID: buildPhase.guid, targetGUID: configuredTarget.target.guid)
            }

            delegate.emit(.overrideTarget(configuredTarget), SWBUtil.Diagnostic(behavior: .warning, location: location, data: DiagnosticData("Multiple targets match implicit dependency for \(source.valueForDisplay). Consider adding an explicit dependency on the intended target to resolve this ambiguity.", component: .targetIntegrity), childDiagnostics: candidateConfiguredTargets.map({ dependency -> Diagnostic in
                let project = workspaceContext.workspace.project(for: dependency.target)
                return Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Target '\(dependency.target.name)' (in project '\(project.name)')"))
            })))
        }
    }

    nonisolated private func emitImplicitDependencyRejectionDiagnostic(_ rejectionReason: ImplicitDependencyRejectionReason) {
        guard workspaceContext.userPreferences.enableDebugActivityLogs else {
            return
        }

        switch rejectionReason {
        case let .supportedPlatforms(candidateDependency, candidateSupportedPlatforms, currentTarget, currentSupportedPlatform):
            delegate.emit(.overrideTarget(currentTarget), SWBUtil.Diagnostic(behavior: .note, location: .buildSetting(BuiltinMacros.SUPPORTED_PLATFORMS), data: DiagnosticData("\(candidateDependency.target.name) rejected as an implicit dependency because its SUPPORTED_PLATFORMS '\(candidateSupportedPlatforms.sorted().joined(separator: " "))' does not contain this target's platform '\(currentSupportedPlatform)'.")))
        case let .platform(candidateDependency, candidatePlatform, currentTarget, currentPlatform):
            delegate.emit(.overrideTarget(currentTarget), SWBUtil.Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("\(candidateDependency.target.name) rejected as an implicit dependency because its platform identifier '\(candidatePlatform?.identifier ?? "")' is not equal to this target's platform identifier '\(currentPlatform?.identifier ?? "")'.")))
        case let .architectures(candidateDependency, candidateArchitectures, currentTarget, currentArchitectures):
            delegate.emit(.overrideTarget(currentTarget), SWBUtil.Diagnostic(behavior: .note, location: .buildSetting(BuiltinMacros.ARCHS), data: DiagnosticData("\(candidateDependency.target.name) rejected as an implicit dependency because its ARCHS '\(candidateArchitectures.sorted().joined(separator: " "))' are not a superset of this target's ARCHS '\(currentArchitectures.sorted().joined(separator: " "))'.")))
        case let .sdkVariant(candidateDependency, candidateSDKVariant, currentTarget, currentSDKVariant):
            delegate.emit(.overrideTarget(currentTarget), SWBUtil.Diagnostic(behavior: .note, location: .buildSetting(BuiltinMacros.SDK_VARIANT), data: DiagnosticData("\(candidateDependency.target.name) rejected as an implicit dependency because its SDK_VARIANT '\(candidateSDKVariant ?? "<nil>")' is not equal to this target's SDK_VARIANT '\(currentSDKVariant ?? "<nil>")' and it is not zippered.")))
        case .implicitDependencyDomain(candidateDependency: let candidateDependency, candidateDomain: let candidateDomain, currentTarget: let currentTarget, currentDomain: let currentDomain):
            delegate.emit(.overrideTarget(currentTarget), SWBUtil.Diagnostic(behavior: .note, location: .buildSetting(BuiltinMacros.IMPLICIT_DEPENDENCY_DOMAIN), data: DiagnosticData("\(candidateDependency.target.name) rejected as an implicit dependency because its IMPLICIT_DEPENDENCY_DOMAIN '\(candidateDomain)' is not equal to this target's domain '\(currentDomain)'.")))
        case .emptyImplicitDependencyDomain(candidateDependency: let candidateDependency, currentTarget: let currentTarget, currentDomain: let currentDomain):
            delegate.emit(.overrideTarget(currentTarget), SWBUtil.Diagnostic(behavior: .note, location: .buildSetting(BuiltinMacros.IMPLICIT_DEPENDENCY_DOMAIN), data: DiagnosticData("\(candidateDependency.target.name) rejected as an implicit dependency because its IMPLICIT_DEPENDENCY_DOMAIN is empty (trying to match this target's domain '\(currentDomain)').")))
        }
    }
}

/// The reason why a candidate target was rejected as an implicit dependency.
private enum ImplicitDependencyRejectionReason {
    /// The target was rejected as an implicit dependency because its `SUPPORTED_PLATFORMS` does not contain the current target's platform.
    case supportedPlatforms(candidateDependency: ConfiguredTarget, candidateSupportedPlatforms: [String], currentTarget: ConfiguredTarget, currentSupportedPlatform: String)

    /// The target was rejected as an implicit dependency because its platform identifier is not equal to the current target's platform identifier.
    case platform(candidateDependency: ConfiguredTarget, candidatePlatform: Platform?, currentTarget: ConfiguredTarget, currentPlatform: Platform?)

    /// The target was rejected as an implicit dependency because its `ARCHS` are not a superset of the current target's `ARCHS`.
    case architectures(candidateDependency: ConfiguredTarget, candidateArchitectures: Set<String>, currentTarget: ConfiguredTarget, currentArchitectures: Set<String>)

    /// The target was rejected as an implicit dependency because its `SDK_VARIANT` is not equal to the current target's `SDK_VARIANT` and it is not zippered.
    case sdkVariant(candidateDependency: ConfiguredTarget, candidateSDKVariant: String?, currentTarget: ConfiguredTarget, currentSDKVariant: String?)

    /// The target was rejected as an implicit dependency because its `IMPLICIT_DEPENDENCY_DOMAIN` does not match that of the current target.
    case implicitDependencyDomain(candidateDependency: ConfiguredTarget, candidateDomain: String, currentTarget: ConfiguredTarget, currentDomain: String)

    /// The target was rejected as an implicit dependency because its `IMPLICIT_DEPENDENCY_DOMAIN` is empty.
    case emptyImplicitDependencyDomain(candidateDependency: ConfiguredTarget, currentTarget: ConfiguredTarget, currentDomain: String)
}

fileprivate struct LinkageDependencyBuildFileFilteringContext: BuildFileFilteringContext {
    var excludedSourceFileNames: [String]
    var includedSourceFileNames: [String]
    var currentPlatformFilter: SWBCore.PlatformFilter?

    init(scope: MacroEvaluationScope) {
        self.excludedSourceFileNames = scope.evaluate(BuiltinMacros.EXCLUDED_SOURCE_FILE_NAMES)
        self.includedSourceFileNames = scope.evaluate(BuiltinMacros.INCLUDED_SOURCE_FILE_NAMES)
        self.currentPlatformFilter = PlatformFilter(scope)
    }
}

private extension Path {
    /// List of suffixes for library file types which can be linked by the linker.
    ///
    /// We're listing library suffixes in this order, since this follows the ld64 and general Unix-like OS linker search order rules.
    static let libraryExtensions = ["dylib", "tbd", "so", "a"]

    /// Private specialized method which returns the stem of the filename of the receiver.  Returns nil if a suitable stem could not be determined.
    var stem: String? {
        return basenameWithoutSuffix.nilIfEmpty
    }
}

fileprivate actor LinkageDependencies {
    var path: OrderedSet<ConfiguredTarget> = []
}
