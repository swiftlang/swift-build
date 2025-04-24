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

/// Wrapper for capturing the task information needed for the `TargetOrderTaskProducer`.
///
/// The `GlobalProductPlan` contains a map of `ConfiguredTarget`s to `TargetTaskInfo`s.
final class TargetTaskInfo {
    /// A virtual node representing the start of the overall target.
    ///
    /// All tasks in the target depend on this node having been built.
    let startNode: any PlannedNode

    /// A virtual node representing the end of overall target.
    ///
    /// This node depends on all of the tasks in the target.
    let endNode: any PlannedNode

    /// A virtual node representing the start of compiling source code for the target.
    ///
    /// Any tasks that compile sources depend on this node having been built.
    let startCompilingNode: any PlannedNode

    /// A virtual node representing the start of linking the target.
    ///
    /// Any tasks involving linking depend on this node having been built.
    let startLinkingNode: any PlannedNode

    /// A virtual node representing the start of scanning the target.
    ///
    /// Any tasks involving scanning depend on this node having been built.
    let startScanningNode: any PlannedNode

    /// A virtual node representing the end of preparing modules or headers for dependent targets.
    ///
    /// This node depends on all tasks in this target which produce modules or copy headers in place.
    let modulesReadyNode: any PlannedNode

    /// A virtual node representing the end of generating linker inputs for dependent targets.
    ///
    /// This node depends on tasks which produce linker inputs.
    let linkerInputsReadyNode: any PlannedNode

    /// A virtual node representing the end of scanning (libclang or Swift driver) for dependent targets.
    ///
    /// This node depends on tasks which produce scanning inputs.
    let scanInputsReadyNode: any PlannedNode

    /// A virtual node representing when tasks that can start immediately will actually start.
    ///
    /// This allows us to disable tasks starting immediately for targets that want to opt-out of eager compilation.
    let startImmediateNode: any PlannedNode

    /// A virtual node representing that the target's product has essentially been built, but it has not yet been signed.
    ///
    /// When *not* performing eager compilation, this allows us to order tasks of targets which depend on this target after this node, but before the task which signs this target's product (as represented by the `willSignNode`).
    let unsignedProductReadyNode: any PlannedNode

    /// A virtual node representing that a target will be code signing its product in a later task.
    ///
    /// This allows us to order tasks - especially tasks from other targets which depend on this target - before this node so that they run before the target's product is signed.  For example, targets which are building their own products directly into the target.
    let willSignNode: any PlannedNode

    /// A path node representing the tasks necessary to 'prepare-for-index' a target, before any compilation can occur.
    /// This is only set for an index build.
    let preparedForIndexPreCompilationNode: (any PlannedNode)?

    /// A path node representing the tasks necessary to 'prepare-for-index' module content output of a target.
    /// This is only set for an index build.
    let preparedForIndexModuleContentNode: (any PlannedNode)?

    init(startNode: any PlannedNode, endNode: any PlannedNode, startCompilingNode: (any PlannedNode)? = nil, startLinkingNode: (any PlannedNode)? = nil, startScanningNode: (any PlannedNode)? = nil, modulesReadyNode: (any PlannedNode)? = nil, linkerInputsReadyNode: (any PlannedNode)? = nil, scanInputsReadyNode: (any PlannedNode)? = nil, startImmediateNode: (any PlannedNode)? = nil, unsignedProductReadyNode: any PlannedNode, willSignNode: any PlannedNode, preparedForIndexPreCompilationNode: (any PlannedNode)? = nil, preparedForIndexModuleContentNode: (any PlannedNode)? = nil) {
        self.startNode = startNode
        self.endNode = endNode
        self.startCompilingNode = startCompilingNode ?? startNode
        self.startLinkingNode = startLinkingNode ?? startNode
        self.startScanningNode = startScanningNode ?? startNode
        self.modulesReadyNode = modulesReadyNode ?? endNode
        self.linkerInputsReadyNode = linkerInputsReadyNode ?? endNode
        self.scanInputsReadyNode = scanInputsReadyNode ?? endNode
        self.startImmediateNode = startImmediateNode ?? startNode
        self.unsignedProductReadyNode = unsignedProductReadyNode
        self.willSignNode = willSignNode
        self.preparedForIndexPreCompilationNode = preparedForIndexPreCompilationNode
        self.preparedForIndexModuleContentNode = preparedForIndexModuleContentNode
    }
}

/// Task producer for the gate tasks for a single target that are used to enforce the ordering of tasks within and across targets.
final class TargetOrderTaskProducer: StandardTaskProducer, TaskProducer {
    let targetTaskInfo: TargetTaskInfo

    let targetContext: TargetTaskProducerContext

    init(_ context: TargetTaskProducerContext, targetTaskInfo: TargetTaskInfo) {
        self.targetTaskInfo = targetTaskInfo
        self.targetContext = context
        super.init(context)
    }

    func prepare() async {
        if let preparedForIndexModuleNode = targetTaskInfo.preparedForIndexModuleContentNode {
            precondition(context.preparedForIndexModuleContentTasks.isEmpty)
            await appendGeneratedTasks(&context.preparedForIndexModuleContentTasks) { delegate in
                let outputPath = preparedForIndexModuleNode.path
                let cbc = CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], outputs: [outputPath])
                context.writeFileSpec.constructFileTasks(cbc, delegate, ruleName: ProductPlan.preparedForIndexModuleContentRuleName, contents: [], permissions: nil, forceWrite: true, preparesForIndexing: true, additionalTaskOrderingOptions: [])
            }
        }
    }

    func generateTasks() -> [any PlannedTask] {
        return [
            createTargetBeginTask(),
            targetContext.targetEndTask,
            createStartCompilingTask(),
            createStartLinkingTask(),
            createStartScanningTask(),
            targetContext.modulesReadyTask,
            targetContext.linkerInputsReadyTask,
            createStartImmediateTask(),
            targetContext.unsignedProductReadyTask,
            targetContext.willSignTask,
        ] + context.preparedForIndexModuleContentTasks + context.phaseEndTasks
    }

    /// Creates the target-begin task for the target, which all tasks in the target are ordered after.
    ///
    /// It depends on the exit nodes of all targets the target depends on, and has the target's own start node as its output.
    private func createTargetBeginTask() -> any PlannedTask {
        return createStartTask(lookupTargetExitNode, output: targetTaskInfo.startNode)
    }

    /// Creates the start-compiling task for the target, which all `compilation` tasks in the target are ordered after.
    ///
    /// It depends on one of two sets of things:
    ///
    /// - If eager compilation is enabled, then it depends on the modules-ready nodes of targets the target depends on (unless `EAGER_COMPILATION_DISABLE` is enabled for that target, in which case it depends on the exit node for that target). This is how the target's `compilation` tasks are ordered  after the header and module producing commands of targets it depends on, allowing them to start running when upstream targets still have some work (such as linking) to do.
    /// - If eager compilation is disabled, then it depends on the exit nodes for all targets the target depends on.
    ///
    /// It has the target's own start-compiling node as its output.
    private func createStartCompilingTask() -> any PlannedTask {
        let lookup = allowEagerCompilation ? lookupModulesReadyNode : lookupTargetExitNode
        return createStartTask(lookup, output: targetTaskInfo.startCompilingNode)
    }

    /// Creates the start-linking task for the target, which all `linking` tasks in the target are ordered after.
    ///
    /// It depends on one of two sets of things:
    ///
    /// - If eager linking is enabled, then it depends on the linker-inputs-ready nodes of targets the target depends on (unless eager compilation is disabled for that target, in which case it depends on the exit node for that target).
    /// - If eager compilation is disabled, then it depends on the exit nodes for all targets the target depends on.
    ///
    /// It has the target's own start-compiling node as its output.
    private func createStartLinkingTask() -> any PlannedTask {
        let lookup = allowEagerLinking ? lookupLinkerInputsReadyNode : lookupTargetExitNode
        return createStartTask(lookup, output: targetTaskInfo.startLinkingNode)
    }

    private func createStartScanningTask() -> any PlannedTask {
        createStartTask(lookupScanningInputsReadyNode, output: targetTaskInfo.startScanningNode)
    }

    /// Creates the start-immediate task for the target.
    ///
    /// It depends on one of two sets of things:
    ///
    /// - If eager compilation is enabled, then it has no dependencies on targets the target depends on. This is how tasks such as create-directory tasks for all targets all run at the beginning of the build.
    /// - If eager compilation is disabled, then it depends on the exit nodes for all targets the target depends on. This orders the immediate tasks after all tasks for those dependencies.
    ///
    /// It has the target's own start-immediate node as its output.
    private func createStartImmediateTask() -> any PlannedTask {
        let lookup = allowEagerCompilation ? { (_, _) in nil } : lookupTargetExitNode
        return createStartTask(lookup, output: targetTaskInfo.startImmediateNode)
    }

    /// Utility method to create one of several kinds of start tasks for the target.
    /// - parameter inputLookup: A closure passed to look up the input dependencies for the start task.
    /// - parameter output: The output node for the start task.
    private func createStartTask(_ inputLookup: (ConfiguredTarget, ConfiguredTarget) -> (any PlannedNode)?, output: any PlannedNode) -> any PlannedTask {
        var (inputs, resolvedTargetDependencies) = inputsForDependencies(inputLookup)

        if let node = staleFileRemovalNode {
            inputs.append(node)
        }

        // Only depend on build directory creation for standard targets.
        if configuredTarget.target.type == .standard {
            let workspaceContext = context.globalProductPlan.planRequest.workspaceContext
            let settings = context.globalProductPlan.getTargetSettings(configuredTarget)
            for macro in workspaceContext.buildDirectoryMacros {
                inputs.append(context.createVirtualNode("CreateBuildDirectory-\(settings.globalScope.evaluate(macro).str)"))
            }

            inputs.append(contentsOf: context.globalProductPlan.xcframeworkContext.outputFiles(for: configuredTarget).map(context.createNode))
        }

        return context.createGateTask(inputs, output: output, taskConfiguration: {
            $0.forTarget = context.configuredTarget
            $0.makeGate()
            $0.targetDependencies = resolvedTargetDependencies
        })
    }

    private var _allowEagerCompilation: Bool?

    /// Private convenience method to check whether eager compilation is enabled, and to emit earnings if problems with eager compilation configuration are detected. The purpose of this method is to only emit those warnings once per target.
    private var allowEagerCompilation: Bool {
        guard let allowEagerCompilation = _allowEagerCompilation else {
            _allowEagerCompilation = checkAllowEagerCompilation()
            return _allowEagerCompilation!
        }

        return allowEagerCompilation
    }

    /// Private method to do the actual work of `allowEagerCompilation()`.
    private func checkAllowEagerCompilation() -> Bool {
        let scope = context.settings.globalScope

        guard context.globalProductPlan.planRequest.buildGraph.targetsBuildInParallel else {
            if context.requiresEagerCompilation(scope) {
                context.warning("target '\(context.settings.target!.name)' requires eager compilation, but parallel target builds are disabled, which prevent eager compilation")
            }
            return false
        }

        // An individual target can opt-out of eager compilation.
        guard !scope.evaluate(BuiltinMacros.EAGER_COMPILATION_DISABLE) else {
            if context.requiresEagerCompilation(scope) {
                context.warning("target '\(context.settings.target!.name)' has both required and disabled eager compilation")
            }
            return false
        }

        // Targets using DEPLOYMENT_LOCATION may create their product structure inside another target's product.
        // This will cause issues when signing that target, so attempt to detect these configurations and disable eager compilation.
        if scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION), let configuredTarget = context.configuredTarget, let enclosingTarget = context.globalProductPlan.targetToProducingTargetForNearestEnclosingProduct[configuredTarget] {
            if context.requiresEagerCompilation(scope) {
                context.warning("target '\(context.settings.target!.name)' requires eager compilation, but DEPLOYMENT_LOCATION is set and the build directory of '\(enclosingTarget.target.name)' encloses the build directory of '\(context.settings.target!.name)'.")
            }
            return false
        }

        return true
    }

    private lazy var allowEagerLinking: Bool = {
        let scope = context.settings.globalScope

        // Eager compilation is a prerequisite for eager linking.
        guard allowEagerCompilation else {
            if context.requiresEagerLinking(scope) {
                context.warning("target '\(context.settings.target!.name)' requires eager linking, but eager compilation is disabled")
            }
            return false
        }

        // An individual target can opt-out of eager linking.
        // During development, this setting defaults to true when empty.
        guard scope.evaluate(BuiltinMacros.EAGER_LINKING) else {
            if context.requiresEagerLinking(scope) {
                context.warning("target '\(context.settings.target!.name)' has both required and disabled eager linking")
            }
            return false
        }

        return true
    }()

    /// Workhorse utility method for computing the input node for use for immediate depended-on (upstream) targets of a target.
    /// - parameter lookup: A lookup method which takes a `ConfiguredTarget` and returns an input `PlannedNode`, or nil if there are no inputs.
    /// - returns: A tuple of synchronized lists of input `PlannedNode`s and their corresponding `ConfiguredTarget`s
    private func inputsForDependencies(_ lookup: (ConfiguredTarget, ConfiguredTarget) -> (any PlannedNode)?) -> (inputs: [any PlannedNode], resolvedTargetDependencies: [ResolvedTargetDependency]) {
        // The inputs are (the appropriate gate nodes from the lookup closure of) all of the targets the configuredTarget immediately depends on.  This is a superset of the dependencies, which are all of the immediate (explicit + implicit) targets the configuredTarget is declared to depend on.
        var inputs = [any PlannedNode]()
        let dependencies = context.globalProductPlan.resolvedDependencies(of: configuredTarget)
        for dependency in dependencies  {
            if dependency.target !== configuredTarget {
                // FIXME: If lookup() returns nil here, doesn't this mean the two lists we return will be out-of-sync?  Is that bad?
                if let input = lookup(dependency.target, configuredTarget) {
                    inputs.append(input)
                }
            }
        }

        // If we are building targets serially, then add the exit node of the previous target to the inputs.
        //
        // FIXME: Figure out where this really belongs.
        if !context.globalProductPlan.planRequest.buildGraph.targetsBuildInParallel {
            // If this is a hosted target, then we only order it with respect to other targets hosted by the same target, since they are built interleaved with tasks from the hosting target.
            if let hostTarget = context.globalProductPlan.hostTargetForTargets[configuredTarget] {
                if let hostedTargets = context.globalProductPlan.hostedTargetsForTargets[hostTarget] {
                    // FIXME: .firstIndex() is O(n)
                    if let index = hostedTargets.firstIndex(where: { $0 == configuredTarget }), index != 0 {
                        let previous = hostedTargets[index - 1]
                        if let input = lookup(previous, configuredTarget) {
                            inputs.append(input)
                        }
                    }
                }
            }
            // Otherwise we order it after the closest non-hosted target in the full list.
            else {
                // FIXME: .firstIndex() is O(n)
                if let configuredTargetIndex = context.globalProductPlan.allTargets.firstIndex(where: { $0 == configuredTarget }), configuredTargetIndex != 0 {
                    var index = configuredTargetIndex
                    var previous: ConfiguredTarget? = nil
                    while index != 0 {
                        index = index - 1
                        let prev = context.globalProductPlan.allTargets[index]
                        if context.globalProductPlan.hostTargetForTargets[prev] != nil {
                            // It's a hosted target, so we keep looking.  This is to avoid cycles.  rdar://problem/72563741
                            continue
                        }
                        if let hostedTargets = context.globalProductPlan.hostedTargetsForTargets[prev] {
                            // If it's a host target, then we look to see whether any of its hosted targets are listed after us in the dependency closure, and if they are then we keep looking.  This is to avoid cycles.  rdar://problem/73210420
                            // NOTE: I think that, strictly speaking, we only need to care about whether a hosted target *which depends on us* is listed after us in the dependency closure, but there isn't a simple way to figure that out, since `TargetBuildGraph` only remembers immediate dependencies.
                            var canOrderAfter = true
                            for hostedTarget in hostedTargets {
                                // FIXME: .firstIndex() is O(n)
                                if let hostedTargetIndex = context.globalProductPlan.allTargets.firstIndex(where: { $0 == hostedTarget }), hostedTargetIndex > configuredTargetIndex {
                                    canOrderAfter = false
                                    break
                                }
                            }
                            if !canOrderAfter {
                                continue
                            }
                        }
                        // If we get here then we can be ordered after this target.
                        previous = prev
                        break
                    }
                    if let previous = previous, let input = lookup(previous, configuredTarget) {
                        inputs.append(input)
                    }

                }
            }
        }

        return (inputs, dependencies)
    }

    private var configuredTarget: ConfiguredTarget {
        return context.configuredTarget!
    }

    /// Returns the end node for the given `dependency` which `target` depends on.  This is often used to order the tasks of one target after a specific set of tasks of an earlier target.
    private func lookupTargetExitNode(_ dependency: ConfiguredTarget, _ target: ConfiguredTarget) -> any PlannedNode {
        let taskInfo = context.globalProductPlan.targetTaskInfos[dependency]!
        // If the dependency is the target which is hosting this target, then use its unsigned-product-ready node as the input.
        if let hostTarget = context.globalProductPlan.hostTargetForTargets[target], dependency === hostTarget {
            return taskInfo.unsignedProductReadyNode
        }
        // Otherwise use the dependency's end node.
        return taskInfo.endNode
    }

    /// Returns the node before which are ordered all of the tasks needed to finish building the modules for the given `dependency`.  This is used to order both the target's own compilation tasks after this node, and - when eager compilation are enabled - downstream targets' compilation tasks after this node, allowing them to run in parallel with this target's compilation tasks.
    private func lookupModulesReadyNode(_ dependency: ConfiguredTarget, _ target: ConfiguredTarget) -> any PlannedNode {
        let taskInfo = context.globalProductPlan.targetTaskInfos[dependency]!
        let targetScope = context.globalProductPlan.getTargetSettings(dependency).globalScope
        if targetScope.evaluate(BuiltinMacros.EAGER_COMPILATION_DISABLE) {
            return taskInfo.endNode
        }
        return taskInfo.modulesReadyNode
    }

    private func lookupLinkerInputsReadyNode(_ dependency: ConfiguredTarget, _ target: ConfiguredTarget) -> any PlannedNode {
        let taskInfo = context.globalProductPlan.targetTaskInfos[dependency]!
        let targetScope = context.globalProductPlan.getTargetSettings(dependency).globalScope
        if targetScope.evaluate(BuiltinMacros.EAGER_COMPILATION_DISABLE) {
            return taskInfo.endNode
        }
        return taskInfo.linkerInputsReadyNode
    }

    private func lookupScanningInputsReadyNode(_ dependency: ConfiguredTarget, _ target: ConfiguredTarget) -> any PlannedNode {
        let taskInfo = context.globalProductPlan.targetTaskInfos[dependency]!
        return taskInfo.scanInputsReadyNode

    }

    /// The `staleFileRemovalNode` is used as the input to the target-start gate task, so that stale file removal occurs before the target starts building.  It is also the output of the stale file removal task which is how it connects up.
    private var staleFileRemovalNode: (any PlannedNode)? {
        return context.staleFileRemovalTaskIdentifier(for: configuredTarget).map(MakePlannedVirtualNode)
    }
}
