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
public import struct SWBProtocol.TargetDescription
public import struct SWBProtocol.TargetDependencyRelationship
import SWBMacro

/// This enumeration is used to describe the reason a dependency exists between a target and the target that depends on it, for reporting purposes.
public enum TargetDependencyReason: Sendable {
    /// The upstream target has an dependency on the target, in the 'Dependencies' pseudo-phase.
    case explicit
    /// The upstream target has an implicit dependency on the target due a build file being in a build phase of the upstream target.
    /// - parameter filename: The name of the file used to find this linkage. This is used for diagnostics. While this could be derived from the `reference` parameter, doing so is cumbersome so it's easier to just capture it here.
    /// - parameter buildableItem: The `BuildFile.BuildableItem` used to find this linkage.
    /// - parameter buildPhase: The name of the build phase used to find this linkage. This is used for diagnostics.
    case implicitBuildPhaseLinkage(filename: String, buildableItem: BuildFile.BuildableItem, buildPhase: String)
    /// The upstream target has an implicit dependency on the target due to options being passed via a build setting.
    case implicitBuildSettingLinkage(settingName: String, options: [String])
    /// The upstream target has a transitive dependency on the target via target(s) which were removed from the build graph.
    case impliedByTransitiveDependencyViaRemovedTargets(intermediateTargetName: String)
}

extension TargetDependencyReason: SerializableCodable {
}

/// The resolved dependency of one target on another, this class represents information about the depended-on target (i.e., why the depending target depends on it).
///
/// Note that while it is theoretically possible for a target to depend on another target for multiple reasons, we only capture the most significant reason in this structure (where "most significant" means "the first reason the algorithm found for the dependency").  Consequently, only the target, not the dependency reason, is used for hashing and equality of this structure.
public struct ResolvedTargetDependency: Hashable, Encodable, Sendable {
    public let target: ConfiguredTarget
    public let reason: TargetDependencyReason

    public static func == (lhs: ResolvedTargetDependency, rhs: ResolvedTargetDependency) -> Bool {
        return lhs.target == rhs.target
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(target)
    }
}

extension ResolvedTargetDependency: Serializable {
    public func serialize<T>(to serializer: T) where T : SWBUtil.Serializer {
        serializer.serializeAggregate(2) {
            serializer.serialize(target)
            serializer.serialize(reason)
        }
    }

    public init(from deserializer: any SWBUtil.Deserializer) throws {
        try deserializer.beginAggregate(2)
        target = try deserializer.deserialize()
        reason = try deserializer.deserialize()
    }
}

extension ResolvedTargetDependency {
    public func replacingTarget(_ target: Target) -> ResolvedTargetDependency {
        return ResolvedTargetDependency(target: self.target.replacingTarget(target), reason: reason)
    }
}

/// A completely resolved graph of configured targets for use in a build.
public struct TargetBuildGraph: TargetGraph, Sendable {
    /// The reason for constructing a build graph. Relevant for whether to stop early or continue.
    public enum Purpose: Sendable {
        case build
        case dependencyGraph
    }

    /// The workspace context this graph is for.
    public let workspaceContext: WorkspaceContext

    /// The build request the graph is for.
    public let buildRequest: BuildRequest

    public let buildRequestContext: BuildRequestContext

    /// The complete list of configured targets, in topological order. That is, each target will be included in the array only after all of the targets that it depends on (unless there is a target dependency cycle).
    public let allTargets: OrderedSet<ConfiguredTarget>

    /// The mapping containing the immediate predecessors of each configured target, including implicit dependencies if enabled.
    private let targetDependencies: [ConfiguredTarget: [ResolvedTargetDependency]]

    /// A mapping for each target in the dependency closure, which itself contains a mapping of buildable items for each build file in its Frameworks build phase to the configured target that produces it.
    /// - remark: This could potentially be enhanced to also include linkages via `OTHER_LDFLAGS`, but we'd have to encode the linking entity rather than just using `BuildFile.BuildableItem`.
    private let targetsToLinkedReferencesToProducingTargets: [ConfiguredTarget: [BuildFile.BuildableItem: ResolvedTargetDependency]]

    /// List of targets that were requested to build dynamically by the client.
    public let dynamicallyBuildingTargets: Set<Target>

    /// Whether or not there are any Swift packages in the build graph.
    public let containsSwiftPackages: Bool

    // FIXME: Report cycles via the delegate.
    //
    /// Construct a new graph for the given build request.
    ///
    ///
    /// The result closure guarantees that all targets a target depends on appear in the returned array before that target.  Any detected dependency cycles will be broken.
    public init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: any TargetDependencyResolverDelegate, purpose: Purpose = .build) async {
        let (allTargets, targetDependencies, targetsToLinkedReferencesToProducingTargets, dynamicallyBuildingTargets) =
        await MacroNamespace.withExpressionInterningEnabled {
            await buildRequestContext.keepAliveSettingsCache {
                let resolver = TargetDependencyResolver(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate, purpose: purpose)
                return await resolver.computeGraph()
            }
        }
        self.init(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, allTargets: allTargets, targetDependencies: targetDependencies, targetsToLinkedReferencesToProducingTargets: targetsToLinkedReferencesToProducingTargets, dynamicallyBuildingTargets: dynamicallyBuildingTargets)
    }

    public init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, allTargets: OrderedSet<ConfiguredTarget>, targetDependencies: [ConfiguredTarget: [ResolvedTargetDependency]], targetsToLinkedReferencesToProducingTargets: [ConfiguredTarget: [BuildFile.BuildableItem: ResolvedTargetDependency]], dynamicallyBuildingTargets: Set<Target>) {
        self.workspaceContext = workspaceContext
        self.buildRequest = buildRequest
        self.buildRequestContext = buildRequestContext
        self.allTargets = allTargets
        self.targetDependencies = targetDependencies
        self.targetsToLinkedReferencesToProducingTargets = targetsToLinkedReferencesToProducingTargets
        self.dynamicallyBuildingTargets = dynamicallyBuildingTargets
        self.containsSwiftPackages = allTargets.contains(where: { workspaceContext.workspace.project(for: $0.target).isPackage })
    }

    /// Get the dependencies of a target in the graph.
    public func dependencies(of target: ConfiguredTarget) -> [ConfiguredTarget] {
        assert(allTargets.contains(target))
        return targetDependencies[target]?.map({ $0.target }) ?? []
    }

    /// Get the dependencies of a target in the graph, with supporting information about the nature of the dependency. If the caller only needs the target and not the other information, then use `dependencies(of:)` instead.
    public func resolvedDependencies(of target: ConfiguredTarget) -> [ResolvedTargetDependency] {
        assert(allTargets.contains(target))
        return targetDependencies[target] ?? []
    }

    private let _targetDependenciesByGuid: LazyCache<TargetBuildGraph, [TargetDependencyRelationship]> = LazyCache { instance in
        var results: [TargetDependencyRelationship] = []
        for (target, deps) in instance.targetDependencies {
            let targetID = target.guid
            let target = TargetDescription(name: target.target.name, guid: targetID.stringValue)
            let dependencies = deps.map { TargetDescription(name: $0.target.target.name, guid: $0.target.guid.stringValue) }
            results.append(TargetDependencyRelationship(target, dependencies: dependencies))
        }
        // We sort the dependencies by guid to make it deterministic
        return results.sorted(by: \.target.guid)
    }

    /// This array contains a sorted representation of dependencies between all targets.
    /// It's sorted by the guid of the target to be deterministic across executions.
    public var targetDependenciesByGuid: [TargetDependencyRelationship] {
        return _targetDependenciesByGuid.getValue(self)
    }

    /// Return the `ConfiguredTarget` which produces the given `buildableItem` for the given `ConfiguredTarget`.
    public func producingTarget(for buildableItem: BuildFile.BuildableItem, in target: ConfiguredTarget) -> ResolvedTargetDependency? {
        return targetsToLinkedReferencesToProducingTargets[target]?[buildableItem]
    }

    /// Computes and returns an appropriate diagnostic indicating whether the build is using dependency-based or manual target build order.
    public var targetBuildOrderDiagnostic: Diagnostic {
        if targetsBuildInParallel {
            return Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Building targets in dependency order"))
        } else {
            let behavior: Diagnostic.Behavior
            let suffix: String
            let isError = allTargets.contains(where: { buildRequestContext.getCachedSettings($0.parameters, target: $0.target).globalScope.evaluate(BuiltinMacros._OBSOLETE_MANUAL_BUILD_ORDER) })
            if isError {
                behavior = .error
                suffix = "prohibited"
            } else {
                let disableWarning = allTargets.contains(where: { buildRequestContext.getCachedSettings($0.parameters, target: $0.target).globalScope.evaluate(BuiltinMacros.DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING) })
                behavior = disableWarning ? .note : .warning

                if buildRequest.schemeCommand != nil {
                    suffix = "deprecated - choose Dependency Order in scheme settings instead, or set \(BuiltinMacros.DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING.name) in any of the targets in the current scheme to suppress this warning"
                } else {
                    suffix = "deprecated - check \"Parallelize build for command-line builds\" in the project editor, or set \(BuiltinMacros.DISABLE_MANUAL_TARGET_ORDER_BUILD_WARNING.name) in any of the targets in the current build to suppress this warning"
                }
            }
            return Diagnostic(behavior: behavior, location: .unknown, data: DiagnosticData("Building targets in manual order is \(suffix)"))
        }
    }

    /// Computes and returns a hierarchical diagnostic representing the build graph.
    public var dependencyGraphDiagnostic: Diagnostic {
        return _dependencyGraphDiagnostic.getValue(self)
    }
    private var _dependencyGraphDiagnostic: LazyCache<TargetBuildGraph, Diagnostic> = LazyCache { instance in
        // .allTargets is sorted in topological order. Reverse this so that targets appear before their dependencies in the list.
        return Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Target dependency graph (\(instance.allTargets.count) target" + (instance.allTargets.count > 1 ? "s" : "") + ")"), childDiagnostics: instance.allTargets.reversed().map { configuredTarget in
            let project = instance.workspaceContext.workspace.project(for: configuredTarget.target)
            let resolvedDependencies = instance.resolvedDependencies(of: configuredTarget)
            let parts = [
                "Target '\(configuredTarget.target.name)' in project '\(project.name)'",
                instance.buildRequest.shouldSkipExecution(target: configuredTarget.target) ? " (skipped due to 'Skip Dependencies' scheme option)" : "",
                resolvedDependencies.isEmpty ? " (no dependencies)" : "",
            ]
            return Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData(parts.joined(separator: "")), childDiagnostics: resolvedDependencies.map { dependency in
                let project = instance.workspaceContext.workspace.project(for: dependency.target.target)
                let dependencyDescription = "target '\(dependency.target.target.name)' in project '\(project.name)'"
                let dependencyString: String
                switch dependency.reason {
                case .explicit:
                    dependencyString = "Explicit dependency on \(dependencyDescription)"
                case .implicitBuildPhaseLinkage(filename: let filename, buildableItem: _, buildPhase: let buildPhase):
                    dependencyString = "Implicit dependency on \(dependencyDescription) via file '\(filename)' in build phase '\(buildPhase)'"
                case .implicitBuildSettingLinkage(settingName: let settingName, options: let options):
                    dependencyString = "Implicit dependency on \(dependencyDescription) via options '\(options.joined(separator: " "))' in build setting '\(settingName)'"
                case .impliedByTransitiveDependencyViaRemovedTargets(let intermediateTargetName):
                    dependencyString = "Dependency on \(dependencyDescription) via transitive dependency through '\(intermediateTargetName)'"
                }
                return Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("➜ " + dependencyString))
            })
        })
    }
}

extension TargetBuildGraph {
    /// Whether the target build graph is _actually_ using parallel target builds, which may be different from the value in the request. This is the funnel point for additional logic.
    public var targetsBuildInParallel: Bool {
        // If there's only one target in the graph, parallel vs non-parallel is a no-op.
        if allTargets.count <= 1 {
            return true
        }

        // If there's only two targets in the graph, and the first target is an aggregate target which depends on the second target and has no build phases, parallel vs non-parallel is a no-op.
        if allTargets.count == 2 {
            switch (allTargets[0].target, allTargets[1].target) {
            case (let aggregate as AggregateTarget, let other), (let other, let aggregate as AggregateTarget):
                if aggregate.buildPhases.isEmpty && aggregate.dependencies.contains(where: { $0.guid == other.guid }) {
                    return true
                }
            default:
                break
            }
        }

        return buildRequest.useParallelTargets
    }
}

/// Cached information on a target, used as part of resolution.
private final class DiscoveredTargetInfo {
    /// The ordered list of immediate (non-product) dependencies.  This includes implicit dependencies.
    let immediateDependencies: [ResolvedTargetDependency]

    /// The list of package product target dependencies.
    let packageProductDependencies: [PackageProductTarget]

    init(immediateDependencies: [ResolvedTargetDependency], packageProductDependencies: [PackageProductTarget]) {
        self.immediateDependencies = immediateDependencies
        self.packageProductDependencies = packageProductDependencies
    }
}

fileprivate extension TargetDependencyResolver {
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

/// Builder-like class for resolving target dependencies.
@_spi(Testing) public actor TargetDependencyResolver {
    /// The set of visited discovered targets.
    private var visitedDiscoveredTargets = Set<ConfiguredTarget>()

    /// The set of targets which have been discovered.
    private var discoveredTargets = [ConfiguredTarget: DiscoveredTargetInfo]()

    private let linkageDependencyResolver: LinkageDependencyResolver?

    /// The immediate dependencies of configured targets.  These will include implicit dependencies only if the build request instructs that they should be used.
    ///
    /// This property will be nil until the resolver's dependency closure has been computed.
    private var immediateDependenciesByConfiguredTarget: [ConfiguredTarget: OrderedSet<ResolvedTargetDependency>]? = nil

    @_spi(Testing) public let resolver: DependencyResolver

    private let purpose: TargetBuildGraph.Purpose

    public init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: any TargetDependencyResolverDelegate, purpose: TargetBuildGraph.Purpose = .build) {
        // Go through all targets in the workspace and build the indexes we need to look up implicit dependencies.
        // At this point the only parameters we have are the ones from the build request, so if the values we put in the indices could differ for other parameters (e.g., for different platforms) then we won't account for that here.  However, I believe Xcode will have the same problem.
        if buildRequest.useImplicitDependencies {
            linkageDependencyResolver = LinkageDependencyResolver(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
        } else {
            linkageDependencyResolver = nil
        }

        self.resolver = DependencyResolver(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
        self.purpose = purpose
    }

    /// Computes the dependency closure of configured targets for the resolver's build request.
    ///
    /// The result closure guarantees that all targets a target depends on appear in the returned array before that target.  Any detected dependency cycles will be broken.
    fileprivate func computeGraph() async -> (allTargets: OrderedSet<ConfiguredTarget>, targetDependencies: [ConfiguredTarget: [ResolvedTargetDependency]], targetsToLinkedReferencesToProducingTargets: [ConfiguredTarget: [BuildFile.BuildableItem: ResolvedTargetDependency]], dynamicallyBuildingTargets: Set<Target>) {
        // For generating assembly or preprocessor output, we limit the build to the requested targets.
        switch buildRequest.buildCommand {
        case .generateAssemblyCode, .generatePreprocessedFile:
            return await (OrderedSet<ConfiguredTarget>(buildRequest.buildTargets.asyncMap { info in await resolver.lookupConfiguredTarget(info.target, parameters: info.parameters, imposedParameters: resolver.defaultImposedParameters) }), [:], [:], [])
        default:
            break
        }

        // First, perform discovery of all of the targets in the build, and configure them with specialization parameters.
        //
        // This is an explicit pre-pass which satisfies two goals: it allows us to unique specializations more simply, and it allows us to separate the expensive computation (the computation of build settings during implicit dependencies) from the order dependent logic, so we can run it in parallel.
        let topLevelTargetsToDiscover = await resolver.concurrentMap(maximumParallelism: 100, buildRequest.buildTargets) { [resolver] in
            await resolver.lookupTopLevelConfiguredTarget($0)
        }
        if !topLevelTargetsToDiscover.isEmpty {
            await resolver.concurrentPerform(iterations: topLevelTargetsToDiscover.count, maximumParallelism: 100) { [self] i in
                if Task.isCancelled { return }
                let configuredTarget = topLevelTargetsToDiscover[i]
                let imposedParameters = resolver.specializationParameters(configuredTarget, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
                await discoverInfo(for: configuredTarget, imposedParameters: imposedParameters)
            }
        }

        // Go through the build requests's top-level configured targets.  For each one we ask it to add its dependencies and then itself to the dependency closure.
        immediateDependenciesByConfiguredTarget = [:]
        var allTargets = OrderedSet<ConfiguredTarget>()
        for topLevelConfiguredTarget in topLevelTargetsToDiscover {
            if Task.isCancelled { break }

            var dependencyPath = OrderedSet<ConfiguredTarget>()
            await self.addDependencies(forConfiguredTarget: topLevelConfiguredTarget, toDependencyClosure: &allTargets, dependencyPath: &dependencyPath)
        }

        for target in allTargets {
            // we don't want to stop too early (when we are computing the dependency graph) because this prevents us from getting better diagnostics later on, when it matters.
            if !target.target.approvedByUser, purpose != .dependencyGraph {
                // FIXME: This should be a target-level diagnostic once rdar://108290784 (Target-level diagnostics are possibly not working for failures during planning) has been fixed.
                // Downgrade this to a warning when indexing to support functionality that doesn't require expanding macros. Execution-time checks will ensure the macro is not built until approved by the user.
                let behavior = buildRequest.enableIndexBuildArena ? Diagnostic.Behavior.warning : .error
                delegate.emit(SWBUtil.Diagnostic(behavior: behavior, location: .path(workspaceContext.workspace.project(for: target.target).xcodeprojPath, fileLocation: .object(identifier: target.target.guid)), data: DiagnosticData("Target '\(target.target.name)' must be enabled before it can be used.", component: .targetMissingUserApproval)))
            }
        }

        // Apply the superimposed overrides discovered while creating the dependency closure.
        // FIXME: We could simplify all of this if we refactor the discovery logic to have a single data structure as the source of truth, and construct the other data structures from it after performing this postprocessing.
        var newAllTargets = OrderedSet<ConfiguredTarget>()
        var configuredTargetsToReplace = [ConfiguredTarget: ConfiguredTarget]()
        // First build up a new dependency closure in allTargets.  Since this is a set, this will deduplicate any ConfiguredTargets which end up identical after the global overrides are applied..
        for configuredTarget in allTargets {
            if Task.isCancelled { break }
            if let allSuperimposedSpecializations = await resolver.superimposedSpecializations[configuredTarget.target] {
                var overridesToApply = [String: String]()
                let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
                for specialization in allSuperimposedSpecializations {
                    if let superimposedProperties = specialization.superimposedProperties, specialization.isCompatible(with: configuredTarget, settings: settings, workspaceContext: workspaceContext) {
                        // At this point we have some properties to apply to a target which is compatible with our specialization, so we add them to the overrides to apply.  This unifies overrides from potentially multiple specializations.
                        overridesToApply.addContents(of: superimposedProperties.overrides(configuredTarget, settings))
                    }
                }
                // If we have any overrides to apply, then do so, add the new ConfiguredTarget to the list, record that we should replace it elsewhere, and continue.
                if !overridesToApply.isEmpty {
                    let newParameters = configuredTarget.parameters.mergingOverrides(overridesToApply)
                    let newConfiguredTarget = ConfiguredTarget(parameters: newParameters, target: configuredTarget.target)
                    newAllTargets.append(newConfiguredTarget)
                    configuredTargetsToReplace[configuredTarget] = newConfiguredTarget
                    continue
                }
            }
            // If we didn't apply any overrides, then add the original ConfiguredTarget.
            newAllTargets.append(configuredTarget)
        }
        allTargets = newAllTargets
        // Now replace configured targets in other structures.  Again, since these structures use dictionaries and sets, this will deduplicate any items in those structures.
        if !configuredTargetsToReplace.isEmpty {
            var newConfiguredTargetsByTarget = [Target: Set<ConfiguredTarget>]()
            for (target, configuredTargets) in await resolver.configuredTargetsByTarget {
                var newConfiguredTargets = Set<ConfiguredTarget>()
                for configuredTarget in configuredTargets {
                    if let newConfiguredTarget = configuredTargetsToReplace[configuredTarget] {
                        newConfiguredTargets.insert(newConfiguredTarget)
                    }
                    else {
                        newConfiguredTargets.insert(configuredTarget)
                    }
                }
                newConfiguredTargetsByTarget[target] = newConfiguredTargets
            }
            await resolver.updateConfiguredTargetsByTarget { $0 = newConfiguredTargetsByTarget }

            var newImmediateDependenciesByConfiguredTarget = [ConfiguredTarget: OrderedSet<ResolvedTargetDependency>]()
            for (configuredTarget, dependencies) in immediateDependenciesByConfiguredTarget! {
                // This is tricky:  We need to *both* replace ConfiguredTargets in the ResolvedTargetDependency list, *and* replace the ConfiguredTarget key, which might mean combining the dependencies of multiple targets.  This second part is potentially lossy, in that we could lose proper ordering of the merged dependency lists.  But I don't see a way to resolve this, other than fundamentally restructuring all of the dependency logic.
                let newConfiguredTarget = configuredTargetsToReplace[configuredTarget] ?? configuredTarget
                var newDependencies = newImmediateDependenciesByConfiguredTarget[newConfiguredTarget] ?? OrderedSet<ResolvedTargetDependency>()
                for dependency in dependencies {
                    if let newDependencyTarget = configuredTargetsToReplace[dependency.target] {
                        let newDependency = ResolvedTargetDependency(target: newDependencyTarget, reason: dependency.reason)
                        newDependencies.append(newDependency)
                    }
                    else {
                        newDependencies.append(dependency)
                    }
                }
                newImmediateDependenciesByConfiguredTarget[newConfiguredTarget] = newDependencies
            }
            immediateDependenciesByConfiguredTarget = newImmediateDependenciesByConfiguredTarget
        }

        // FIXME: This is a bit gross, but we have to reduce the number of specializations in case there are both internal and public specializations for the same platform, because they would both be building in the same arena. Unfortunately, we cannot do this while creating specializations because that step is running in parallel. In the future, we will likely have to generalize this a bit more for other cases where we need to narrow down the number of specializations based on some criteria.
        for (_, configuredTargets) in await resolver.configuredTargetsByTarget {
            if Task.isCancelled { break }
            if configuredTargets.count == 1 { continue }

            // Order all configured targets per platform.
            var configuredTargetsPerPlatform = [Ref<Platform>?: [ConfiguredTarget]]()
            var settingsForConfiguredTarget = [ConfiguredTarget: Settings]()
            for ct in configuredTargets {
                let settings = buildRequestContext.getCachedSettings(ct.parameters, target: ct.target)
                settingsForConfiguredTarget[ct] = settings
                let platform = settings.platform.map({ Ref($0) })
                if let configuredTargets = configuredTargetsPerPlatform[platform] {
                    configuredTargetsPerPlatform[platform] = configuredTargets + [ct]
                } else {
                    configuredTargetsPerPlatform[platform] = [ct]
                }
            }

            // Find cases where we have configured targets with unsuffixed and suffixed SDKs.
            _ = await configuredTargetsPerPlatform.asyncMap { platform, configuredTargets in
                if configuredTargets.count == 1 { return }

                // Only handle cases where there is exactly one specialization for a suffixed SDK.
                let targetsUsingSuffixedSDK = configuredTargets.filter { settingsForConfiguredTarget[$0]?.sdk?.canonicalNameSuffix?.nilIfEmpty != nil }
                if let suffixedTarget = targetsUsingSuffixedSDK.first, targetsUsingSuffixedSDK.count == 1 {
                    // Compute specialization parameters without opinion about the suffixed SDK.
                    let fullParameters = resolver.specializationParameters(suffixedTarget, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
                    let parameters = SpecializationParameters(source: .target(name: suffixedTarget.target.name), platform: fullParameters.platform, sdkVariant: fullParameters.sdkVariant, supportedPlatforms: fullParameters.supportedPlatforms, toolchain: nil, canonicalNameSuffix: nil)

                    // Check if any of the unsuffixed targets are incompatible with parameters other than whether the suffixed SDK is being used.
                    let incompatibleTargets = configuredTargets.filter {
                        return $0 != suffixedTarget && !parameters.isCompatible(with: $0, settings: settingsForConfiguredTarget[$0]!, workspaceContext: workspaceContext)
                    }

                    // If no targets are incompatible, remove the unnecessary targets from the build graph.
                    if incompatibleTargets.count == 0 {
                        for configuredTarget in configuredTargets {
                            if let index = allTargets.firstIndex(of: configuredTarget), configuredTarget != suffixedTarget {
                                allTargets.remove(at: index)

                                // Fix up any existing references to the removed configured target.
                                for (dependee, dependencies) in immediateDependenciesByConfiguredTarget! {
                                    if let index = dependencies.firstIndex(where: { $0.target == configuredTarget }) {
                                        var mutableDependencies = dependencies
                                        mutableDependencies.insert(ResolvedTargetDependency(target: suffixedTarget, reason: mutableDependencies[index].reason), at: index)
                                        mutableDependencies.remove(at: index + 1)
                                        immediateDependenciesByConfiguredTarget![dependee] = mutableDependencies
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Construct the map of targets to their immediate resolved dependencies.
        var targetDependencies = [ConfiguredTarget: [ResolvedTargetDependency]]()
        var seenTargetIDs = [ConfiguredTarget.GUID: [ConfiguredTarget]]()
        for (configuredTarget, dependencies) in immediateDependenciesByConfiguredTarget! {
            seenTargetIDs[configuredTarget.guid, default: []].append(configuredTarget)
            targetDependencies[configuredTarget] = dependencies.elements
        }

        // Construct a map, for each target, of buildable items in that target's Frameworks build phase to the target in the graph which produces it.
        // For items we matched using an implicit dependency, this is straightforward since we have the buildable item in the ResolvedTargetDependency's TargetDependencyReason.
        // For other items, we need to match them against the product of the target's explicit dependencies.  This is the nasty part which sort of replicates logic in the LinkageDependencyResolver, but we can't just piggy-back on that logic because not all targets have implicit dependencies enabled.
        var targetsToLinkedReferencesToProducingTargets = [ConfiguredTarget: [BuildFile.BuildableItem: ResolvedTargetDependency]]()
        for configuredTarget in allTargets {
            if Task.isCancelled { break }
            guard let target = configuredTarget.target as? BuildPhaseTarget else {
                continue
            }
            let configuredTargetSettings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: target)
            let currentPlatformFilter = PlatformFilter(configuredTargetSettings.globalScope)
            for buildPhase in target.buildPhases {
                switch buildPhase {
                case let frameworksBuildPhase as FrameworksBuildPhase:
                    // Go through the build files.
                    for buildFile in frameworksBuildPhase.buildFiles where currentPlatformFilter.matches(buildFile.platformFilters) {
                        var foundProducingTarget = false
                        var buildFilePath: Path? = nil

                        // Look for an immediate dependency which produces this build file.
                        for dependency in targetDependencies[configuredTarget] ?? [] {
                            switch dependency.reason {
                            case .explicit:
                                if let productName = (dependency.target.target as? StandardTarget)?.productReference.name {
                                    if buildFilePath == nil {
                                        // This might be expensive, so we try to evaluate it only once per build file.
                                        buildFilePath = resolver.resolveBuildFilePath(buildFile, settings: configuredTargetSettings, dynamicallyBuildingTargets: resolver.dynamicallyBuildingTargets)
                                    }
                                    if let buildFilePath, buildFilePath.basename == productName {
                                        targetsToLinkedReferencesToProducingTargets[configuredTarget, default: [:]][buildFile.buildableItem] = dependency
                                        foundProducingTarget = true
                                    }
                                }
                            case .implicitBuildPhaseLinkage(filename: _, buildableItem: let buildableItem, buildPhase: _) where buildableItem == buildFile.buildableItem:
                                targetsToLinkedReferencesToProducingTargets[configuredTarget, default: [:]][buildFile.buildableItem] = dependency
                                foundProducingTarget = true
                            default:
                                // <rdar://119009960>: We could also track this for other dependency reasons, such as linkages from build settings, but at present we don't need that information.
                                break
                            }
                            if foundProducingTarget {
                                break
                            }
                        }
                    }
                default:
                    break
                }
            }
        }

        // If we find multiple configured targets with the same target GUID, then something has gone very wrong.  It means we think there are multiple targets which have the same target-level task identifier, as this ID is synthesized in ConfiguredTarget.guid.  Emit a build error asking the user to file a Radar.
        for targetID in seenTargetIDs.keys.sorted() {
            if let configuredTargets = seenTargetIDs[targetID], configuredTargets.count > 1 {
                for configuredTarget in configuredTargets {
                    delegate.emit(.overrideTarget(configuredTarget), SWBUtil.Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Internal error: Multiple targets in the build graph have the target ID '\(targetID)'. Please file a bug report.", component: .default)))
                }
            }
        }

        if buildRequest.skipDependencies && buildRequestContext.getCachedSettings(buildRequest.parameters).globalScope.evaluate(BuiltinMacros.DIAGNOSE_SKIP_DEPENDENCIES_USAGE) {
            delegate.emit(.init(behavior: .error, location: .unknown, data: .init("The 'Skip Dependencies' option is deprecated and can no longer be used.")))
        }

        // Apply the requested dependency scope to the graph.
        switch buildRequest.dependencyScope {
        case .workspace:
            // If dependencies are scoped to the workspace, no pruning is required.
            break
        case .buildRequest:
            if buildRequest.skipDependencies {
                delegate.emit(.init(behavior: .error, location: .unknown, data: .init("The 'Skip Dependencies' option is deprecated and cannot be combined with dependency scopes.")))
            }
            // First, partition the targets into those we're keeping, and those we're removing.
            var keptTargets: OrderedSet<ConfiguredTarget> = []
            var removedTargets: OrderedSet<ConfiguredTarget> = []
            let requestedTargetGUIDs = Set(buildRequest.buildTargets.map(\.target.guid))
            var extraRequestedTargetGUIDs: Set<String> = []
            var potentialExtraRequestedPackageTargetGUIDs: Set<String> = []
            for configuredTarget in allTargets.reversed() {
                if requestedTargetGUIDs.contains(configuredTarget.target.guid) {
                    keptTargets.insert(configuredTarget, at: 0)
                    let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
                    if settings.globalScope.evaluate(BuiltinMacros.DEPENDENCY_SCOPE_INCLUDES_DIRECT_DEPENDENCIES) {
                        // Track targets requested via flattening specially, because the build setting is not applied recursively. If A depends on B depends on C and A/B both set DEPENDENCY_SCOPE_INCLUDES_DIRECT_DEPENDENCIES=YES, but only A was present in the build request, we should only build A and B.
                        extraRequestedTargetGUIDs.formUnion(configuredTarget.target.dependencies.map(\.guid))
                    }
                    if configuredTarget.target is PackageProductTarget {
                        // If this is a package product, we want to also include any targets which make up that product, since they can't be added to a scheme.
                        potentialExtraRequestedPackageTargetGUIDs.formUnion(configuredTarget.target.dependencies.map(\.guid))
                    }
                } else if extraRequestedTargetGUIDs.contains(configuredTarget.target.guid) {
                    keptTargets.insert(configuredTarget, at: 0)
                } else if potentialExtraRequestedPackageTargetGUIDs.contains(configuredTarget.target.guid) {
                    // This target was not explicitly requested, but it's a dependency of a package product. If this is not a package product, make sure we include it.
                    if configuredTarget.target is PackageProductTarget {
                        removedTargets.append(configuredTarget)
                    } else {
                        potentialExtraRequestedPackageTargetGUIDs.formUnion(configuredTarget.target.dependencies.map(\.guid))
                        keptTargets.insert(configuredTarget, at: 0)
                    }
                } else {
                    removedTargets.append(configuredTarget)
                }
            }

            // For each removed target, identify all kept targets reachable by traversing only edges which originate at a removed target.
            var reachableKeptTargetsByRemovedTarget: [ConfiguredTarget: OrderedSet<ConfiguredTarget>] = [:]
            do {
                func visit(_ configuredTarget: ConfiguredTarget) {
                    if let outgoingEdges = targetDependencies[configuredTarget], !outgoingEdges.isEmpty {
                        for outgoingEdge in outgoingEdges {
                            if keptTargets.contains(outgoingEdge.target) {
                                reachableKeptTargetsByRemovedTarget[configuredTarget, default: []].append(outgoingEdge.target)
                            } else if removedTargets.contains(outgoingEdge.target) {
                                visit(outgoingEdge.target)
                                reachableKeptTargetsByRemovedTarget[configuredTarget, default: []].append(contentsOf: reachableKeptTargetsByRemovedTarget[outgoingEdge.target] ?? [])
                            } else {
                                assertionFailure("\(outgoingEdge.target.target.name) was not in the list of kept or pruned targets.")
                            }
                        }
                    } else {
                        reachableKeptTargetsByRemovedTarget[configuredTarget] = []
                    }
                }

                while let unvisitedRemovedTarget = removedTargets.subtracting(reachableKeptTargetsByRemovedTarget.keys).first {
                    visit(unvisitedRemovedTarget)
                }
            }

            // Then, create an updated list of edges for the modified graph.
            var updatedTargetDependencies: [ConfiguredTarget: [ResolvedTargetDependency]] = [:]
            for keptConfiguredTarget in keptTargets {
                for outgoingEdge in targetDependencies[keptConfiguredTarget] ?? [] {
                    if keptTargets.contains(outgoingEdge.target) {
                        // If this is an edge from a kept target, to a kept target, preserve it.
                        updatedTargetDependencies[keptConfiguredTarget, default: []].append(outgoingEdge)
                    } else {
                        // If this is an edge from a kept target to a removed target, then see if any kept targets are reachable from that removed target. If so, add edges from the kept target to each reachable kept target.
                        for reachableKeptTarget in reachableKeptTargetsByRemovedTarget[outgoingEdge.target] ?? [] {
                            updatedTargetDependencies[keptConfiguredTarget, default: []].append(ResolvedTargetDependency(target: reachableKeptTarget, reason: .impliedByTransitiveDependencyViaRemovedTargets(intermediateTargetName: outgoingEdge.target.target.name)))
                        }
                    }
                }
            }

            // Finally, update the canonical node and adjacency list.
            allTargets = keptTargets
            targetDependencies = updatedTargetDependencies
        }

        return (allTargets, targetDependencies, targetsToLinkedReferencesToProducingTargets, resolver.dynamicallyBuildingTargets)
    }

    /// Discover the dependency information for one target.
    ///
    /// This will update the shared configured target and dependency info.
    func discoverInfo(for configuredTarget: ConfiguredTarget, imposedParameters: SpecializationParameters?) async {
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

        // Add the discovered info.
        let discoveredInfo = await computeDiscoveredTargetInfo(for: configuredTarget, imposedParameters: imposedParameters, dependencyPath: nil, resolver: resolver)
        discoveredTargets[configuredTarget] = discoveredInfo

        // If we have no dependencies, we are done.
        if discoveredInfo.immediateDependencies.isEmpty {
            return
        }

        // Otherwise, dispatch discovery of all of the immediate dependencies in parallel.
        await resolver.concurrentPerform(iterations: discoveredInfo.immediateDependencies.count, maximumParallelism: 100) { [self] i in
            let dependency = discoveredInfo.immediateDependencies[i]
            let imposedParametersForDependency: SpecializationParameters
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
            await self.discoverInfo(for: dependency.target, imposedParameters: imposedParametersForDependency)
        }
    }

    /// Private method to add the receiver's dependencies to a dependency closure ordered set, followed by adding the receiver itself.  Each target is configured using the parameters of `configuredTarget` before being added to the closure.  This effectively performs a postorder traversal of the target dependency graph.
    ///
    /// - Parameters:
    ///   - dependencyClosure: The list of targets to add to.
    ///   - configuredTarget: The configured target whose parameters should be used to configure the receiver and its dependencies.
    ///   - dependencyPath: The ordered list of dependencies added along the path to this target, for detecting recursion.
    ///   - imposedParameters: Additional build parameter overrides which should be imposed upon all targets along this path (for specialization purposes).
    private func addDependencies(forConfiguredTarget configuredTarget: ConfiguredTarget, toDependencyClosure dependencyClosure: inout OrderedSet<ConfiguredTarget>, dependencyPath: inout OrderedSet<ConfiguredTarget>, imposedParameters: SpecializationParameters? = nil) async {
        let statusMessage = workspaceContext.userPreferences.activityTextShorteningLevel >= .allDynamicText
            ? "Computing dependencies"
            : "Computing dependencies for '\(configuredTarget.target.name)'"
        delegate.updateProgress(statusMessage: statusMessage, showInLog: false)

        // Update the path, while traversing.
        guard dependencyPath.append(configuredTarget).inserted else {
            // If the target is already present along this path then we found a cycle.
            //
            // FIXME: We need to report these cycles: <rdar://problem/31707925> Swift Build should directly report cycles discovered during target graph resolution
            return
        }
        defer {
            let element = dependencyPath.removeLast()
            assert(element === configuredTarget)
        }

        // If the configured target is already in the dependency closure, then we return.
        //
        // The combination of these two guards means that the top-level target where any recursion was entered will always be added to the end of the dependency closure.
        guard !dependencyClosure.contains(configuredTarget) else { return }

        // Get the discovered target info, or create it if necessary (for targets not visited in the initial discovery, or when specialization has become active).
        let discoveredInfo: DiscoveredTargetInfo
        if let info = discoveredTargets[configuredTarget], imposedParameters == nil || imposedParameters?.isCompatible(with: configuredTarget, settings: buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target), workspaceContext: workspaceContext) == true {
            discoveredInfo = info
        } else {
            if resolver.makeAggregateTargetsTransparentForSpecialization {
                discoveredInfo = await computeDiscoveredTargetInfo(for: configuredTarget, imposedParameters: imposedParameters, dependencyPath: dependencyPath, resolver: resolver)
            } else {
                var immediateDependencies = [ResolvedTargetDependency]()
                var packageProductDependencies = [PackageProductTarget]()
                for dependency in resolver.explicitDependencies(for: configuredTarget) {
                    if let asPackageProduct = dependency as? PackageProductTarget {
                        packageProductDependencies.append(asPackageProduct)
                    } else {
                        let buildParameters = resolver.buildParametersByTarget[dependency] ?? configuredTarget.parameters
                        let effectiveImposedParameters = imposedParameters?.effectiveParameters(target: configuredTarget, dependency: ConfiguredTarget(parameters: buildParameters, target: dependency), dependencyResolver: resolver)
                        let configuredDependency = await resolver.lookupConfiguredTarget(dependency, parameters: buildParameters, imposedParameters: effectiveImposedParameters)
                        immediateDependencies.append(ResolvedTargetDependency(target: configuredDependency, reason: .explicit))
                    }
                }
                discoveredInfo = DiscoveredTargetInfo(immediateDependencies: immediateDependencies, packageProductDependencies: packageProductDependencies)
            }
        }

        // Create an ordered set to remember our immediate dependencies.
        var immediateDependencies = OrderedSet<ResolvedTargetDependency>()

        /// Nested function to record that `dependency` is an immediate dependency of the target being processed.
        func recordImmediateDependency(_ dependency: ResolvedTargetDependency, imposedParameters: SpecializationParameters? = nil) async {
            immediateDependencies.append(dependency)
            let dependencyImposedParameters: SpecializationParameters?
            if resolver.makeAggregateTargetsTransparentForSpecialization && dependency.target.target.type == .aggregate {
                dependencyImposedParameters = imposedParameters
            } else {
                dependencyImposedParameters = resolver.specializationParameters(dependency.target, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
            }
            await addDependencies(forConfiguredTarget: dependency.target, toDependencyClosure: &dependencyClosure, dependencyPath: &dependencyPath, imposedParameters: dependencyImposedParameters)
        }


        // Visit all of the immediate dependencies.
        for configuredDependency in discoveredInfo.immediateDependencies {
            if Task.isCancelled { break }
            let imposedParametersForDependency: SpecializationParameters?
            if resolver.makeAggregateTargetsTransparentForSpecialization {
                // Aggregate targets should be transparent for specialization, so unless we already have imposed parameters, we will compute them based on the parent of the aggregate unless that is an aggregate itself.
                if imposedParameters == nil && configuredDependency.target.target.type == .aggregate && configuredTarget.target.type != .aggregate {
                    imposedParametersForDependency = resolver.specializationParameters(configuredTarget, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
                } else {
                    imposedParametersForDependency = imposedParameters
                }
            } else {
                imposedParametersForDependency = imposedParameters
            }
            await recordImmediateDependency(configuredDependency, imposedParameters: imposedParametersForDependency)
        }

        // Visit all of the package product targets.
        for dependency in discoveredInfo.packageProductDependencies {
            if Task.isCancelled { break }

            let buildParameters = resolver.buildParametersByTarget[dependency] ?? configuredTarget.parameters

            // If this is a dependency onto a package product target, the package product inherits certain settings from the target which depends on it (unless we are already in a specialized context.
            //
            // FIXME: We eventually will also need to reconcile conflicting requirements, one example: <rdar://problem/31587072> In Swift Build, creating ConfiguredTargets from Targets should take into account minimum deployment target
            var specializedParameters = imposedParameters?.effectiveParameters(target: configuredTarget, dependency: ConfiguredTarget(parameters: buildParameters, target: dependency), dependencyResolver: resolver)
            if specializedParameters == nil {
                specializedParameters = resolver.specializationParameters(configuredTarget, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
            }

            // Get the configured dependency.  Package product dependencies are always 'explicit'.
            let configuredDependency = await resolver.lookupConfiguredTarget(dependency, parameters: buildParameters, imposedParameters: specializedParameters)
            await recordImmediateDependency(ResolvedTargetDependency(target: configuredDependency, reason: .explicit), imposedParameters: specializedParameters)
        }

        // Add the immediate dependencies for this configured target to the cache of that data.
        immediateDependenciesByConfiguredTarget![configuredTarget] = immediateDependencies

        // Finally, add the configured target to the dependency closure.
        dependencyClosure.append(configuredTarget)
    }

    /// Discover the info for a configured target with the given imposed parameters.
    private func computeDiscoveredTargetInfo(for configuredTarget: ConfiguredTarget, imposedParameters: SpecializationParameters?, dependencyPath: OrderedSet<ConfiguredTarget>?, resolver: isolated DependencyResolver) async -> DiscoveredTargetInfo {
        var immediateDependencies = [ResolvedTargetDependency]()
        var packageProductDependencies = [PackageProductTarget]()
        for dependency in resolver.explicitDependencies(for: configuredTarget) {
            if let asPackageProduct = dependency as? PackageProductTarget {
                packageProductDependencies.append(asPackageProduct)
            } else {
                if !resolver.isTargetSuitableForPlatformForIndex(dependency, parameters: configuredTarget.parameters, imposedParameters: imposedParameters, dependencies: dependencyPath) {
                    continue
                }

                // If we have an existing, compatible configured target, use its build parameters.
                // But, if the imposedParameters include superimposedProperties, then we always want to look up a new configured target.
                // FIXME: This logic could likely take superimposed properties into account to even further reduce creating duplicate targets, but presently extracting that info from ConfiguredTarget is not easy to do in a generic manner.  It's also unlikely to yield large performance wins.
                if imposedParameters?.superimposedProperties == nil, let compatibleTarget = resolver.compatibleConfiguredTarget(dependency, for: configuredTarget.parameters, baseTarget: configuredTarget.target) {
                    immediateDependencies.append(ResolvedTargetDependency(target: compatibleTarget, reason: .explicit))
                } else {
                    let buildParameters = resolver.buildParametersByTarget[dependency] ?? configuredTarget.parameters
                    let effectiveImposedParameters = imposedParameters?.effectiveParameters(target: configuredTarget, dependency: ConfiguredTarget(parameters: buildParameters, target: dependency), dependencyResolver: resolver)
                    let configuredDependency = resolver.lookupConfiguredTarget(dependency, parameters: buildParameters, imposedParameters: effectiveImposedParameters)
                    immediateDependencies.append(ResolvedTargetDependency(target: configuredDependency, reason: .explicit))
                }
            }
        }

        do {
            // For implicit dependencies, the TOOLCHAIN is not imposed downstream. Doing so can cause multiple targets building for the same SDK but with differing toolchains, and that is not a valid configuration. It is up to the client to ensure that the TOOLCHAIN is configured properly for how the target is used.
            let imposedParametersWithoutToolchainImposition = imposedParameters?.withoutToolchainImposition

            // NOTE: Package products are intentionally excluded here (and thus don't participate in implicit dependencies).
            let fromPackage = workspaceContext.workspace.project(for: configuredTarget.target).isPackage
            if let linkageDependencyResolver, buildRequest.useImplicitDependencies, !fromPackage {
                let resolvedDependencies = await linkageDependencyResolver.implicitDependencies(for: configuredTarget, immediateDependencies: immediateDependencies.map({ $0.target }), imposedParameters: imposedParametersWithoutToolchainImposition, resolver: resolver)
                immediateDependencies += resolvedDependencies

                // This is a bit ugly, but any targets that are found via the `linkageDependencyResolver` above need to
                // be included as well, otherwise, they will not be properly considered for things like the specialization
                // filtering that happens for default vs. suffixed SDK differences between a target. (see rdar://75600023).

                for (key, configuredTargets) in await linkageDependencyResolver.resolver.configuredTargetsByTarget {
                    resolver.updateConfiguredTargetsByTarget { $0[key, default: []].formUnion(configuredTargets) }
                    for ct in configuredTargets {
                        let effectiveImposedParameters = imposedParameters?.effectiveParameters(target: configuredTarget, dependency: ct, dependencyResolver: resolver)
                        resolver.addSuperimposedProperties(for: ct, superimposedProperties: effectiveImposedParameters?.superimposedProperties)
                    }
                }
            }
        }

        return DiscoveredTargetInfo(immediateDependencies: immediateDependencies, packageProductDependencies: packageProductDependencies)
    }
}
