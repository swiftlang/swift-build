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

import SWBCore
import SWBUtil
import SWBMacro

@PluginExtensionSystemActor private func taskProducerExtensions(_ workspaceContext: WorkspaceContext) -> [any TaskProducerExtension] {
    let extensions = workspaceContext.core.pluginManager.extensions(of: TaskProducerExtensionPoint.self)

    // Sort the extensions using their type name so we always go through them in a stable order.
    return extensions.sorted {
        "\(Swift.type(of: $0))" < "\(Swift.type(of: $1))"
    }
}

/// A ProductPlanner is responsible for taking the inputs to a build (the workspace context and build request) and generating a set of product plans containing task producers which can produce tasks which will create those products.  There will be one product plan per configured target in the build request.
package struct ProductPlanner
{
    /// The request for which the planner is constructing plans.
    let planRequest: BuildPlanRequest

    /// The delegate to use to construct planned items.
    let delegate: any TaskPlanningDelegate

    package init(planRequest: BuildPlanRequest, taskPlanningDelegate: any TaskPlanningDelegate)
    {
        self.planRequest = planRequest
        self.delegate = taskPlanningDelegate
    }

    package typealias Generator = AnyIterator<ProductPlan>

    /// Returns a generator which produces a stream of product plans.
    package func productPlans() async -> ([ProductPlan], GlobalProductPlan) {
        return await planRequest.buildRequestContext.keepAliveSettingsCache {
            // Construct the global product plan.
            let globalProductPlan = await GlobalProductPlan(planRequest: planRequest, delegate: delegate, nodeCreationDelegate: delegate)
            let targetTaskInfos = globalProductPlan.targetTaskInfos

            // Create the plans themselves in parallel.
            var productPlans = await globalProductPlan.allTargets.asyncMap { configuredTarget in
                // Create the product plan for the this target, and serially add it to the list of product plans.
                return await ProductPlanBuilder(configuredTarget: configuredTarget, workspaceContext: self.planRequest.workspaceContext, delegate: self.delegate).createProductPlan(targetTaskInfos[configuredTarget]!, globalProductPlan)
            }

            // Create the product plan for target-independent task producers
            await productPlans.append(WorkspaceProductPlanBuilder(workspaceContext: planRequest.workspaceContext, delegate: delegate).createProductPlan(productPlans, globalProductPlan))

            return (productPlans, globalProductPlan)
        }
    }
}

private struct WorkspaceProductPlanBuilder {
    /// The workspace context within which we are creating a plan.
    let workspaceContext: WorkspaceContext

    /// The delegate to use to construct planned items.
    let delegate: any TaskPlanningDelegate

    func createProductPlan(_ targetProductPlans: [ProductPlan], _ globalProductPlan: GlobalProductPlan) async -> ProductPlan {
        // Create the context object for the task producers.
        // FIXME: Either each task producer should get its own file path resolver, or the path resolver's caching logic needs to be thread-safe.
        let globalTaskProducerContext = TaskProducerContext(workspaceContext: workspaceContext, globalProductPlan: globalProductPlan, delegate: delegate)

        let targetContexts = targetProductPlans.map(\.taskProducerContext)

        var taskProducers: [any TaskProducer] = [
            CreateBuildDirectoryTaskProducer(context: globalTaskProducerContext, targetContexts: targetContexts),
            XCFrameworkTaskProducer(context: globalTaskProducerContext, targetContexts: targetContexts),
            SDKStatCacheTaskProducer(context: globalTaskProducerContext, targetContexts: targetContexts),
            HeadermapVFSTaskProducer(context: globalTaskProducerContext, targetContexts: targetContexts),
            PCHModuleMapTaskProducer(context: globalTaskProducerContext, targetContexts: targetContexts),
        ] + (globalProductPlan.planRequest.buildRequest.enableIndexBuildArena ? [IndexBuildVFSDirectoryRemapTaskProducer(context: globalTaskProducerContext)] : [])

        for taskProducerExtension in await taskProducerExtensions(globalTaskProducerContext.workspaceContext) {
            for globalTaskProducer in taskProducerExtension.globalTaskProducers {
                taskProducers.append(globalTaskProducer.createGlobalTaskProducer(globalTaskProducerContext, targetContexts: targetContexts))
            }
        }

        return ProductPlan(path: Path("placeholder"), taskProducers: taskProducers, forTarget: nil, targetTaskInfo: nil, taskProducerContext: globalTaskProducerContext)
    }
}

private struct ProductPlanBuilder
{
    /// The configured target for which we are creating a plan.
    let configuredTarget: ConfiguredTarget

    /// The workspace context within which we are creating a plan.
    let workspaceContext: WorkspaceContext

    /// The delegate to use to construct planned items.
    let delegate: any TaskPlanningDelegate

    init(configuredTarget: ConfiguredTarget, workspaceContext: WorkspaceContext, delegate: any TaskPlanningDelegate)
    {
        self.configuredTarget = configuredTarget
        self.workspaceContext = workspaceContext
        self.delegate = delegate
    }


    /// Create the product plan.
    func createProductPlan(_ targetTaskInfo: TargetTaskInfo, _ globalProductPlan: GlobalProductPlan) async -> ProductPlan
    {
        // Create the context object for the task producers.
        // FIXME: Either each task producer should get its own file path resolver, or the path resolver's caching logic needs to be thread-safe.
        let taskProducerContext = TargetTaskProducerContext(configuredTarget: configuredTarget, workspaceContext: workspaceContext, targetTaskInfo: targetTaskInfo, globalProductPlan: globalProductPlan, delegate: delegate)

        // Compute the path of the product.
        // FIXME: Figure out how to represent targets which don't have a product path (e.g, aggregate and external targets).  Maybe use their PIF GUID?
        var path = Path("placeholder")
        if let standardTarget = self.configuredTarget.target as? StandardTarget
        {
            path = taskProducerContext.settings.filePathResolver.resolveAbsolutePath(standardTarget.productReference)
        }

        // Have the target create its task producers.
        var taskProducers = await self.configuredTarget.target.taskProducers(taskProducerContext)

        // Add the target ordering producer.
        taskProducers.append(TargetOrderTaskProducer(taskProducerContext, targetTaskInfo: targetTaskInfo))

        // Create and return the product plan.  This will set the plan as the shared data provider for each task producer.
        return ProductPlan(path: path, taskProducers: taskProducers, forTarget: configuredTarget, targetTaskInfo: targetTaskInfo, taskProducerContext: taskProducerContext)
    }
}


// MARK: Target extensions to create task producers.


protocol ProductPlanBuilding
{
    func provisionalTasks(_ settings: Settings) -> [String: ProvisionalTask]
    func taskProducers(_ taskProducerContext: TargetTaskProducerContext) async -> [any TaskProducer]
}

extension Target: ProductPlanBuilding
{
    func provisionalTasks(_ settings: Settings) -> [String: ProvisionalTask]
    {
        switch self
        {
        case let target as StandardTarget:
            return target.self.standardTargetProvisionalTasks(settings)

        case let target as AggregateTarget:
            return target.self.aggregateTargetProvisionalTasks(settings)

        case let target as ExternalTarget:
            return target.self.externalTargetProvisionalTasks(settings)

        case is PackageProductTarget:
            // Package product targets have no provisional tasks.
            return [:]

        default:
            preconditionFailure("\(Swift.type(of: self)) does not know how to create TaskProducers")
        }
    }

    func taskProducers(_ taskProducerContext: TargetTaskProducerContext) async -> [any TaskProducer]
    {
        switch self
        {
        case let target as StandardTarget:
            return await target.standardTargetTaskProducers(taskProducerContext)

        case let target as AggregateTarget:
            return target.aggregateTargetTaskProducers(taskProducerContext)

        case let target as ExternalTarget:
            return target.externalTargetTaskProducers(taskProducerContext)

        case let target as PackageProductTarget:
            return target.packageProductTargetTaskProducers(taskProducerContext)

        default:
            preconditionFailure("\(Swift.type(of: self)) does not know how to create TaskProducers")
        }
    }
}

extension BuildPhaseTarget
{
    func buildPhaseTargetProvisionalTasks(_ settings: Settings) -> [String: ProvisionalTask]
    {
        let provisionalTasks = [String: ProvisionalTask]()
        // TODO: Create provisional tasks for other task producers.
        return provisionalTasks
    }

    /// The base name used by phase start and end nodes set up for task producers for this target.
    func phaseNodeRoot(_ configuredTarget: ConfiguredTarget?) -> String {
        return configuredTarget?.guid.stringValue ?? "target-\(self.name)-\(self.guid)"
    }

    /// Creates a list of task producers for the build phases in this target.  The tasks created by these producers will be ordered so that all tasks created by the producer for one phase will run before any tasks created by the producer for the next phase are run.
    ///
    /// - parameter startPhaseNode: The start phase node for tasks created by the producer of the first build phase.  If passed, then all tasks created by the producer for the first build phase will run after all tasks on which this node depends (presumably as set up by our caller).  If nil, then a new start node will be created, and the tasks will run independently of any tasks previously created by the caller.
    /// - returns: A tuple consisting of the list of task producers created, and the end phase node of the producer for the last build phase.  This end phase node can be used by the caller to order further producers to make their tasks run after the tasks for the build phases.
    func buildPhaseTargetTaskProducers(_ taskProducerContext: TargetTaskProducerContext, startPhaseNodes: [PlannedVirtualNode]? = nil) -> (taskProducers: [any TaskProducer], endPhaseNode: PlannedVirtualNode)
    {
        // All headers phases should run ahead of other phases, unless they follow an unsandboxed script.
        let earlyHeadersPhaseGUIDs: Set<String>
        if taskProducerContext.settings.globalScope.evaluate(BuiltinMacros.RESCHEDULE_INDEPENDENT_HEADERS_PHASES) {
            earlyHeadersPhaseGUIDs = Set(buildPhases.prefix(while: {
                if let shellScriptPhase = $0 as? ShellScriptBuildPhase {
                    if !taskProducerContext.settings.globalScope.evaluate(BuiltinMacros.ENABLE_USER_SCRIPT_SANDBOXING) {
                        return false
                    }
                    // FIXME: Refactor output file list parsing so we can call into it here.
                    if shellScriptPhase.outputFileListPaths.count > 0 {
                        return false
                    }
                    for outputExpr in shellScriptPhase.outputFilePaths {
                        let output = Path(taskProducerContext.settings.globalScope.evaluate(outputExpr))
                        if taskProducerContext.lookupFileType(fileName: output.basename)?.conformsToAny(taskProducerContext.compilationRequirementOutputFileTypes) == true {
                            return false
                        }
                    }
                    return true
                } else {
                    return true
                }
            }).filter({ $0 is HeadersBuildPhase }).map(\.guid))
        } else {
            earlyHeadersPhaseGUIDs = []
        }
        let orderedPhases = buildPhases.filter { earlyHeadersPhaseGUIDs.contains($0.guid) } + buildPhases.filter { !earlyHeadersPhaseGUIDs.contains($0.guid) }
        var fusedPhases: [[BuildPhase]] = []
        if let firstPhase = orderedPhases.first {
            var currentFusedPhase: [BuildPhase] = [firstPhase]
            for phase in orderedPhases.dropFirst() {
                if isValidFusedPhase(currentFusedPhase + [phase], taskProducerContext: taskProducerContext) {
                    currentFusedPhase.append(phase)
                } else {
                    fusedPhases.append(currentFusedPhase)
                    currentFusedPhase = [phase]
                }
            }
            if !currentFusedPhase.isEmpty {
                fusedPhases.append(currentFusedPhase)
            }
        }

        var taskProducers = [any TaskProducer]()

        var startPhaseNodes = startPhaseNodes ?? [taskProducerContext.createVirtualNode(phaseNodeRoot(taskProducerContext.configuredTarget) + "-start")]
        for (i, fusedPhase) in fusedPhases.enumerated()
        {
            let endFusedPhaseNode = taskProducerContext.createVirtualNode(phaseNodeRoot(taskProducerContext.configuredTarget) + "-fused-phase" + String(i) + "-" + fusedPhase.map { $0.name.asLegalRfc1034Identifier.lowercased() }.joined(separator: "&"))
            let endFusedPhaseTask = taskProducerContext.createPhaseEndTask(inputs: startPhaseNodes, output: endFusedPhaseNode, mustPrecede: [taskProducerContext.targetEndTask])

            for phase in fusedPhase {
                if let producer = taskProducer(for: phase, phaseStartNodes: startPhaseNodes, phaseEndNode: endFusedPhaseNode, phaseEndTask: endFusedPhaseTask, taskProducerContext: taskProducerContext, isFirstFusedPhase: i == 0) {
                    taskProducers.append(producer)
                }
            }

            // The start phase node for the next fused phase is the end phase node for the phase we just finished.
            startPhaseNodes = [endFusedPhaseNode]
        }

        return (taskProducers, startPhaseNodes.only!)
    }

    func isValidFusedPhase(_ proposedFusedPhase: [BuildPhase], taskProducerContext: TargetTaskProducerContext) -> Bool {
        if taskProducerContext.settings.globalScope.evaluate(BuiltinMacros.IGNORE_BUILD_PHASES) {
            return true
        }

        // Always fuse headers phases.
        if proposedFusedPhase.allSatisfy({ $0 is HeadersBuildPhase }) {
            return true
        }

        guard taskProducerContext.settings.globalScope.evaluate(BuiltinMacros.FUSE_BUILD_PHASES) else {
            return false
        }
        guard (taskProducerContext.configuredTarget?.target as? StandardTarget)?.buildRules.contains(where: {
            if case .shellScript = $0.actionSpecifier {
                return true
            } else {
                return false
            }
        }) != true || SWBFeatureFlag.allowBuildPhaseFusionWithCustomShellScriptBuildRules.value else {
            // If the target has a shell script build rule, it may not be safe to parallelize if it specifies incorrect dependencies.
            return false
        }
        if proposedFusedPhase.allSatisfy({ $0 is SourcesBuildPhase || $0 is FrameworksBuildPhase || $0 is ResourcesBuildPhase }) {
            return true
        } else if proposedFusedPhase.allSatisfy({ ($0 as? ShellScriptBuildPhase)?.hasSpecifiedDependencies == true }) {
            /// Don't attempt to run script phases in parallel with other phase types, but fuse consecutive script phases if the user has opted-in.
            return taskProducerContext.settings.globalScope.evaluate(BuiltinMacros.FUSE_BUILD_SCRIPT_PHASES)
        } else if proposedFusedPhase.allSatisfy({ $0 is CopyFilesBuildPhase }) {
            /// Don't attempt to run script phases in parallel with other phase types (bundles make dependency tracking tricky), but fuse consecutive copy phases if the feature flag is enabled.
            return SWBFeatureFlag.allowCopyFilesBuildPhaseFusion.value
        } else {
            return false
        }
    }

    func taskProducer(for phase: BuildPhase, phaseStartNodes: [PlannedVirtualNode], phaseEndNode: PlannedVirtualNode, phaseEndTask: any PlannedTask, taskProducerContext: TargetTaskProducerContext, isFirstFusedPhase: Bool) -> (any TaskProducer)? {
        switch phase
        {
        case let sourcesBuildPhase as SourcesBuildPhase:
            return SourcesTaskProducer(taskProducerContext, sourcesBuildPhase: sourcesBuildPhase, frameworksBuildPhase: self.frameworksBuildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
        case let headersBuildPhase as HeadersBuildPhase:
            return HeadersTaskProducer(taskProducerContext, buildPhase: headersBuildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask, shouldIgnorePhaseOrdering: isFirstFusedPhase)
        case let resourcesBuildPhase as ResourcesBuildPhase:
            return ResourcesTaskProducer(taskProducerContext, buildPhase: resourcesBuildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
        case let copyFilesBuildPhase as CopyFilesBuildPhase:
            return CopyFilesTaskProducer(taskProducerContext, buildPhase: copyFilesBuildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
        case let shellScriptBuildPhase as ShellScriptBuildPhase:
            return ShellScriptTaskProducer(taskProducerContext, shellScriptBuildPhase: shellScriptBuildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
        case let rezBuildPhase as RezBuildPhase:
            return RezTaskProducer(taskProducerContext, buildPhase: rezBuildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
        case let applescriptBuildPhase as AppleScriptBuildPhase:
            return AppleScriptTaskProducer(taskProducerContext, buildPhase: applescriptBuildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
        case _ as FrameworksBuildPhase:
            // The frameworks build phase is processed by the SourcesTaskProducer.
            return nil
        case _ as JavaArchiveBuildPhase:
            // We no longer support building anything with the Java Archive build phase.
            return nil
        default:
            preconditionFailure("Unrecognized build phase type '\(Swift.type(of: phase))'")
        }
    }
}

extension StandardTarget
{
    func standardTargetProvisionalTasks(_ settings: Settings) -> [String: ProvisionalTask]
    {
        var provisionalTasks = super.buildPhaseTargetProvisionalTasks(settings)

        provisionalTasks.addContents(of: ProductStructureTaskProducer.self.provisionalTasks(settings))
        // TODO: Create provisional tasks for other task producers.
        provisionalTasks.addContents(of: ProductPostprocessingTaskProducer.self.provisionalTasks(settings))

        return provisionalTasks
    }

    func standardTargetTaskProducers(_ taskProducerContext: TargetTaskProducerContext) async -> [any TaskProducer]
    {
        let taskProducerExtensions = await taskProducerExtensions(taskProducerContext.workspaceContext)

        var taskProducers = [any TaskProducer]()

        for taskProducerExtension in taskProducerExtensions {
            taskProducers += taskProducerExtension.createPreSetupTaskProducers(taskProducerContext)
        }

        // Variables to track the start and end phase nodes for the individual task producers, and a convenience method to create a new end node for the next producer, and make the start node for the next producer the end node for the previous producer.  The individual task producers will create a task which depends on the start node and has the end node as an output, and whose name is based on the end node.
        // Some producers may share start and end nodes.  This means that tasks for those producers may run concurrently, but will be ordered with respect to other producers.
        var startPhaseNode = taskProducerContext.createVirtualNode("\(phaseNodeRoot(taskProducerContext.configuredTarget))-start")
        var endPhaseNode = taskProducerContext.createVirtualNode("\(phaseNodeRoot(taskProducerContext.configuredTarget))-ProductStructureTaskProducer")
        func createNewPhaseNode(_ name: String) {
            startPhaseNode = endPhaseNode
            endPhaseNode = taskProducerContext.createVirtualNode("\(phaseNodeRoot(taskProducerContext.configuredTarget))-\(name)")
        }

        // Add setup task producers.  These are ordered with respect to each other.
        taskProducers.append(ProductStructureTaskProducer(taskProducerContext, phaseStartNodes: [startPhaseNode], phaseEndNode: endPhaseNode))

        createNewPhaseNode("GeneratedFilesTaskProducer")
        taskProducers.append(GeneratedFilesTaskProducer(taskProducerContext, phaseStartNodes: [startPhaseNode], phaseEndNode: endPhaseNode))

        createNewPhaseNode("GenerateAppPlaygroundAssetCatalogTaskProducer")
        taskProducers.append(GenerateAppPlaygroundAssetCatalogTaskProducer(taskProducerContext, phaseStartNodes: [startPhaseNode], phaseEndNode: endPhaseNode))

        createNewPhaseNode("HeadermapTaskProducer")
        taskProducers.append(HeadermapTaskProducer(taskProducerContext, phaseStartNodes: [startPhaseNode], phaseEndNode: endPhaseNode))

        // Insert task producers from extensions before the end of setup task producers as our many of our tests check the last phase node's name.
        for taskProducerExtension in taskProducerExtensions {
            for setupTaskProducerFactory in taskProducerExtension.setupTaskProducers {
                createNewPhaseNode(setupTaskProducerFactory.name)
                taskProducers.append(setupTaskProducerFactory.createTaskProducer(taskProducerContext, startPhaseNodes: [startPhaseNode], endPhaseNode: endPhaseNode))
            }
        }

        createNewPhaseNode("ModuleVerifierTaskProducer")
        taskProducers.append(ModuleVerifierTaskProducer(taskProducerContext, phaseStartNodes: [startPhaseNode], phaseEndNode: endPhaseNode))

        let setupEndPhaseNode = endPhaseNode
        var postprocessingTaskProducerInputNodes = [setupEndPhaseNode]

        // Add build phase task producers.  These are ordered after the setup task producers.
        let (buildPhaseTaskProducers, buildPhasesEndNode) = super.buildPhaseTargetTaskProducers(taskProducerContext, startPhaseNodes: [endPhaseNode])
        taskProducers.append(contentsOf: buildPhaseTaskProducers)
        endPhaseNode = buildPhasesEndNode
        postprocessingTaskProducerInputNodes.append(buildPhasesEndNode)

        // Add other product building task producers.  These are ordered after the setup task producers, but not with respect to the build phase task producers or with respect to each other.
        // Be careful of defining unnecessary orderings here, as it can lead to dependency cycles.
        // FIXME: Some of these task producers surely need to be ordered with respect to certain others, while others don't need to be.

        let copyHeadersCompletionTasks = buildPhaseTaskProducers.compactMap({ ($0 as? SourcesTaskProducer)?.copyHeadersCompletionTask })
        createNewPhaseNode("ModuleMapTaskProducer")
        taskProducers.append(ModuleMapTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode, copyHeadersCompletionTasks: copyHeadersCompletionTasks))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("SwiftPackageCopyFilesTaskProducer")
        let packageCopyFilesEndPhaseTask = taskProducerContext.createPhaseEndTask(inputs: [setupEndPhaseNode], output: endPhaseNode, mustPrecede: [taskProducerContext.targetEndTask])
        taskProducers.append(SwiftPackageCopyFilesTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode, phaseEndTask: packageCopyFilesEndPhaseTask, frameworksBuildPhase: self.frameworksBuildPhase))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("InfoPlistTaskProducer")
        taskProducers.append(InfoPlistTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("SanitizerTaskProducer")
        taskProducers.append(SanitizerTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("SwiftStandardLibrariesTaskProducer")
        taskProducers.append(SwiftStandardLibrariesTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode, buildPhasesEndNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("SwiftFrameworkABICheckerTaskProducer")
        taskProducers.append(SwiftFrameworkABICheckerTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode, buildPhasesEndNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("SwiftABIBaselineGenerationTaskProducer")
        taskProducers.append(SwiftABIBaselineGenerationTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode, buildPhasesEndNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("TestTargetTaskProducer")
        taskProducers.append(XCTestProductTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("TestHostTaskProducer")
        taskProducers.append(XCTestHostTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("CopySwiftPackageResourcesTaskProducer")
        taskProducers.append(CopySwiftPackageResourcesTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("TAPISymbolExtractorTaskProducer")
        taskProducers.append(TAPISymbolExtractorTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("DocumentationTaskProducer")
        taskProducers.append(DocumentationTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        createNewPhaseNode("CustomTaskProducer")
        taskProducers.append(CustomTaskProducer(taskProducerContext, phaseStartNodes: [setupEndPhaseNode], phaseEndNode: endPhaseNode))
        postprocessingTaskProducerInputNodes.append(endPhaseNode)

        for taskProducerExtension in taskProducerExtensions {
            for factory in taskProducerExtension.unorderedPostSetupTaskProducers {
                createNewPhaseNode(factory.name)
                taskProducers.append(factory.createTaskProducer(taskProducerContext, startPhaseNodes: [setupEndPhaseNode], endPhaseNode: endPhaseNode))
                postprocessingTaskProducerInputNodes.append(endPhaseNode)
            }

            for factory in taskProducerExtension.unorderedPostBuildPhasesTaskProducers {
                createNewPhaseNode(factory.name)
                taskProducers.append(factory.createTaskProducer(taskProducerContext, startPhaseNodes: [setupEndPhaseNode, buildPhasesEndNode], endPhaseNode: endPhaseNode))
                postprocessingTaskProducerInputNodes.append(endPhaseNode)
            }
        }

        // Add postprocessing task producers.  These are ordered after all of the other task producers.
        createNewPhaseNode("ProductPostprocessingTaskProducer")
        taskProducers.append(ProductPostprocessingTaskProducer(taskProducerContext, phaseStartNodes: postprocessingTaskProducerInputNodes, phaseEndNode: endPhaseNode))

        // Add the postprocessing task producer for XCTest targets.  These tasks involve assembling or modifying content outside of the test target's own product, often in an enclosing wrapper (the application being tested, or the test runner), so this producer is ordered after the test target's own postprocessing task producer.
        createNewPhaseNode("TestTargetPostprocessingTaskProducer")
        taskProducers.append(XCTestProductPostprocessingTaskProducer(taskProducerContext, phaseStartNodes: [startPhaseNode], phaseEndNode: endPhaseNode))

        return taskProducers
    }
}

extension AggregateTarget
{
    func aggregateTargetProvisionalTasks(_ settings: Settings) -> [String: ProvisionalTask]
    {
        // TODO: We should probably check that only build phases useful in an aggregate target are present here.
        return super.buildPhaseTargetProvisionalTasks(settings)
    }

    func aggregateTargetTaskProducers(_ taskProducerContext: TargetTaskProducerContext) -> [any TaskProducer]
    {
        // TODO: We should probably check that only build phases useful in an aggregate target are present here.
        return super.buildPhaseTargetTaskProducers(taskProducerContext).taskProducers
    }
}

extension ExternalTarget
{
    func externalTargetProvisionalTasks(_ settings: Settings) -> [String: ProvisionalTask]
    {
        // External targets have no provisional tasks.
        return [:]
    }

    func externalTargetTaskProducers(_ taskProducerContext: TaskProducerContext) -> [any TaskProducer]
    {
        if !customTasks.isEmpty {
            taskProducerContext.error("custom tasks are not yet supported in external targets")
        }
        return [ExternalTargetTaskProducer(taskProducerContext)]
    }
}

extension PackageProductTarget
{
    func packageProductTargetTaskProducers(_ taskProducerContext: TargetTaskProducerContext) -> [any TaskProducer]
    {
        if !customTasks.isEmpty {
            taskProducerContext.error("custom tasks are not yet supported in package product targets")
        }
        return []
    }

    func phaseNodeRoot(_ configuredTarget: ConfiguredTarget?) -> String {
        return configuredTarget?.guid.stringValue ?? "target-\(self.name)-\(self.guid)"
    }
}
