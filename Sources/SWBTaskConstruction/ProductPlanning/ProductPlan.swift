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

package import SWBUtil
package import SWBCore
import SWBMacro
import SWBProtocol
import Foundation

/// The `GlobalProductPlanDelegate` is a subset of the more ubiquitous `TaskPlanningDelegate` which provides functionality only needed by a `GlobalProductPlan`, even if it exists outside the context of a build.
package protocol GlobalProductPlanDelegate: CoreClientTargetDiagnosticProducingDelegate {
    /// Check if the construction has been cancelled and should abort as soon as possible.
    var cancelled: Bool { get }

    /// Update the progress of an ongoing task planning operation.
    func updateProgress(statusMessage: String, showInLog: Bool)
}

/// Information on the global build plan.
///
/// This class encapsulates the information on the global product plan which is made available to each individual product to use during planning.
package final class GlobalProductPlan: GlobalTargetInfoProvider
{
    /// The build plan request.
    let planRequest: BuildPlanRequest

    /// The target task info for each configured target.
    private(set) var targetTaskInfos: [ConfiguredTarget: TargetTaskInfo]

    /// The imparted build properties for each configured target.
    ///
    /// The array of imparted build properties is ordered so that direct dependencies come first, followed by their direct
    /// transitive dependencies and so forth.
    private var impartedBuildPropertiesByTarget: [ConfiguredTarget: [SWBCore.ImpartedBuildProperties]]

    /// The set of shared intermediate nodes that have been created, keyed by their sharing identifier.
    ///
    /// This is a limited mechanism for concurrent task construction processes to coordinate on the production of a shared node.
    let sharedIntermediateNodes = Registry<String, (any PlannedNode, any Sendable)>()

    let delegate: any GlobalProductPlanDelegate

    struct VFSContentsKey: Hashable {
        let project: SWBCore.Project
        let effectivePlatformName: String
    }

    /// A shared map of VFS contents, keyed by project.
    //
    // FIXME: <rdar://problem/28303817> [Swift Build] Produce VFS as a per-project task
    let sharedVFSContents = Registry<VFSContentsKey, ByteString>()

    /// The mapping of user-module info for targets.
    private let moduleInfo = Registry<ConfiguredTarget, ModuleInfo?>()

    /// The information about XCFrameworks used throughout the task planning process.
    let xcframeworkContext: XCFrameworkContext

    /// The recursive search path resolver to use.
    let recursiveSearchPathResolver: RecursiveSearchPathResolver

    let buildDirectories: BuildDirectoryContext

    /// Whether this build requires a VFS.
    var needsVFS: Bool { return needsVFSCache.getValue(self) }
    private var needsVFSCache = LazyCache { (plan: GlobalProductPlan) -> Bool in
        // We enable the VFS iff some target provides a user-defined module.
        for ct in plan.targetTaskInfos.keys {
            if plan.getTargetSettings(ct).globalScope.evaluate(BuiltinMacros.DEFINES_MODULE) {
                return true
            }
        }
        return false
    }

    /// Maps targets to the set of macro implementations they should load when compiling Swift code.
    package private(set) var swiftMacroImplementationDescriptorsByTarget: [ConfiguredTarget: Set<SwiftMacroImplementationDescriptor>]

    /// The set of targets which must build during prepare-for-indexing.
    package private(set) var targetsRequiredToBuildForIndexing: Set<ConfiguredTarget>

    /// The set of targets which need to build a swiftmodule during installAPI
    package private(set) var targetsWhichShouldBuildModulesDuringInstallAPI: Set<ConfiguredTarget>?

    /// All targets in the product plan.
    /// - remark: This property is preferred over the `TargetBuildGraph` in the `BuildPlanRequest` as it performs additional computations for Swift packages.
    package private(set) var allTargets: [ConfiguredTarget] = []

    /// Get the dependencies of a target in the graph.
    package func dependencies(of target: ConfiguredTarget) -> [ConfiguredTarget] {
        resolvedDependencies(of: target).map { $0.target }
    }

    package func resolvedDependencies(of target: ConfiguredTarget) -> [ResolvedTargetDependency] {
        // Use the static target for lookup if necessary.
        let configuredTarget: ConfiguredTarget
        if let staticTarget = staticallyBuildingTargetsWithDiamondLinkage[target.target] {
            configuredTarget = target.replacingTarget(staticTarget)
        } else {
            configuredTarget = target
        }

        // Return dynamic targets where necessary.
        return planRequest.buildGraph.resolvedDependencies(of: configuredTarget).map { resolvedDependency in
            if let dynamicTarget = dynamicallyBuildingTargetsWithDiamondLinkage[resolvedDependency.target.target] {
                return resolvedDependency.replacingTarget(dynamicTarget)
            } else {
                return resolvedDependency
            }
        }
    }

    /// The mapping of original targets to dynamically building targets because of diamond-style linkage.
    private var dynamicallyBuildingTargetsWithDiamondLinkage = [SWBCore.Target: SWBCore.Target]()

    /// Reverse mapping which allows looking up the corresponding dynamically building target for a static one.
    private var staticallyBuildingTargetsWithDiamondLinkage = [SWBCore.Target: SWBCore.Target]()

    /// All targets in the product plan which are building dynamically because of diamond-style linkage or because of the client's build request.
    ///
    /// Note: currently this will only be package product targets.
    package var dynamicallyBuildingTargets: Set<SWBCore.Target> {
        return Set(planRequest.buildGraph.dynamicallyBuildingTargets + Array(dynamicallyBuildingTargetsWithDiamondLinkage.keys))
    }

    struct ErrorComponents: Hashable {
        let name: String
        let targetName: String
        let andOther: String
        let conflicts: Bool
    }

    var errorComponentsList = Set<ErrorComponents>()

    /// A map from the `Path` of each products created by a target in the dependency closure (using both `TARGET_BUILD_DIR` and `BUILT_PRODUCTS_DIR`) to the `ConfiguredTarget` which creates it.
    /// - remark: If there are multiple targets which create products at the same path, that is not reflected here, and will be a build error elsewhere.
    let productPathsToProducingTargets: [Path: ConfiguredTarget]

    /// A map from `ConfiguredTarget`s which are being built as mergeable libraries to `ConfiguredTarget`s which are merging them.
    let mergeableTargetsToMergingTargets: [ConfiguredTarget: Set<ConfiguredTarget>]

    /// A map from each target to all of the targets whose products its product hosts.
    ///
    /// Presently the only mechanism supported for this sort of hosting is XCTest app-hosted tests using `TEST_HOST`.
    let hostedTargetsForTargets: [ConfiguredTarget: OrderedSet<ConfiguredTarget>]

    /// A map from each hosted target to the target whose product hosts its product.
    ///
    /// Presently the only mechanism supported for this sort of hosting is XCTest app-hosted tests using `TEST_HOST`.
    let hostTargetForTargets: [ConfiguredTarget: ConfiguredTarget]

    /// The set of `PRODUCT_NAME`s used by more than one target. This is permitted, but may require special consideration in some contexts to avoid conflicting tasks/outputs.
    let duplicatedProductNames: Set<String>

    /// A map from targets to the the target which produces the nearest enclosing product.
    let targetToProducingTargetForNearestEnclosingProduct: [ConfiguredTarget: ConfiguredTarget]

    /// A map of `MH_BUNDLE` targets to any clients of that target.
    let clientsOfBundlesByTarget: [ConfiguredTarget:[ConfiguredTarget]]

    private static let dynamicMachOTypes = ["mh_execute", "mh_dylib", "mh_bundle"]

    // Checks that we have either been passed a configuration override for packages or we are building Debug/Release.
    private static func verifyPackageConfigurationOverride(planRequest: BuildPlanRequest) {
        #if DEBUG
        if !planRequest.workspaceContext.workspace.projects.filter({ $0.isPackage }).isEmpty {
            let parameters = planRequest.buildRequest.parameters
            assert(parameters.configuration == nil || parameters.packageConfigurationOverride != nil || parameters.configuration == "Debug" || parameters.configuration == "Release")
        }
        #endif
    }

    enum LinkedDependency: Hashable {
        case direct(ConfiguredTarget)
        case staticTransitive(ConfiguredTarget, origin: ConfiguredTarget)
        case bundleLoader(ConfiguredTarget)

        var target: ConfiguredTarget {
            switch self {
            case .direct(let target): return target
            case .staticTransitive(let target, _): return target
            case .bundleLoader(let target): return target
            }
        }
    }

    package init(planRequest: BuildPlanRequest, delegate: any GlobalProductPlanDelegate, nodeCreationDelegate: (any TaskPlanningNodeCreationDelegate)?) async {
        Self.verifyPackageConfigurationOverride(planRequest: planRequest)

        self.planRequest = planRequest
        self.delegate = delegate
        self.recursiveSearchPathResolver = RecursiveSearchPathResolver(fs: planRequest.workspaceContext.fs)
        self.xcframeworkContext = XCFrameworkContext(workspaceContext: planRequest.workspaceContext, buildRequestContext: planRequest.buildRequestContext)
        self.buildDirectories = BuildDirectoryContext()

        var clientsOfBundlesByTarget = [ConfiguredTarget:[ConfiguredTarget]]()
        let bundleTargets = Set(planRequest.buildGraph.allTargets.filter {
            let settings = planRequest.buildRequestContext.getCachedSettings($0.parameters, target: $0.target)
            return settings.globalScope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_bundle"
        })
        for configuredTarget in planRequest.buildGraph.allTargets {
            for match in bundleTargets.intersection(planRequest.buildGraph.dependencies(of: configuredTarget)) {
                clientsOfBundlesByTarget[match, default: []].append(configuredTarget)
            }
        }
        self.clientsOfBundlesByTarget = clientsOfBundlesByTarget

        var directlyLinkedDependenciesByTarget = [ConfiguredTarget:OrderedSet<LinkedDependency>]()
        var impartedBuildPropertiesByTarget = [ConfiguredTarget:[SWBCore.ImpartedBuildProperties]]()

        // We can skip computing contributing properties entirely if no target declares any and if there are no package products in the graph.
        let targetsContributingProperties = planRequest.buildGraph.allTargets.filter { !$0.target.hasImpartedBuildProperties || $0.target.type == .packageProduct }
        if !targetsContributingProperties.isEmpty {
            let linkageGraph = await TargetLinkageGraph(workspaceContext: planRequest.workspaceContext, buildRequest: planRequest.buildRequest, buildRequestContext: planRequest.buildRequestContext, delegate: WrappingDelegate(delegate: delegate))

            let configuredTargets = planRequest.buildGraph.allTargets
            let targetsByBundleLoader = Self.computeBundleLoaderDependencies(
                planRequest: planRequest,
                configuredTargets: AnyCollection(configuredTargets),
                diagnosticDelegate: delegate
            )
            var bundleLoaderByTarget = [ConfiguredTarget:ConfiguredTarget]()
            for (bundleLoaderTarget, targetsUsingThatBundleLoader) in targetsByBundleLoader {
                for targetUsingBundleLoader in targetsUsingThatBundleLoader {
                    bundleLoaderByTarget[targetUsingBundleLoader] = bundleLoaderTarget
                }
            }

            for configuredTarget in configuredTargets {
                // Compute the transitive dependencies of the configured target.
                let dependencies: OrderedSet<ConfiguredTarget>
                if UserDefaults.useTargetDependenciesForImpartedBuildSettings {
                    dependencies = transitiveClosure([configuredTarget], successors: planRequest.buildGraph.dependencies(of:)).0
                } else {
                    dependencies = transitiveClosure([configuredTarget], successors: linkageGraph.dependencies(of:)).0
                }

                let linkedDependencies: [LinkedDependency] = linkageGraph.dependencies(of: configuredTarget).map { .direct($0) }
                let transitiveStaticDependencies: [LinkedDependency] = linkedDependencies.flatMap { origin in
                    transitiveClosure([origin.target]) {
                        let settings = planRequest.buildRequestContext.getCachedSettings($0.parameters, target: $0.target)
                        guard !Self.dynamicMachOTypes.contains(settings.globalScope.evaluate(BuiltinMacros.MACH_O_TYPE)) else {
                            return []
                        }
                        return linkageGraph.dependencies(of: $0)
                    }.0.map { .staticTransitive($0, origin: origin.target) }
                }

                directlyLinkedDependenciesByTarget[configuredTarget] = OrderedSet(linkedDependencies + transitiveStaticDependencies + (bundleLoaderByTarget[configuredTarget].map { [.bundleLoader($0)] } ?? []))
                impartedBuildPropertiesByTarget[configuredTarget] = dependencies.compactMap { $0.getImpartedBuildProperties(using: planRequest) }
            }

            for (targetToImpart, bundleLoaderTargets) in targetsByBundleLoader {
                for bundleLoaderTarget in bundleLoaderTargets {
                    // Bundle loader target gets all of the build settings that are imparted to the target it is referencing _and_ the build settings that are being imparted by that referenced target.
                    let currentImpartedBuildProperties = targetToImpart.getImpartedBuildProperties(using: planRequest).map { [$0] } ?? []
                    impartedBuildPropertiesByTarget[bundleLoaderTarget, default: []] += currentImpartedBuildProperties + (impartedBuildPropertiesByTarget[targetToImpart] ?? [])
                }
            }
        }

        self.impartedBuildPropertiesByTarget = impartedBuildPropertiesByTarget


        // Iterate through the targets to compute the following:
        //  - The TargetTaskInfo for each target.  This is done in multiple passes to account for one target's product being embedded in another ('host') target.
        //  - The map of paths of hosting targets' product paths to the targets whose products they are hosting.
        //  - The map of product paths to their producing targets.
        //    (We ignore the case where multiple targets produce the same path, because that's going to be a problem in many other places.)
        //  - The map of targets being built as mergeable to targets which are merging them.
        var targetTaskInfos = [ConfiguredTarget: TargetTaskInfo]()
        var productPathsToProducingTargets = [Path: ConfiguredTarget]()
        var targetsForProductPaths = [Path: ConfiguredTarget]()
        var targetsForTestHostPaths = [Path: OrderedSet<ConfiguredTarget>]()
        var mergeableTargetsToMergingTargets = [ConfiguredTarget: Set<ConfiguredTarget>]()
        var shouldEmitValidArchsEnforcementNote = false
        for configuredTarget in planRequest.buildGraph.allTargets {
            let settings = planRequest.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target, provisioningTaskInputs: planRequest.provisioningInputs[configuredTarget])
            let scope = settings.globalScope

            if !scope.evaluate(BuiltinMacros.ENFORCE_VALID_ARCHS) {
                shouldEmitValidArchsEnforcementNote = true
            }

            // Compute various interesting paths to the product for this target and save them for use below to match them with targets whose product they are hosting.
            for buildDirSetting in [BuiltinMacros.BUILT_PRODUCTS_DIR, BuiltinMacros.TARGET_BUILD_DIR] {
                let buildDirPath = scope.evaluate(buildDirSetting)
                for subpathSetting in [BuiltinMacros.FULL_PRODUCT_NAME, BuiltinMacros.EXECUTABLE_PATH] {
                    let subpath = scope.evaluate(subpathSetting)
                    if !subpath.isEmpty, !subpath.isAbsolute {
                        let path = buildDirPath.join(subpath)
                        // Note that if we find multiple targets in the build graph which create products at the same path, only one will be recorded here.  But in that case llbuild should complain at build time about multiple producers for some output.  Since this logic is somewhat niche at present (only used for hosted test targets), we're not emitting an issue here, since it's a more general potential problem and I think we should fall through to the llbuild behavior.  But I'm leaving this comment in so that if we have a future unanticipated scenario where this is relevant, a future visitor to this code can note that this code isn't handling that scenario.
                        targetsForProductPaths[path] = configuredTarget
                    }
                }
            }

            // Record the target's products using both TARGET_BUILD_DIR and BUILT_PRODUCTS_DIR.
            if let standardTarget = configuredTarget.target as? SWBCore.StandardTarget {
                productPathsToProducingTargets[settings.globalScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(standardTarget.productReference.name).normalize()] = configuredTarget
                productPathsToProducingTargets[settings.globalScope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(standardTarget.productReference.name).normalize()] = configuredTarget
            }

            // If this target is a merged binary target, then record its dependencies which are being built as mergeable libraries.
            if scope.evaluate(BuiltinMacros.MERGE_LINKED_LIBRARIES) {
                for dependency in planRequest.buildGraph.dependencies(of: configuredTarget) {
                    let settings = planRequest.buildRequestContext.getCachedSettings(dependency.parameters, target: dependency.target, provisioningTaskInputs: planRequest.provisioningInputs[dependency])
                    let scope = settings.globalScope
                    if scope.evaluate(BuiltinMacros.MERGEABLE_LIBRARY) {
                        mergeableTargetsToMergingTargets[dependency, default: Set<ConfiguredTarget>()].insert(configuredTarget)
                    }
                }
            }

            // If this is a target whose product will be embedded by that target inside another target, then capture information about the target it will embed into.
            // Note that we don't invoke XCTestBundleProductTypeSpec.usesTestHost() here because it returns false when doing a deployment build.
            let hostProductPath = Path(scope.evaluate(BuiltinMacros.TEST_HOST)).normalize()
            if settings.productType is XCTestBundleProductTypeSpec && !hostProductPath.isEmpty {
                if !hostProductPath.isEmpty {
                    // This is a test target which uses TEST_HOST, so we add it to the list of targets which are using that host.
                    targetsForTestHostPaths[hostProductPath, default: OrderedSet<ConfiguredTarget>()].append(configuredTarget)
                }
            }

            // If we have a delegate to do so, then create virtual nodes for the target used to order this target's tasks with respect to other target's tasks - both fundamental target ordering, and orderings for eager compilation.
            if let nodeCreationDelegate {
                let targetNodeBase = configuredTarget.guid.stringValue
                let targetStartNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-entry")
                let targetEndNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-end")
                let targetStartCompilingNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-begin-compiling")
                let targetStartLinkingNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-begin-linking")
                let targetStartScanningNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-begin-scanning")
                let targetModulesReadyNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-modules-ready")
                let targetLinkerInputsReadyNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-linker-inputs-ready")
                let targetScanInputsReadyNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-scan-inputs-ready")
                let targetStartImmediateNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-immediate")

                var preparedForIndexPreCompilationNode: (any PlannedNode)?
                var preparedForIndexModuleContentNode: (any PlannedNode)?
                if planRequest.buildRequest.enableIndexBuildArena, configuredTarget.target.type == .standard {
                    let settings = planRequest.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target, impartedBuildProperties: impartedBuildPropertiesByTarget[configuredTarget])
                    let scope = settings.globalScope
                    preparedForIndexPreCompilationNode = nodeCreationDelegate.createNode(absolutePath: Path(scope.evaluate(BuiltinMacros.INDEX_PREPARED_TARGET_MARKER_PATH)))
                    preparedForIndexModuleContentNode = nodeCreationDelegate.createNode(absolutePath: Path(scope.evaluate(BuiltinMacros.INDEX_PREPARED_MODULE_CONTENT_MARKER_PATH)))
                }
                let targetUnsignedProductReadyNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-unsigned-product-ready")
                let targetWillSignNode = nodeCreationDelegate.createVirtualNode(targetNodeBase + "-will-sign")

                // Create the target task info collector.
                targetTaskInfos[configuredTarget] = TargetTaskInfo(startNode: targetStartNode, endNode: targetEndNode, startCompilingNode: targetStartCompilingNode, startLinkingNode: targetStartLinkingNode, startScanningNode: targetStartScanningNode, modulesReadyNode: targetModulesReadyNode, linkerInputsReadyNode: targetLinkerInputsReadyNode, scanInputsReadyNode: targetScanInputsReadyNode, startImmediateNode: targetStartImmediateNode, unsignedProductReadyNode: targetUnsignedProductReadyNode, willSignNode: targetWillSignNode, preparedForIndexPreCompilationNode: preparedForIndexPreCompilationNode, preparedForIndexModuleContentNode: preparedForIndexModuleContentNode)
            }
        }

        if shouldEmitValidArchsEnforcementNote {
            delegate.note("Not enforcing VALID_ARCHS because ENFORCE_VALID_ARCHS = NO")
        }

        self.targetTaskInfos = targetTaskInfos
        self.productPathsToProducingTargets = productPathsToProducingTargets
        self.mergeableTargetsToMergingTargets = mergeableTargetsToMergingTargets

        // Compute the map of targets to the list of targets they host, and vice versa.
        var hostedTargetsForTarget = [ConfiguredTarget: OrderedSet<ConfiguredTarget>]()
        var hostTargetForTargets = [ConfiguredTarget: ConfiguredTarget]()
        for (hostPath, hostedTargets) in targetsForTestHostPaths {
            // If somehow we don't have any hosted targets for this path, just skip this.
            guard !hostedTargets.isEmpty else {
                continue
            }
            if let hostTarget = targetsForProductPaths[hostPath] {
                hostedTargetsForTarget[hostTarget] = hostedTargets
                for target in hostedTargets {
                    hostTargetForTargets[target] = hostTarget
                }
            }
            else {
                // Emit a warning for a target which defines a TEST_HOST which can't be mapped to a target.  Brian Croom says, "we have a fairly hard requirement [in IDEFoundation] that your TEST_HOST value be something that we can trace back to a buildable in the current workspace, which we then use to query the bundle identifier. Years ago it was possible to select arbitrary other pre-built apps to use as the host, but we unintentionally broke that at some point".  He suggested adding this warning.
                for hostedTarget in hostedTargets {
                    delegate.warning(.overrideTarget(hostedTarget), "Unable to find a target which creates the host product for value of $(TEST_HOST) '\(hostPath.str)'", location: .buildSetting(BuiltinMacros.TEST_HOST), component: .targetIntegrity)
                }
            }
        }
        self.hostedTargetsForTargets = hostedTargetsForTarget
        self.hostTargetForTargets = hostTargetForTargets

        var productNames: Set<String> = []
        var duplicatedNames: Set<String> = []
        for configuredTarget in planRequest.buildGraph.allTargets {
            let settings = planRequest.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target, provisioningTaskInputs: planRequest.provisioningInputs[configuredTarget])
            let targetProductName = settings.globalScope.evaluate(BuiltinMacros.PRODUCT_NAME)
            if productNames.contains(targetProductName) {
                duplicatedNames.insert(targetProductName)
            } else {
                productNames.insert(targetProductName)
            }
        }
        self.duplicatedProductNames = duplicatedNames

        // Record targets with nested build directories.
        var targetToProducingTargetForNearestEnclosingProduct: [ConfiguredTarget: ConfiguredTarget] = [:]
        for configuredTarget in planRequest.buildGraph.allTargets {
            let settings = planRequest.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target, provisioningTaskInputs: planRequest.provisioningInputs[configuredTarget])
            var dir = settings.globalScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).normalize()
            while !dir.isRoot && !dir.isEmpty {
                if let enclosingTarget = productPathsToProducingTargets[dir] {
                    targetToProducingTargetForNearestEnclosingProduct[configuredTarget] = enclosingTarget
                    break
                }
                dir = dir.dirname
            }
        }
        self.targetToProducingTargetForNearestEnclosingProduct = targetToProducingTargetForNearestEnclosingProduct


        var swiftMacroImplementationDescriptorsByTarget: [ConfiguredTarget: Set<SwiftMacroImplementationDescriptor>] = [:]
        var targetsRequiredToBuildForIndexing: Set<ConfiguredTarget> = []
        // Consider the targets in topological order, collecting information about host tool usage.
        for configuredTarget in planRequest.buildGraph.allTargets {
            // If this target loads binary macros, add a descriptor for this target
            let settings = planRequest.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target, provisioningTaskInputs: planRequest.provisioningInputs[configuredTarget])
            let macros = settings.globalScope.evaluate(BuiltinMacros.SWIFT_LOAD_BINARY_MACROS)
            if !macros.isEmpty {
                for macro in macros {
                    if let descriptor = SwiftMacroImplementationDescriptor(value: macro) {
                        swiftMacroImplementationDescriptorsByTarget[configuredTarget, default: []].insert(descriptor)
                    } else {
                        delegate.error("'\(macro)' does not describe a valid Swift macro implementation")
                    }
                }
            }
            // Because macro implementations are host tools, we consider all dependencies rather than restricting ourselves to only linkage dependencies like imparted build properties. As a result, we do not require special handling of bundle loader targets here.
            for dependency in planRequest.buildGraph.dependencies(of: configuredTarget) {
                // Add any macro implementation targets of the dependency to the dependent. The dependency is guaranteed to have its descriptors (if any) populated because the targets are being processed in topological order.
                swiftMacroImplementationDescriptorsByTarget[configuredTarget, default: []].formUnion(swiftMacroImplementationDescriptorsByTarget[dependency, default: []])
                // If the dependency vends a macro, add a descriptor for this target.
                let dependencySettings = planRequest.buildRequestContext.getCachedSettings(dependency.parameters, target: dependency.target, provisioningTaskInputs: planRequest.provisioningInputs[dependency])
                let declaringModules = dependencySettings.globalScope.evaluate(BuiltinMacros.SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES)
                if !declaringModules.isEmpty {
                    swiftMacroImplementationDescriptorsByTarget[configuredTarget, default: []].insert(.init(declaringModuleNames: declaringModules, path: dependencySettings.globalScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(dependencySettings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_PATH)).normalize()))
                }
            }
            // If this target is a host tool, it and its dependencies must build as part of prepare-for-indexing.
            if settings.productType?.conformsTo(identifier: "com.apple.product-type.tool.host-build") == true {
                targetsRequiredToBuildForIndexing.insert(configuredTarget)
                targetsRequiredToBuildForIndexing.formUnion(transitiveClosure([configuredTarget], successors: planRequest.buildGraph.dependencies(of:)).0)
            }
        }
        self.swiftMacroImplementationDescriptorsByTarget = swiftMacroImplementationDescriptorsByTarget

        // Collect information about tools produced by the build which may be run by script phases or custom tasks (including those derived from package build tool plugins.
        // Consider the targets in topological order
        var targetsByCommandLineToolProductPath: [Path: ConfiguredTarget] = [:]
        for configuredTarget in planRequest.buildGraph.allTargets {
            let targetSettings = planRequest.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target, provisioningTaskInputs: planRequest.provisioningInputs[configuredTarget])
            if targetSettings.platform?.name == targetSettings.globalScope.evaluate(BuiltinMacros.HOST_PLATFORM),
               targetSettings.productType?.conformsTo(identifier: "com.apple.product-type.tool") == true {
                let executablePath = targetSettings.globalScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(targetSettings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_PATH)).normalize()
                targetsByCommandLineToolProductPath[executablePath] = configuredTarget
            }

            for scriptPhase in (configuredTarget.target as? SWBCore.BuildPhaseTarget)?.buildPhases.compactMap({ $0 as? SWBCore.ShellScriptBuildPhase }) ?? [] {
                for scriptPhaseInput in scriptPhase.inputFilePaths.map({ Path(targetSettings.globalScope.evaluate($0)).normalize() }) {
                    if let producingTarget = targetsByCommandLineToolProductPath[scriptPhaseInput] {
                        targetsRequiredToBuildForIndexing.insert(producingTarget)
                        targetsRequiredToBuildForIndexing.formUnion(transitiveClosure([producingTarget], successors: planRequest.buildGraph.dependencies(of:)).0)
                    }
                }
            }

            for customTask in configuredTarget.target.customTasks {
                guard customTask.preparesForIndexing else { continue }
                for input in customTask.inputFilePaths.map({ Path(targetSettings.globalScope.evaluate($0)).normalize() }) {
                    if let producingTarget = targetsByCommandLineToolProductPath[input] {
                        targetsRequiredToBuildForIndexing.insert(producingTarget)
                        targetsRequiredToBuildForIndexing.formUnion(transitiveClosure([producingTarget], successors: planRequest.buildGraph.dependencies(of:)).0)
                    }
                }
            }
        }

        self.targetsRequiredToBuildForIndexing = targetsRequiredToBuildForIndexing

        if planRequest.buildRequest.parameters.action == .installAPI {
            var targetsWhichShouldEmitModulesDuringInstallAPI: Set<ConfiguredTarget> = []
            // Consider all targets in topological order, visiting dependents before dependencies to ensure all transitive dependencies of a target which emits a module also emit modules.
            for configuredTarget in planRequest.buildGraph.allTargets.reversed() {
                let settings = planRequest.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target, provisioningTaskInputs: planRequest.provisioningInputs[configuredTarget])
                // If this target will emit a TBD during installAPI, it must emit a module
                if settings.globalScope.evaluate(BuiltinMacros.SUPPORTS_TEXT_BASED_API) && settings.allowInstallAPIForTargetsSkippedInInstall(in: settings.globalScope) && settings.productType?.supportsInstallAPI == true {
                    targetsWhichShouldEmitModulesDuringInstallAPI.insert(configuredTarget)
                }
                // If this target should emit a module during installAPI, its dependencies should as well because this target's module may depend on them.
                if targetsWhichShouldEmitModulesDuringInstallAPI.contains(configuredTarget) {
                    for dependency in planRequest.buildGraph.dependencies(of: configuredTarget) {
                        targetsWhichShouldEmitModulesDuringInstallAPI.insert(dependency)
                    }
                }
            }
            self.targetsWhichShouldBuildModulesDuringInstallAPI = targetsWhichShouldEmitModulesDuringInstallAPI
        } else {
            self.targetsWhichShouldBuildModulesDuringInstallAPI = nil
        }

        diagnoseInvalidDeploymentTargets(diagnosticDelegate: delegate)
        diagnoseSwiftPMUnsafeFlags(diagnosticDelegate: delegate)

        if UserDefaults.enableDiagnosingDiamondProblemsWhenUsingPackages && !planRequest.buildRequest.enableIndexBuildArena {
            resolveDiamondProblemsInPackages(dependenciesByTarget: directlyLinkedDependenciesByTarget, diagnosticDelegate: delegate)
        }

        // Sort based on order from build graph to preserve any fixed ordering from the scheme.
        self.allTargets = Array(self.targetTaskInfos.keys).sorted { (a, b) -> Bool in
            guard let first = planRequest.buildGraph.allTargets.firstIndex(of: a) else {
                return false
            }

            guard let second = planRequest.buildGraph.allTargets.firstIndex(of: b) else {
                return true
            }

            return first < second
        }
    }

    private static func computeBundleLoaderDependencies(
        planRequest: BuildPlanRequest,
        configuredTargets: AnyCollection<ConfiguredTarget>,
        diagnosticDelegate: any TargetDiagnosticProducingDelegate
    ) -> [ConfiguredTarget: [ConfiguredTarget]] {
        let targetsWithBundleLoader: [(Path, ConfiguredTarget)] = configuredTargets.compactMap {
            let settings = planRequest.buildRequestContext.getCachedSettings($0.parameters, target: $0.target)
            let bundleLoader = settings.globalScope.evaluate(BuiltinMacros.BUNDLE_LOADER)
            return bundleLoader.isEmpty ? nil : (bundleLoader, $0)
        }

        // We can return early if there are no targets that uses the bundle loader setting.
        if targetsWithBundleLoader.isEmpty {
            return [:]
        }

        let targetsWithBundleLoaderMap = Dictionary(grouping: targetsWithBundleLoader, by: { $0.0 }).mapValues{ $0.compactMap{ $0.1 } }

        // We only need to care about targets that actually have some imparted properties.
        let executablePathToTarget: [(Path, ConfiguredTarget)] = configuredTargets.map {
            let settings = planRequest.buildRequestContext.getCachedSettings($0.parameters, target: $0.target)
            let path = settings.globalScope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR).join(settings.globalScope.evaluate(BuiltinMacros.EXECUTABLE_PATH)).normalize()
            return (path, $0)
        }
        let executablePathToTargetsMap = Dictionary(grouping: executablePathToTarget, by: { $0.0 }).mapValues{ $0.compactMap{ $0.1 } }

        var result: [ConfiguredTarget: [ConfiguredTarget]] = [:]
        for (execName, targets) in executablePathToTargetsMap {
            // Skip targets that are not referenced in any target with a bundle loader.
            guard let bundleLoaderTargets = targetsWithBundleLoaderMap[execName] else { continue }
            guard targets.count == 1 else {
                // This means multiple targets are going to write to the same location. This would be diagnosed during task construction.
                continue
            }

            result[targets[0]] = bundleLoaderTargets
        }
        return result
    }

    /// Ensures that no non-package target is depending on a package target
    /// that uses unsafe flags in the package manifest.
    func diagnoseSwiftPMUnsafeFlags(diagnosticDelegate: any TargetDiagnosticProducingDelegate) {
        let targets = planRequest.buildGraph.allTargets

        // Find targets that use unsafe flags.
        let unsafeFlagsTargets = targets.filter {
            return getTargetSettings($0).globalScope.evaluate(BuiltinMacros.USES_SWIFTPM_UNSAFE_FLAGS)
        }

        for target in targets {
            // Ignore package targets as SwiftPM already checks for this.
            let project = planRequest.workspaceContext.workspace.project(for: target.target)
            if project.isPackage {
                continue
            }

            // Emit an error if this target depends on a package target that uses unsafe flags.
            //
            // We'll probably want to allow this for root packages in the future.
            let dependencies = planRequest.buildGraph.dependencies(of: target)
            let dependsOnAnUnsafeTarget = dependencies.first{ unsafeFlagsTargets.contains($0) }
            if let unsafeTarget = dependsOnAnUnsafeTarget {
                diagnosticDelegate.error(.overrideTarget(target), "The package product '\(unsafeTarget.target.name)' cannot be used as a dependency of this target because it uses unsafe build flags.", component: .targetIntegrity)
            }
        }
    }

    func diagnoseInvalidDeploymentTargets(diagnosticDelegate: any TargetDiagnosticProducingDelegate) {
        for target in planRequest.buildGraph.allTargets.filter({
            planRequest.workspaceContext.workspace.project(for: $0.target).isPackage && $0.target.type != .packageProduct
        }) {
            let settings = getTargetSettings(target)
            let platformDeploymentTargetMacro: StringMacroDeclaration?
            let platformDisplayName: String
            if settings.sdkVariant?.isMacCatalyst == true {
                platformDeploymentTargetMacro = BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET
                platformDisplayName = BuildVersion.Platform.macCatalyst.displayName(infoLookup: planRequest.workspaceContext.core)
            } else {
                platformDeploymentTargetMacro = settings.platform?.deploymentTargetMacro
                platformDisplayName = settings.platform?.familyDisplayName ?? "No Platform"
            }

            guard let deploymentTargetMacro = platformDeploymentTargetMacro, let deploymentTarget = try? Version(settings.globalScope.evaluate(deploymentTargetMacro)) else {
                continue
            }

            let dependencies = planRequest.buildGraph.dependencies(of: target)
            for dependency in dependencies {
                guard let dependencyDeploymentTarget = try? Version(self.getTargetSettings(dependency).globalScope.evaluate(deploymentTargetMacro)) else {
                    continue
                }

                if dependencyDeploymentTarget > deploymentTarget {
                    diagnosticDelegate.error(.overrideTarget(target), "The package product '\(dependency.target.name)' requires minimum platform version \(dependencyDeploymentTarget) for the \(platformDisplayName) platform, but this target supports \(deploymentTarget)", component: .targetIntegrity)
                }
            }
        }
    }

    func resolveDiamondProblemsInPackages(dependenciesByTarget: [ConfiguredTarget:OrderedSet<LinkedDependency>], diagnosticDelegate: any TargetDiagnosticProducingDelegate) {
        // Repeatedly check for diamonds until we do not find any more. This should always converge since worst case we will stop once all static package targets have been converted to dynamic ones, but we will also terminate if we somehow end up in a stable state with more than zero remaining diamonds.
        var lastDiamonds = 0, currentDiamonds = 0
        repeat {
            lastDiamonds = currentDiamonds
            currentDiamonds = checkForDiamondProblemsInPackageProductLinkage(dependenciesByTarget: dependenciesByTarget, diagnosticDelegate: diagnosticDelegate)
        } while currentDiamonds > 0 && lastDiamonds != currentDiamonds

        // If all package targets of a product ended up being building dynamically, we do not need to build the product itself dynamically. In fact doing so would fail, because the binary would have no contents.
        for staticTarget in dynamicallyBuildingTargetsWithDiamondLinkage.keys {
            guard staticTarget.type == .packageProduct else { continue }

            let packageTargetDependencies = staticTarget.dependencies.compactMap { targetDependency in
                planRequest.buildGraph.workspaceContext.workspace.target(for: targetDependency.guid)
            }.filter {
                $0.type != .packageProduct
            }
            let staticallyLinkedTargets = packageTargetDependencies.filter { !dynamicallyBuildingTargets.contains($0) }.filter {
                // Note: we cannot easily get to the "right" build parameters here, but it seems fine to work with the generic ones because we will only inspect settings that shouldn't depend on specific parameters.
                let settings = planRequest.buildRequestContext.getCachedSettings(planRequest.buildRequest.parameters, target: $0)
                let isObjectFile = settings.globalScope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_object"
                let isStaticLibrary = settings.globalScope.evaluate(BuiltinMacros.PRODUCT_TYPE) == "com.apple.product-type.library.static"
                return isObjectFile || isStaticLibrary
            }

            guard staticallyLinkedTargets.isEmpty else { continue }

            guard let guid = dynamicallyBuildingTargetsWithDiamondLinkage[staticTarget]?.guid else { continue }
            for configuredTarget in self.targetTaskInfos.keys {
                guard configuredTarget.target.guid == guid else { continue }
                let dynamicConfiguredTarget = configuredTarget
                let staticConfiguredTarget = dynamicConfiguredTarget.replacingTarget(staticTarget)

                guard let taskInfo = self.targetTaskInfos[dynamicConfiguredTarget] else { continue }
                self.targetTaskInfos.removeValue(forKey: dynamicConfiguredTarget)
                self.targetTaskInfos[staticConfiguredTarget] = taskInfo

                let impartedBuildProperties = self.impartedBuildPropertiesByTarget[dynamicConfiguredTarget]
                self.impartedBuildPropertiesByTarget.removeValue(forKey: dynamicConfiguredTarget)
                self.impartedBuildPropertiesByTarget[staticConfiguredTarget] = impartedBuildProperties

                self.dynamicallyBuildingTargetsWithDiamondLinkage.removeValue(forKey: staticConfiguredTarget.target)
                self.staticallyBuildingTargetsWithDiamondLinkage.removeValue(forKey: dynamicConfiguredTarget.target)
            }
        }
    }

    // Checks whether we have any duplicated occurrences of the same package product in the graph.
    func checkForDiamondProblemsInPackageProductLinkage(dependenciesByTarget: [ConfiguredTarget:OrderedSet<LinkedDependency>], diagnosticDelegate: any TargetDiagnosticProducingDelegate) -> Int {
        func emitError(for name: String, targetName: String, andOther: String, conflicts: Bool = false) {
            if errorComponentsList.insert(ErrorComponents(name: name, targetName: targetName, andOther: andOther, conflicts: conflicts)).inserted {
                if conflicts {
                    diagnosticDelegate.error("Swift package \(name) is linked as a static library by '\(targetName)' \(andOther), but cannot be built dynamically because there is a package product with the same name.")
                } else {
                    diagnosticDelegate.error("Swift package \(name) is linked as a static library by '\(targetName)' \(andOther). This will result in duplication of library code.")
                }
            }
        }

        // First, we need to determine which top-level targets link a certain package product or target.
        var topLevelLinkingTargetsByPackageProduct = [ConfiguredTarget:Set<ConfiguredTarget>]()
        var topLevelLinkingTargetsByPackageTarget = [ConfiguredTarget:Set<ConfiguredTarget>]()

        for (configuredTarget, dependencies) in dependenciesByTarget {
            // We are only interested in targets which link dynamically.
            let settings = getTargetSettings(configuredTarget)
            guard Self.dynamicMachOTypes.contains(settings.globalScope.evaluate(BuiltinMacros.MACH_O_TYPE)) || dynamicallyBuildingTargets.contains(configuredTarget.target) else {
                continue
            }

            var packageTargetsToSkip = [SWBCore.Target]()

            // Find all statically linked package products.
            let linkedPackageProducts = dependencies.filter {
                $0.target.target.type == .packageProduct
            }.filter { packageProduct in
                // Ignore if we already converted this to a dynamic target.
                if dynamicallyBuildingTargets.contains(packageProduct.target.target) {
                    packageTargetsToSkip.append(contentsOf: packageProduct.target.target.dependencies.compactMap {
                        planRequest.workspaceContext.workspace.target(for: $0.guid)
                    }.filter {
                        $0.type != .packageProduct
                    })
                    return false
                }
                // Find the configured targets for target dependencies.
                let dependencies = packageProduct.target.target.dependencies.compactMap { targetDependency in
                    planRequest.buildGraph.allTargets.first(where: { $0.target.guid == targetDependency.guid })
                }
                // Use the first package target to determine linkage.
                guard let packageTargetTarget = dependencies.first else {
                    return false
                }
                // Check whether this actually links statically.
                let settings = getTargetSettings(packageTargetTarget)
                return settings.productType?.identifier == "com.apple.product-type.objfile"
            }

            for product in linkedPackageProducts {
                topLevelLinkingTargetsByPackageProduct[product.target, default: []].insert(configuredTarget)
            }

            // Find all statically linked package targets.
            let linkedPackageTargets = dependencies.filter {
                guard planRequest.workspaceContext.workspace.project(for: $0.target.target).isPackage else { return false }
                // Ignore if we already converted this to a dynamic target.
                if dynamicallyBuildingTargets.contains($0.target.target) || packageTargetsToSkip.contains($0.target.target) {
                    return false
                }
                // Check whether this actually links statically.
                return getTargetSettings($0.target).productType?.identifier == "com.apple.product-type.objfile"
            }

            for target in linkedPackageTargets {
                topLevelLinkingTargetsByPackageTarget[target.target, default: []].insert(configuredTarget)
            }
        }

        var numberOfDiamonds = 0

        // To determine actual diamond problems, we need to calculate for which executable we have multiple top-level targets linking the same package product.
        for (configuredTarget, dependencies) in dependenciesByTarget {
            // We are only interested in targets which are building an executable this time.
            let settings = getTargetSettings(configuredTarget)
            guard Self.dynamicMachOTypes.contains(settings.globalScope.evaluate(BuiltinMacros.MACH_O_TYPE)) else {
                continue
            }
            // Do not check this target if the diagnostic is disabled.
            guard !settings.globalScope.evaluate(BuiltinMacros.DISABLE_DIAMOND_PROBLEM_DIAGNOSTIC) else {
                continue
            }

            enum PackageTargetKind {
                case product
                case target
            }

            @discardableResult func checkLinkage(for name: String, topLevelTargets: Set<ConfiguredTarget>, kind: PackageTargetKind) -> String? {
                // Determine which top-level targets ultimately end up in the current executable's process.
                let linkingAgainstCurrentExecutable = Array(topLevelTargets.intersection(dependencies.map { $0.target } + [configuredTarget])).sorted()
                if linkingAgainstCurrentExecutable.count > 1 {
                    let andOther: String
                    if linkingAgainstCurrentExecutable.count == 2, let otherTargetName = linkingAgainstCurrentExecutable.filter({ $0 != configuredTarget }).first?.target.name {
                        andOther = "and '\(otherTargetName)'"
                    } else {
                        andOther = "and \(linkingAgainstCurrentExecutable.count - 1) other targets"
                    }
                    return andOther
                } else {
                    return nil
                }
            }

            // If we have already emitted an error about a package product, don't emit an error about its targets.
            var packageTargetsToIgnore = [ConfiguredTarget]()

            let updateConfiguration = { (configuredTarget: ConfiguredTarget, dynamicTarget: SWBCore.Target) in
                // If the `targetTaskInfo` for the static target isn't present, we already made the decision to make this target dynamic.
                if self.targetTaskInfos[configuredTarget] == nil { return }

                // There can be multiple configured targets for the dynamic target, we have to update all of them.
                let matchingConfiguredTargets = self.targetTaskInfos.keys.filter { $0.target.guid == configuredTarget.target.guid }

                for matchingTarget in matchingConfiguredTargets {
                    guard let taskInfo = self.targetTaskInfos[matchingTarget] else { return }
                    let dynamicConfiguredTarget = matchingTarget.replacingTarget(dynamicTarget)

                    self.targetTaskInfos.removeValue(forKey: matchingTarget)
                    self.targetTaskInfos[dynamicConfiguredTarget] = taskInfo

                    let impartedBuildProperties = self.impartedBuildPropertiesByTarget[matchingTarget]
                    self.impartedBuildPropertiesByTarget.removeValue(forKey: matchingTarget)
                    self.impartedBuildPropertiesByTarget[dynamicConfiguredTarget] = impartedBuildProperties

                    let descriptors = self.swiftMacroImplementationDescriptorsByTarget.removeValue(forKey: matchingTarget)
                    self.swiftMacroImplementationDescriptorsByTarget[dynamicConfiguredTarget] = descriptors

                    if self.targetsRequiredToBuildForIndexing.remove(matchingTarget) != nil {
                        self.targetsRequiredToBuildForIndexing.insert(dynamicConfiguredTarget)
                    }

                    if self.targetsWhichShouldBuildModulesDuringInstallAPI?.remove(matchingTarget) != nil {
                        self.targetsWhichShouldBuildModulesDuringInstallAPI?.insert(dynamicConfiguredTarget)
                    }
                }
            }

            for (product, topLevelTargets) in topLevelLinkingTargetsByPackageProduct {
                let name = "product '\(product.target.name)'"
                if let andOther = checkLinkage(for: name, topLevelTargets: topLevelTargets, kind: .product) {
                    packageTargetsToIgnore.append(contentsOf: dependenciesByTarget[product]?.map { $0.target } ?? [])

                    let workspaceContext = self.planRequest.workspaceContext
                    if let packageProductTarget = product.target as? SWBCore.PackageProductTarget, let guid = packageProductTarget.dynamicTargetVariantGuid, let dynamicTarget = workspaceContext.workspace.target(for: guid) {
                        updateConfiguration(product, dynamicTarget)
                        self.dynamicallyBuildingTargetsWithDiamondLinkage[packageProductTarget] = dynamicTarget
                    } else {
                        // If we can't determine a dynamic target, still emit the error.
                        emitError(for: name, targetName: configuredTarget.target.name, andOther: andOther)
                    }

                    numberOfDiamonds += 1
                }
            }

            for (target, topLevelTargets) in topLevelLinkingTargetsByPackageTarget {
                if !packageTargetsToIgnore.contains(target) {
                    let name = "target '\(target.target.name)'"
                    if let andOther = checkLinkage(for: name, topLevelTargets: topLevelTargets, kind: .target) {
                        let workspaceContext = self.planRequest.workspaceContext
                        if let standardTarget = target.target as? SWBCore.StandardTarget, let guid = standardTarget.dynamicTargetVariantGuid, let dynamicTarget = workspaceContext.workspace.target(for: guid) {
                            updateConfiguration(target, dynamicTarget)
                            self.dynamicallyBuildingTargetsWithDiamondLinkage[standardTarget] = dynamicTarget
                        } else {
                            // If we can't determine a dynamic target, still emit the error.
                            emitError(for: name, targetName: configuredTarget.target.name, andOther: andOther, conflicts: self.getTargetSettings(target).globalScope.evaluate(BuiltinMacros.PACKAGE_TARGET_NAME_CONFLICTS_WITH_PRODUCT_NAME))
                        }

                        numberOfDiamonds += 1
                    }
                }
            }
        }

        for (packageProductTarget, dynamicTarget) in dynamicallyBuildingTargetsWithDiamondLinkage {
            staticallyBuildingTargetsWithDiamondLinkage[dynamicTarget] = packageProductTarget
        }

        return numberOfDiamonds
    }

    func getWorkspaceSettings() -> Settings {
        return planRequest.buildRequestContext.getCachedSettings(planRequest.buildRequest.parameters)
    }

    /// Get the settings to use for a particular configured target.
    package func getTargetSettings(_ configuredTarget: ConfiguredTarget) -> Settings {
        // FIXME: Reevaluate whether or not we should cache all of the things we compute here in the workspace context, that may lead to more memory use than it is worth.
        let provisioningTaskInputs: ProvisioningTaskInputs? = planRequest.buildRequest.enableIndexBuildArena ? nil : planRequest.provisioningInputs(for: configuredTarget)
        return planRequest.buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target, provisioningTaskInputs: provisioningTaskInputs, impartedBuildProperties: impartedBuildPropertiesByTarget[configuredTarget])
    }

    /// Get the settings to use for an unconfigured target.
    ///
    /// This method is intended for use when querying cross-target information where the configuration parameters are not known. In this case, we will use the "best" configured target that we know of, ideally one for the current build. If no configured target is available, we will use one that is configured "as if" the target was building.
    func getUnconfiguredTargetSettings(_ target: SWBCore.Target, viewedFrom: ConfiguredTarget) -> Settings {
        // FIXME: Find the "best" configured target.
        //
        // FIXME: Make efficient.
        for ct in planRequest.buildGraph.allTargets {
            if ct.target === target {
                // We found the target in the build, use it.
                return getTargetSettings(ct)
            }
        }

        // Otherwise, the target is not participating in the build. Use the target as configured with the base build parameters.  Specifically don't include the provisioning task inputs in the settings, since unconfigured targets never have those inputs computed for them.
        //
        // The important thing here is that we try to pick a "consistent" target as often as possible, so that we usually see the same settings regardless of what target we are viewing it from.
        //
        // FIXME: We can do better than this, we probably want to match certain things like the platform.
        //
        // FIXME: Should we care about caching this ConfiguredTarget?
        return getTargetSettings(ConfiguredTarget(parameters: planRequest.buildRequest.parameters, target: target))
    }

    /// Get the module info for a particular target.
    package func getModuleInfo(_ configuredTarget: ConfiguredTarget) -> ModuleInfo? {
        // NOTE: Take care, there is a lock precedence here.
        //
        // FIXME: This is another client that would like to be uncontended on the computation-for-key case.
        return moduleInfo.getOrInsert(configuredTarget) {
            let settings = getTargetSettings(configuredTarget)
            return GlobalProductPlan.computeModuleInfo(workspaceContext: planRequest.workspaceContext, target: configuredTarget.target, settings: settings, diagnosticHandler: { message, location, component, essential in
                delegate.warning(.overrideTarget(configuredTarget), message, location: location, component: component)
            })
        }
    }

    /// Get the expanded search paths for a particular variable.
    func expandedSearchPaths(for items: [String], relativeTo sourcePath: Path, scope: MacroEvaluationScope) -> [String] {
        var result = [String]()
        for item in items {
            let item = Path(item)
            // Expand recursive header search paths, if present.
            if item.basename == "**" {
                // Drop the recursive search marker and make absolute.
                let item = item.dirname
                let searchPath = sourcePath.join(item)

                // Ignore any attempts to do a recursive search of root.
                if searchPath.isRoot {
                    result.append(Path.root.str)
                } else {
                    let excludedPatterns = scope.evaluate(BuiltinMacros.EXCLUDED_RECURSIVE_SEARCH_PATH_SUBDIRECTORIES)
                    let includedPatterns = scope.evaluate(BuiltinMacros.INCLUDED_RECURSIVE_SEARCH_PATH_SUBDIRECTORIES)
                    // FIXME: We need to cache this, and record it to validate the build result.
                    let expanded = recursiveSearchPathResolver.expandedPaths(for: searchPath, relativeTo: sourcePath, excludedPatterns: excludedPatterns, includedPatterns: includedPatterns)

                    // FIXME: We currently ignore recursive search path expansion warnings.

                    // If no paths were added, at least add the specified.
                    //
                    // NOTE: It would be simpler to add this in the resolver, but it changes the command lines (based on whether or not the result is a relative path). We can simplify this if we drop the use of relative recursive search paths.
                    if expanded.paths.isEmpty {
                        result.append(item.str)
                    } else {
                        for path in expanded.paths {
                            result.append(path.str)
                        }
                    }
                }
            } else {
                result.append(item.str)
            }
        }
        return result
    }

    /// Construct the module info, if used, for a target.
    //
    // FIXME: We should just merge the ModuleInfo with the ProductPlan: <rdar://problem/24843930> [Swift Build] Merge ModuleInfo with ProductPlan
    static func computeModuleInfo(workspaceContext: WorkspaceContext, target: SWBCore.Target, settings: Settings, diagnosticHandler: (_ message: String, _ location: Diagnostic.Location, _ component: Component, _ essential: Bool) -> Void) -> ModuleInfo? {
        let scope = settings.globalScope

        // If this product type doesn't support modules, do nothing.
        if scope.evaluate(BuiltinMacros.MODULEMAP_FILE_CONTENTS).isEmpty && !(settings.productType?.supportsGeneratingModuleMap ?? false) {
            return nil
        }

        // If DEFINES_MODULE is disabled, do nothing.
        if !scope.evaluate(BuiltinMacros.DEFINES_MODULE) {
            if !scope.evaluate(BuiltinMacros.MODULEMAP_FILE_CONTENTS).isEmpty {
                diagnosticHandler("MODULEMAP_FILE_CONTENTS has no effect if DEFINES_MODULE is not set", Diagnostic.Location.buildSetting(BuiltinMacros.MODULEMAP_FILE_CONTENTS), .targetIntegrity, false)
            }
            if !scope.evaluate(BuiltinMacros.MODULEMAP_FILE).isEmpty {
                diagnosticHandler("MODULEMAP_FILE has no effect if DEFINES_MODULE is not set", Diagnostic.Location.buildSetting(BuiltinMacros.MODULEMAP_FILE), .targetIntegrity, false)
            }
            if !scope.evaluate(BuiltinMacros.MODULEMAP_PRIVATE_FILE).isEmpty {
                diagnosticHandler("MODULEMAP_PRIVATE_FILE has no effect if DEFINES_MODULE is not set", Diagnostic.Location.buildSetting(BuiltinMacros.MODULEMAP_PRIVATE_FILE), .targetIntegrity, false)
            }
            return nil
        }

        // We have a target which supports and wants to produce a module.

        // Determine if the target includes Swift, which might contribute to the module definition.
        let specLookupContext = SpecLookupCtxt(specRegistry: workspaceContext.core.specRegistry, platform: settings.platform)
        let buildingAnySwiftSourceFiles = (target as? SWBCore.BuildPhaseTarget)?.sourcesBuildPhase?.containsSwiftSources(workspaceContext.workspace, specLookupContext, scope, settings.filePathResolver) ?? false

        // Determine if the target exports its Swift ObjC API.
        let exportsSwiftObjCAPI = buildingAnySwiftSourceFiles && scope.evaluate(BuiltinMacros.SWIFT_INSTALL_OBJC_HEADER) && !scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME).isEmpty

        // Determine if the target itself should generate a module map.
        let (createsModuleMap, umbrellaHeader) = generatesModuleMap(workspaceContext: workspaceContext, target: target, settings: settings)

        let hasExplicitModuleMapContents = !scope.evaluate(BuiltinMacros.MODULEMAP_FILE_CONTENTS).isEmpty

        // If the target doesn't define a module, it only defines a module if we have Swift or if it has explicit module map contents.
        if !createsModuleMap && !exportsSwiftObjCAPI && !hasExplicitModuleMapContents {
            diagnosticHandler("DEFINES_MODULE was set, but no umbrella header could be found to generate the module map", Diagnostic.Location.buildSetting(BuiltinMacros.DEFINES_MODULE), .targetIntegrity, false)
            if !scope.evaluate(BuiltinMacros.MODULEMAP_PRIVATE_FILE).isEmpty {
                diagnosticHandler("MODULEMAP_PRIVATE_FILE has no effect if there is no public module", Diagnostic.Location.buildSetting(BuiltinMacros.MODULEMAP_PRIVATE_FILE), .targetIntegrity, false)
            }
            return nil
        }

        // ... and thus the module is Swift only iff the target isn't generating a module map.
        assert(createsModuleMap || exportsSwiftObjCAPI || hasExplicitModuleMapContents)
        let forSwiftOnly = !createsModuleMap

        // Compute the paths for the module map files for this target in the staging location in $(TARGET_TEMP_DIR).  These copies will be included in the VFS so that we have a simple, defined location for where to have the VFS look for module map entries.  The ModuleInfo object contains these paths so that tasks created by other task producers can depend on them.

        // These paths are assumed to be absolute, to produce absolute paths in the ModuleInfo. If they aren't, well we made a best effort.
        let targetTempDir = scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR)
        let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
        let projectDir = scope.evaluate(BuiltinMacros.PROJECT_DIR)

        var warnedAboutTargetTmpDir = false
        var warnedAboutTargetBuildDir = false
        var warnedAboutProjectDir = false
        if !targetTempDir.isAbsolute {
            diagnosticHandler("not absolute for target \(target.name)", Diagnostic.Location.buildSetting(BuiltinMacros.TARGET_TEMP_DIR), .targetIntegrity, true)
            warnedAboutTargetTmpDir = true
        }
        if !targetBuildDir.isAbsolute {
            diagnosticHandler("not absolute for target \(target.name)", Diagnostic.Location.buildSetting(BuiltinMacros.TARGET_BUILD_DIR), .targetIntegrity, true)
            warnedAboutTargetBuildDir = true
        }
        if !projectDir.isAbsolute {
            diagnosticHandler("not absolute for target \(target.name)", Diagnostic.Location.buildSetting(BuiltinMacros.PROJECT_DIR), .targetIntegrity, true)
            warnedAboutProjectDir = true
        }

        let modulesFolderPath = scope.evaluate(BuiltinMacros.MODULES_FOLDER_PATH)
        let moduleMapFileSetting = scope.evaluate(BuiltinMacros.MODULEMAP_FILE)
        let moduleMapPathOverrideSetting = scope.evaluate(BuiltinMacros.MODULEMAP_PATH)
        let moduleMapPathOverridePath = Path(moduleMapPathOverrideSetting)

        let moduleMapTmpPath = targetTempDir.join(moduleMapPathOverridePath.basename.isEmpty ? "module.modulemap" : moduleMapPathOverridePath.basename)

        var knownClangModuleNames: [String] = []
        let moduleMapSourcePath: Path
        if moduleMapFileSetting.isEmpty {
            // When the modulemap is constructed automatically, there is no source file and the build product is mapped to the temp file.
            moduleMapSourcePath = moduleMapTmpPath
            if hasExplicitModuleMapContents {
                // FIXME: Parse the contents and add the module name to `knownClangModuleNames`
            } else {
                knownClangModuleNames.append(scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME))
            }
        } else {
            moduleMapSourcePath = Path(moduleMapFileSetting).makeAbsolute(relativeTo: projectDir) ?? Path(moduleMapFileSetting)
            // FIXME: If the modulemap already exists, parse it and add the module name to `knownClangModuleNames`
        }
        if !moduleMapSourcePath.isAbsolute && !warnedAboutTargetTmpDir && !warnedAboutProjectDir {
            // If projectDir was not absolute we fell back to the setting which was also not absolute
            diagnosticHandler("not absolute for target \(target.name)", Diagnostic.Location.buildSetting(BuiltinMacros.MODULEMAP_FILE), .targetIntegrity, true)
        }

        let moduleMapBuildPath: Path
        if moduleMapPathOverrideSetting.isEmpty {
            moduleMapBuildPath = targetBuildDir.join(modulesFolderPath).join("module.modulemap")
        } else {
            moduleMapBuildPath = moduleMapPathOverridePath.makeAbsolute(relativeTo: projectDir) ?? moduleMapPathOverridePath
        }
        if !moduleMapBuildPath.isAbsolute && !warnedAboutTargetBuildDir && !warnedAboutProjectDir {
            // If projectDir was not absolute we fell back to the setting which was also not absolute
            diagnosticHandler("not absolute for target \(target.name)", Diagnostic.Location.buildSetting(BuiltinMacros.MODULEMAP_PATH), .targetIntegrity, true)
        }

        let privateModuleMapFileSetting = scope.evaluate(BuiltinMacros.MODULEMAP_PRIVATE_FILE)
        var privateModuleMapTmpPath: Path? = nil
        var privateModuleMapSourcePath: Path? = nil
        var privateModuleMapBuildPath: Path? = nil
        if !privateModuleMapFileSetting.isEmpty {
            privateModuleMapTmpPath = targetTempDir.join("module.private.modulemap")
            privateModuleMapSourcePath = Path(privateModuleMapFileSetting).makeAbsolute(relativeTo: projectDir) ?? Path(privateModuleMapFileSetting)
            // FIXME: If the modulemap already exists, parse it and add the module name to `knownClangModuleNames`
            privateModuleMapBuildPath = targetBuildDir.join(modulesFolderPath).join("module.private.modulemap")

            if privateModuleMapSourcePath?.isAbsolute == false && !warnedAboutProjectDir {
                // If projectDir was not absolute we fell back to the setting which was also not absolute
                diagnosticHandler("not absolute for target \(target.name)", Diagnostic.Location.buildSetting(BuiltinMacros.MODULEMAP_PRIVATE_FILE), .targetIntegrity, true)
            }
        }

        return ModuleInfo(forSwiftOnly: forSwiftOnly, exportsSwiftObjCAPI: exportsSwiftObjCAPI, umbrellaHeader: umbrellaHeader, moduleMapSourcePath: moduleMapSourcePath, privateModuleMapSourcePath: privateModuleMapSourcePath, moduleMapTmpPath: moduleMapTmpPath, privateModuleMapTmpPath: privateModuleMapTmpPath, moduleMapBuiltPath: moduleMapBuildPath, privateModuleMapBuiltPath: privateModuleMapBuildPath, knownClangModuleNames: knownClangModuleNames)
    }

    /// Determine if `configuredTarget` will generate a module map, and which umbrella header to use.
    private static func generatesModuleMap(workspaceContext: WorkspaceContext, target: SWBCore.Target, settings: Settings) -> (Bool, String) {
        let scope = settings.globalScope

        // A target generates a module map if DEFINES_MODULE is true, and it has an explicit module map (or contents), or it has an umbrella header.
        if !scope.evaluate(BuiltinMacros.DEFINES_MODULE) { return (false, "") }

        // If module map contents were provided explicitly, Swift Build is not going to "generate" a modulemap.
        if !scope.evaluate(BuiltinMacros.MODULEMAP_FILE_CONTENTS).isEmpty { return (false, "") }

        if !scope.evaluate(BuiltinMacros.MODULEMAP_FILE).isEmpty { return (true, "") }

        // Look for an umbrella header to use in a generated module map.
        if let buildPhaseTarget = target as? SWBCore.BuildPhaseTarget, let headersBuildPhase = buildPhaseTarget.headersBuildPhase {
            let workspace = workspaceContext.workspace
            let headerFileTypes = workspaceContext.core.specRegistry.headerFileTypes
            let moduleName = scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME)
            let currentPlatformFilter = PlatformFilter(scope)
            let specLookupContext = SpecLookupCtxt(specRegistry: workspaceContext.core.specRegistry, platform: settings.platform)

            // There's no "umbrella" attribute for headers, just a naming convention. Collect all of the
            // headers that match the convention.
            let eligibleHeaders: [(header: String, headerExtension: String, exactMatch: Bool, visibility: HeaderVisibility)]
            eligibleHeaders = headersBuildPhase.buildFiles.compactMap { buildFile in
                if !currentPlatformFilter.matches(buildFile.platformFilters) {
                    return nil
                }

                if let headerVisibility = buildFile.headerVisibility {
                    switch (headerVisibility, buildFile.buildableItem) {
                    case (.public, .reference(let guid)), (.private, .reference(let guid)):
                        // Historically, we've used both public and private headers in the generated module
                        // map. It might seem wrong to use private headers in a public module map, but clang
                        // allows it. If this framework is destined for the public SDK then bad times are
                        // probably ahead. In the more likely case that this is a private framework with only
                        // private headers, it will work fine, it will just be weird.
                        if let reference = workspace.lookupReference(for: guid) {
                            if specLookupContext.lookupFileType(reference: reference)?.conformsToAny(headerFileTypes) ?? false {
                                let path = settings.filePathResolver.resolveAbsolutePath(reference)
                                let basename = path.basenameWithoutSuffix
                                let exactMatch = basename == moduleName
                                if exactMatch || (basename.caseInsensitiveCompare(moduleName) == .orderedSame) {
                                    return (path.basename, path.fileExtension, exactMatch, headerVisibility)
                                }
                            }
                        }
                    default:
                        return nil
                    }
                }
                return nil
            }

            // Pick the "best" match.
            let bestMatch = eligibleHeaders.min { a, b in
                // Prefer public headers (after all, this is for the public module map).
                switch (a.visibility, b.visibility) {
                case (.public, .private):
                    return true
                case (.private, .public):
                    return false
                default:
                    break
                }

                // Prefer the header that matches the module name exactly.
                switch (a.exactMatch, b.exactMatch) {
                case (true, false):
                    return true
                case (false, true):
                    return false
                default:
                    break
                }

                // Prefer non-C++ headers.
                let extensionA = a.headerExtension
                let extensionB = b.headerExtension
                if (extensionA == "h") && (extensionB != "h") {
                    return true
                } else if (extensionA != "h") && (extensionB == "h") {
                    return false
                } else if (extensionA == "H") && (extensionB != "H") {
                    return true
                } else if (extensionA != "H") && (extensionB == "H") {
                    return false
                }

                // Neither one is a great candidate, just pick one.
                return a.header < b.header
            }

            if let bestMatch = bestMatch {
                return (true, bestMatch.header)
            }
        }

        return (false, "")
    }
}

// Wraps a `GlobalProductPlanDelegate` so that it can be used as a `TargetDependencyResolverDelegate`.
private class WrappingDelegate: TargetDependencyResolverDelegate {
    private let delegate: any GlobalProductPlanDelegate

    fileprivate init(delegate: any GlobalProductPlanDelegate) {
        self.delegate = delegate
    }

    package var cancelled: Bool {
        return delegate.cancelled
    }

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return delegate.diagnosticsEngine(for: target)
    }

    package func emit(_ diagnostic: Diagnostic) {
        diagnosticsEngine.emit(diagnostic)
    }

    package func updateProgress(statusMessage: String, showInLog: Bool) {
        delegate.updateProgress(statusMessage: statusMessage, showInLog: showInLog)
    }

    package var diagnosticContext: DiagnosticContextData {
        return delegate.diagnosticContext
    }
}

/// A ProductPlan represents the work required to figure out how to build a ConfiguredTarget within a WorkspaceContext.  The work is modeled in the form of a list of TaskProducers which generate the tasks to run, and any shared immutable data which multiple task producers might need access to.
package final class ProductPlan
{
    /// Rule name used for the task of 'prepare-for-index' a target, before any compilation can occur.
    package static let preparedForIndexPreCompilationRuleName = "PrepareForIndexPreCompilation"

    /// Rule name used for the task of 'prepare-for-index' module content output of a target.
    package static let preparedForIndexModuleContentRuleName = "PrepareForIndexModuleContent"

    /// The configured target this plan is part of, if any.
    package let forTarget: ConfiguredTarget?

    /// The path of the product of this plan, if it has one (i.e., if its target is not purely procedural).
    package let path: Path

    /// The list of TaskProducers to run to create tasks which will generate the product of this plan.
    let taskProducers: [any TaskProducer]

    /// The target task info.
    //
    // FIXME: This does not belong here, but we currently need it to communicate the list of all actual tasks to the info.
    let targetTaskInfo: TargetTaskInfo?

    /// The task producer context for this plan.
    let taskProducerContext: TaskProducerContext

    init(path: Path, taskProducers: [any TaskProducer], forTarget: ConfiguredTarget?, targetTaskInfo: TargetTaskInfo?, taskProducerContext: TaskProducerContext)
    {
        self.path = path
        self.taskProducers = taskProducers
        self.forTarget = forTarget
        self.targetTaskInfo = targetTaskInfo
        self.taskProducerContext = taskProducerContext
    }
}

private extension ConfiguredTarget {
    func getImpartedBuildProperties(using planRequest: BuildPlanRequest) -> SWBCore.ImpartedBuildProperties? {
        let settings = planRequest.buildRequestContext.getCachedSettings(self.parameters, target: self.target)
        let defaultConfigurationName = planRequest.workspaceContext.workspace.project(for: self.target).defaultConfigurationName
        let buildConfiguration = self.target.getEffectiveConfiguration(settings.globalScope.evaluate(BuiltinMacros.CONFIGURATION), defaultConfigurationName: defaultConfigurationName)
        return buildConfiguration?.impartedBuildProperties
    }
}
