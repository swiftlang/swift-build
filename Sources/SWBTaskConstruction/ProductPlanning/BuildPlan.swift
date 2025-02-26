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

/// Information describing a complete build plan request.
package struct BuildPlanRequest: Sendable {
    /// The workspace the plan is being generated for.
    package let workspaceContext: WorkspaceContext

    /// The build request which triggered the plan.
    package let buildRequest: BuildRequest

    /// Context relevant to the lifetime of the build request which triggered the plan.
    package let buildRequestContext: BuildRequestContext

    /// The computed build graph of the targets.
    package let buildGraph: TargetBuildGraph

    /// The map of available provisioning inputs.
    package let provisioningInputs: [ConfiguredTarget: ProvisioningTaskInputs]

    /// Create a new build plan request.
    ///
    /// - Parameters:
    ///   - workspaceContext: The workspace used by the plan.
    ///   - buildRequest: The build request which triggered the plan.
    ///   - buildRequestContext: Context relevant to the lifetime of the build request which triggered the plan.
    ///   - buildGraph: The complete graph of targets to include in the plan.
    ///   - provisioningInputs: The provisioning inputs to use for each target, if available. This map does not need to include entries for all targets, if omitted that target is simply assumed not to have provisioning input data (i.e., not sign).
    package init(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, buildGraph: TargetBuildGraph, provisioningInputs: [ConfiguredTarget: ProvisioningTaskInputs]) {
        self.workspaceContext = workspaceContext
        self.buildRequest = buildRequest
        self.buildRequestContext = buildRequestContext
        self.buildGraph = buildGraph
        self.provisioningInputs = provisioningInputs
    }

    /// Get the provisioning inputs for the given `target`.
    package func provisioningInputs(for target: ConfiguredTarget) -> ProvisioningTaskInputs {
        return provisioningInputs[target] ?? ProvisioningTaskInputs()
    }
}

/// Describes the concrete products that need to be produced as part of a build.
///
/// This object is used to capture the result of the planning process for a particular build request, and to provide access to the complete set of tasks that need to be performed for the build.
package final class BuildPlan: StaleFileRemovalContext {
    /// Information on the global build plan.
    package let globalProductPlan: GlobalProductPlan

    /// The workspace the plan is being generated for.
    package let workspaceContext: WorkspaceContext

    /// The list of product plans produced by this build.
    package let productPlans: [ProductPlan]

    /// The set of tasks to execute for this build plan.
    package let tasks: [any PlannedTask]

    /// The list of external paths which contribute to the build plan and will invalidate the build description.
    package let invalidationPaths: [Path]

    /// Map of the files which are copied during the build, used for mapping diagnostics.
    package let copiedPathMap: [String: String]

    /// The list of recursive search path requests used in construction.
    package let recursiveSearchPathResults: [RecursiveSearchPathResolver.CachedResult]

    package let emitFrontendCommandLines: Bool

    /// Create the build plan for a particular request.
    ///
    /// This will cause the actual construction of all of the product plans and tasks.
    ///
    /// - Returns: The build plan, or nil if cancelled during construction.
    package init?(planRequest: BuildPlanRequest, taskPlanningDelegate delegate: any TaskPlanningDelegate) async {
        // Create a planner to produce the actual product plans.
        let planner = ProductPlanner(planRequest: planRequest, taskPlanningDelegate: delegate)

        // Create the queues to produce and aggregate the tasks.
        let aggregationQueue = SWBQueue(label: "SWBTaskConstruction.BuildPlan.aggregationQueue", qos: planRequest.buildRequest.qos, autoreleaseFrequency: .workItem)

        // Compute a collated list of result contexts and task producers, so we can do a single parallel dispatch.
        //
        // This computation is cheap, so this is overall more efficient than trying to interleave them with our current infrastructure.
        let messageShortening =  planRequest.workspaceContext.userPreferences.activityTextShorteningLevel
        let (productPlans, globalProductPlan) = await planner.productPlans()
        let productPlanResultContexts = productPlans.map{ ProductPlanResultContext(for: $0) }
        let producersToEvaluate = productPlanResultContexts.flatMap{ context in
            return context.productPlan.taskProducers.map{ (resultContext: context, producer: $0) }
        }

        // Due to the nature of task producers having no relationship with respect to ordering amongst other task producers, it is necessary to allow task producers within a particular context to build up any information that may be necessary for other task producers to consume. It is important to note that this mechanism is not intended to share information across individual task producers, but rather, it is to be used to build up contextual information that can be used from the `generateTasks()` phase.
        // Another way to state the sharing relationship:
        //   - `prepare()` is invoked
        //   - data can be populated into the shared context for the target; no order is implied or given for any task producer in this phase
        //   - `generateTasks()` is invoked
        //   - data can be read from the shared context for the target: IMPORTANT!! A task producer should not directly try to access any state on any other task producer.

        // Start with the `planning` phase.
        for context in productPlanResultContexts {
            context.productPlan.taskProducerContext.phase = .planning
        }
        await withTaskGroup(of: Void.self) { group in
            let (progressStream, progressContinuation) = AsyncStream<Void>.makeStream()

            group.addTask {
                var preplannedCount = 0
                for await _ in progressStream {
                    preplannedCount += 1
                    let statusMessage = messageShortening >= .allDynamicText
                        ? "Pre-planning \(activityMessageFractionString(preplannedCount, over: producersToEvaluate.count))"
                        : "Pre-Planning from \(preplannedCount) of \(producersToEvaluate.count) task producers"

                    delegate.updateProgress(statusMessage: statusMessage, showInLog: false)

                    if preplannedCount >= producersToEvaluate.count {
                        progressContinuation.finish()
                    }
                }
            }

            await producersToEvaluate.parallelForEach(group: &group, maximumParallelism: 100) { _, producer in
                progressContinuation.yield(())
                if delegate.cancelled { return }
                await producer.prepare()
            }

            // Wait for the pre-planning to be done so that we can move on to constructing the real tasks.
            await group.waitForAll()
        }

        if delegate.cancelled {
            return nil
        }

        // Move on to the `taskGeneration` phase.
        for context in productPlanResultContexts {
            context.productPlan.taskProducerContext.phase = .taskGeneration
        }
        await withTaskGroup(of: Void.self) { group in
            let (progressStream, progressContinuation) = AsyncStream<Void>.makeStream()

            group.addTask {
                var evaluatedCount = 0
                for await _ in progressStream {
                    evaluatedCount += 1
                    let statusMessage = messageShortening >= .allDynamicText
                        ? "Planning \(activityMessageFractionString(evaluatedCount, over: producersToEvaluate.count))"
                        : "Constructing from \(evaluatedCount) of \(producersToEvaluate.count) task producers"

                    delegate.updateProgress(statusMessage: statusMessage, showInLog: false)

                    if evaluatedCount >= producersToEvaluate.count {
                        progressContinuation.finish()
                    }
                }
            }

            await producersToEvaluate.parallelForEach(group: &group, maximumParallelism: 100) { productPlanResultContext, producer in
                progressContinuation.yield(())
                if delegate.cancelled { return }

                // FIXME: Change this API to just return an array for now.
                let tasks = await Array(producer.generateTasks())
                aggregationQueue.async {
                    productPlanResultContext.addPlannedTasks(tasks)
                }
            }

            // Wait for task production.
            await group.waitForAll()
        }

        await aggregationQueue.sync{ }
        if delegate.cancelled {
            // Reset any deferred producers, which may participate in cycles.
            for context in productPlanResultContexts {
                _ = context.productPlan.taskProducerContext.takeDeferredProducers()
            }
            return nil
        }

        // Now that tasks have been generated, aggregate the invalidation paths
        let invalidationPaths = Set(producersToEvaluate.flatMap { $0.producer.invalidationPaths })

        // Compute all of the deferred tasks (in parallel).
        delegate.updateProgress(statusMessage: messageShortening == .full ? "Planning deferred tasks" : "Constructing deferred tasks", showInLog: false)
        await TaskGroup.concurrentPerform(iterations: productPlanResultContexts.count, maximumParallelism: 10) { i in
            let productPlanResultContext = productPlanResultContexts[i]
            let plan = productPlanResultContext.productPlan
            plan.taskProducerContext.outputsOfMainTaskProducers = productPlanResultContext.outputNodes
            let deferredProducers = plan.taskProducerContext.takeDeferredProducers()

            if delegate.cancelled { return }
            await TaskGroup.concurrentPerform(iterations: deferredProducers.count, maximumParallelism: 10) { i in
                let tasks = await deferredProducers[i]()
                aggregationQueue.async {
                    productPlanResultContext.addPlannedTasks(tasks)
                }
            }
        }

        // Wait for product plan aggregation.
        await aggregationQueue.sync {}
        if delegate.cancelled {
            return nil
        }

        // Now we have a list of product plan result contexts, each of which contains a list of all planned tasks for each plan, as well as the information needed to validate the provisional tasks in the plan.
        // Since these contexts are independent of each other, we can in parallel have each one validate its provisional tasks, and then serially add the tasks it ends up with to a final task array.
        delegate.updateProgress(statusMessage: messageShortening == .full ? "Finalizing plan" : "Finalizing provisional tasks", showInLog: false)
        let tasks = await withTaskGroup(of: [any PlannedTask].self) { group in
            for resultContext in productPlanResultContexts {
                group.addTask {
                    if delegate.cancelled { return [] }

                    // Get the list of effective planned tasks for the product plan (validating any provisional tasks).
                    return await aggregationQueue.sync { resultContext.plannedTasks }
                }
            }

            // Serially add the tasks for this product plan to the array for the whole build request.
            return await group.reduce(into: [], { $0.append(contentsOf: $1) })
        }

        // Wait for provisional task validation.
        await aggregationQueue.sync{ }
        if delegate.cancelled {
            return nil
        }

        // Harvest issues from the task producers' contexts.
        // FIXME: There will typically be a dozen or more task producers which share a context - all producers for a target share the same context - so it would be nice to have a more direct way to get that list than this.
        let taskProducerContexts = Set<TaskProducerContext>(producersToEvaluate.map({ $0.producer.context }))
        for context in taskProducerContexts {
            let diagnosticContext: TargetDiagnosticContext = context.configuredTarget.map { .overrideTarget($0) } ?? .default
            for note in context.notes {
                delegate.note(diagnosticContext, note)
            }
            for warning in context.warnings {
                delegate.warning(diagnosticContext, warning)
            }
            for error in context.errors {
                delegate.error(diagnosticContext, error)
            }
        }

        // If any tasks have conflicting identifiers, emit errors and exclude the duplicates
        let tasksByIdentifier = Dictionary<TaskIdentifier, [any PlannedTask]>(tasks.map { ($0.identifier, [$0]) }, uniquingKeysWith: +)
        let tasksWithoutDuplicates: [any PlannedTask] = tasksByIdentifier.values.compactMap { tasks in
            if tasks.count > 1 {
                BuildPlan.unexpectedDuplicateTasksWithIdentifier(tasks, planRequest.workspaceContext.workspace, delegate)
            }

            // Return just the first task, ignoring any subsequent duplicates.
            return tasks[0]
        }

        // Collect and merge the copied path map from all task producers.
        // We ignore duplicate values because the build graph prohibits multiple tasks from producing the same output
        // anyways, and a "multiple commands produce" error will be emitted later accordingly.
        let copiedPathMaps = productPlanResultContexts.map { $0.productPlan.taskProducerContext.copiedPathMap() }
        let copiedPathMap = Dictionary(merging: copiedPathMaps, uniquingKeysWith: { old, new in old.union(new) }).compactMapValues(\.only)

        // Store the results.
        self.globalProductPlan = globalProductPlan
        self.workspaceContext = planRequest.workspaceContext
        self.productPlans = productPlans
        self.tasks = tasksWithoutDuplicates
        self.invalidationPaths = Array(invalidationPaths.sorted(by: \.str))
        self.recursiveSearchPathResults = globalProductPlan.recursiveSearchPathResolver.allResults
        self.copiedPathMap = copiedPathMap
        self.emitFrontendCommandLines = productPlanResultContexts.map { $0.productPlan.taskProducerContext.emitFrontendCommandLines }.reduce(false, { $0 || $1 })
    }

    static func unexpectedDuplicateTasksWithIdentifier(_ tasks: [any PlannedTask], _ workspace: Workspace, _ delegate: any TaskPlanningDelegate) {
        delegate.emit(Diagnostic(behavior: .error,
                                 location: .unknown,
                                 data: DiagnosticData("Unexpected duplicate tasks"),
                                 childDiagnostics: tasks.map({ .task($0.execTask) }).richFormattedRuleInfo(workspace: workspace)))
    }
}



/// This context stores the results of task generation for a product plan.  It is used by a build plan to collect results of task generation, and once task generation is complete to compute the final set of planned tasks to be used for a product plan by nullifying the tasks for any provisional tasks which were not fulfilled.
///
/// This class is not thread-safe; the build plan is expected to build up the context in a manner that accounts for that.
private final class ProductPlanResultContext: ProvisionalTaskValidationContext, CustomStringConvertible {
    fileprivate let productPlan: ProductPlan

    private let targetName: String

    /// All planned tasks for the product plan.
    private var allPlannedTasks: Set<Ref<any PlannedTask>>

    /// All provisional tasks for the product plan.
    private var provisionalTasks: [ProvisionalTask]

    /// The set of paths which have been declared as inputs to one or more tasks.  Inputs of tasks which have fulfilled provisional tasks are not included in this set (unless they're also the input to a non-provisional task).
    fileprivate private(set) var inputPaths: Set<Path>

    /// The set of paths which have been declared as outputs of one or more tasks.  Outputs of tasks which have fulfilled provisional tasks are not included in this set.
    fileprivate private(set) var outputPaths: Set<Path>

    /// The set of paths which have been declared as inputs to one or more tasks, plus all of their ancestor directories.  Inputs of tasks which have fulfilled provisional tasks are not included in this set (unless they're also the input to a non-provisional task).
    fileprivate private(set) var inputPathsAndAncestors: Set<Path>

    /// The set of paths which have been declared as outputs of one or more tasks, plus all of their ancestor directories.  Outputs of tasks which have fulfilled provisional tasks are not included in this set.
    fileprivate private(set) var outputPathsAndAncestors: Set<Path>

    /// The effective planned tasks for the product plan, with planned tasks for unneeded provisional tasks removed.
    lazy fileprivate private(set) var plannedTasks: [any PlannedTask] = {
        // Create a copy of allPlannedTasks to work with.
        var plannedTasks = self.allPlannedTasks

        // Go through the provisional tasks.  For each one that has a task which is *not* valid, remove it from our working set.
        for provisionalTask in self.provisionalTasks {
            if !provisionalTask.isValid(self) {
                if let plannedTask = provisionalTask.plannedTask {
                    plannedTasks.remove(Ref(plannedTask))
                }
            }
        }

        return plannedTasks.map{ $0.instance }
    }()

    fileprivate var outputNodes: [any PlannedNode] {
        return allPlannedTasks.flatMap { $0.instance.outputs }
    }

    init(for productPlan: ProductPlan) {
        self.productPlan = productPlan
        self.targetName = productPlan.forTarget != nil ? productPlan.forTarget!.target.name : "no target"
        self.allPlannedTasks = Set<Ref<any PlannedTask>>()
        self.inputPaths = Set<Path>()
        self.outputPaths = Set<Path>()
        self.inputPathsAndAncestors = Set<Path>()
        self.outputPathsAndAncestors = Set<Path>()

        // Gather the provisional tasks from the context of the task producers of the product plan.  Note that since all task producers share a context, we only have to use the first producer's context.
        self.provisionalTasks = [ProvisionalTask]()
        if let taskProducer = productPlan.taskProducers.first {
            self.provisionalTasks += taskProducer.context.provisionalTasks.values
        }
    }

    func addPlannedTask(_ plannedTask: any PlannedTask) {
        allPlannedTasks.insert(Ref(plannedTask))

        // Add the task's inputs and outputs to the result context.  However, we only do this if the task is not the assigned task for a provisional task, because we don't want (for example) a provisional task to be considered valid because some other provisional task was created, only to have the latter be considered invalid, and thus the first one having been improperly validated.
        if plannedTask.provisionalTask == nil {
            for input in plannedTask.inputs {
                addInputPath(input.path)
            }
            for output in plannedTask.outputs {
                addOutputPath(output.path)
            }
        }
    }

    func addPlannedTasks(_ plannedTasks: [any PlannedTask]) {
        for plannedTask in plannedTasks {
            self.addPlannedTask(plannedTask)
        }
    }

    /// Private method to add a path and its ancestor paths to the given set.
    private func addPathAndAncestors(_ path: Path, toSet set: inout Set<Path>) {
        guard !path.isEmpty else { return }

        // Add the path to the set.  If it's not already in the set, then we try to add its parent.  (This order means that when we get to '/' we will stop.)
        guard set.insert(path).inserted else { return }
        addPathAndAncestors(path.dirname, toSet: &set)
    }

    /// Private method to record an input path of a task in the result context.
    private func addInputPath(_ path: Path) {
        // Add this path to the set of input paths explicitly declared as outputs of tasks.
        guard inputPaths.insert(path).inserted else { return }
        // Add this path and its ancestors to the set of input-paths-and-ancestors.
        addPathAndAncestors(path, toSet: &inputPathsAndAncestors)
    }

    /// Private method to record an output path of a task in the result context.
    private func addOutputPath(_ path: Path) {
        // Add this path to the set of output paths explicitly declared as outputs of tasks.
        guard outputPaths.insert(path).inserted else { return }
        // Add this path and its ancestors to the set of output-paths-and-ancestors.
        addPathAndAncestors(path, toSet: &outputPathsAndAncestors)
    }

}

private extension ProductPlanResultContext {
    var description: String {
        return "\(type(of: self))<\(self.targetName)>"
    }
}
