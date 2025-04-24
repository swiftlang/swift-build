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
public import SWBCore
package import struct SWBProtocol.ArenaInfo
package import struct SWBProtocol.RunDestinationInfo
package import SWBTaskConstruction
import SWBTaskExecution
package import Testing
import SWBMacro
import Foundation

/// Helper class for testing task construction.
package final class TaskConstructionTester {
    /// Wrapper to encapsulate the results of planning and answer test queries.
    package final class PlanningResults: BuildRequestCheckingResult, DiagnosticsCheckingResult, TasksCheckingResult, PlanRequestCheckingResult {
        /// The core used for the build.
        package let core: Core

        /// The workspace the results were computed for.
        package let workspace: Workspace

        /// Files declared to exist in the file system when the results were computed.
        package let existingFiles: Set<Path>

        /// The build request.  The `TaskConstructionTester` either synthesizes this or (potentially) modifies the one passed in by the test, so this is the one which was actually used.
        package let buildRequest: BuildRequest

        package let buildPlanRequest: BuildPlanRequest

        /// The build plan computed.
        package let buildPlan: BuildPlan

        /// Arena for the configured build request
        package var arena: ArenaInfo? {
            buildRequest.parameters.arena
        }

        // FIXME: This is unfortunate since the delegate should not be used for anything else once task planning is done, but factoring out the delegate to have a "NodeProducer" protocol or something similar is more than I want to sign up for right now.
        //
        /// The task planning delegate which was used to create the build plan.
        ///
        /// This is only used to be able to map `PlannedDirectoryTreeNode`s to `PlannedPathNode`s in the `TaskGraph`.
        private let taskPlanningDelegate: TestTaskPlanningDelegate

        /// The set of unmatched, planned targets.
        var plannedTargets: Set<ConfiguredTarget>

        /// The set of unmatched, planned tasks.
        var plannedTasks: [any PlannedTask]

        package var uncheckedTasks: [any PlannedTask] { return plannedTasks }

        /// A sorted list of the unmatched, planned tasks, for stability in issue reporting.
        var sortedPlannedTasks: [any PlannedTask] {
            return plannedTasks.sorted(by: { $0.execTask.shouldPrecede($1.execTask) })
        }

        /// The set of all planned tasks.
        let allPlannedTasks: [any PlannedTask]

        /// The set of unmatched diagnostics.
        var diagnostics: [ConfiguredTarget?: [Diagnostic]]

        package var checkedErrors: Bool = false
        package var checkedWarnings: Bool = false
        package var checkedNotes: Bool = false
        package var checkedRemarks: Bool = false

        init(_ core: Core, _ workspace: Workspace, _ existingFiles: [Path], _ buildRequest: BuildRequest, _ buildPlanRequest: BuildPlanRequest,_ buildPlan: BuildPlan, _ delegate: TestTaskPlanningDelegate) {
            self.core = core
            self.workspace = workspace
            self.existingFiles = Set(existingFiles)
            self.buildRequest = buildRequest
            self.buildPlanRequest = buildPlanRequest
            self.buildPlan = buildPlan
            self.taskPlanningDelegate = delegate
            let tasks = buildPlan.tasks

            self.diagnostics = delegate.diagnostics
            self.plannedTasks = tasks
            self.allPlannedTasks = plannedTasks
            self.plannedTargets = Set<ConfiguredTarget>(tasks.filter({ $0.ruleInfo.first != "Gate" }).compactMap { $0.forTarget })
        }

        private init(core: Core, workspace: Workspace, existingFiles: Set<Path>, buildRequest: BuildRequest, buildPlanRequest: BuildPlanRequest, buildPlan: BuildPlan, taskPlanningDelegate: TestTaskPlanningDelegate, plannedTargets: Set<ConfiguredTarget>, plannedTasks: [any PlannedTask], allPlannedTasks: [any PlannedTask], diagnostics: [ConfiguredTarget?: [Diagnostic]], checkedErrors: Bool, checkedWarnings: Bool, checkedNotes: Bool, checkedRemarks: Bool) {
            self.core = core
            self.workspace = workspace
            self.existingFiles = existingFiles
            self.buildRequest = buildRequest
            self.buildPlanRequest = buildPlanRequest
            self.buildPlan = buildPlan
            self.taskPlanningDelegate = taskPlanningDelegate
            self.plannedTargets = plannedTargets
            self.plannedTasks = plannedTasks
            self.allPlannedTasks = allPlannedTasks
            self.diagnostics = diagnostics
            self.checkedErrors = checkedErrors
            self.checkedWarnings = checkedWarnings
            self.checkedNotes = checkedNotes
            self.checkedRemarks = checkedRemarks
        }

        package func createCopy() -> PlanningResults {
            PlanningResults(core: core, workspace: workspace, existingFiles: existingFiles, buildRequest: buildRequest, buildPlanRequest: buildPlanRequest, buildPlan: buildPlan, taskPlanningDelegate: taskPlanningDelegate, plannedTargets: plannedTargets, plannedTasks: plannedTasks, allPlannedTasks: allPlannedTasks, diagnostics: diagnostics, checkedErrors: checkedErrors, checkedWarnings: checkedWarnings, checkedNotes: checkedNotes, checkedRemarks: checkedRemarks)
        }

        package func getDiagnostics(_ forKind: DiagnosticKind) -> [String] {
            return diagnostics.formatLocalizedDescription(.debugWithoutBehavior, workspace: workspace, filter: { $0.behavior == forKind })
        }

        package func getDiagnosticMessage(_ pattern: StringPattern, kind: DiagnosticKind, checkDiagnostic: (Diagnostic) -> Bool) -> String? {
            for (target, targetDiagnostics) in diagnostics {
                for (index, event) in targetDiagnostics.enumerated() {
                    guard filterDiagnostic(message: event.formatLocalizedDescription(.debugWithoutBehavior)) != nil else {
                        continue
                    }
                    guard event.behavior == kind else {
                        continue
                    }
                    let message = event.formatLocalizedDescription(.debugWithoutBehavior, targetAndWorkspace: target.map { ($0, workspace) } ?? nil)
                    guard pattern ~= message else {
                        continue
                    }
                    guard checkDiagnostic(event) else {
                        continue
                    }

                    var diags = targetDiagnostics
                    diags.remove(at: index)
                    diagnostics[target] = diags

                    return message
                }
            }
            return nil
        }

        package func check(_ pattern: StringPattern, kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation, checkDiagnostic: (Diagnostic) -> Bool) -> Bool {
            let found = (getDiagnosticMessage(pattern, kind: kind, checkDiagnostic: checkDiagnostic) != nil)

            if !found, failIfNotFound {
                Issue.record("unable to find \(kind.name): '\(pattern)' (other \(kind.name)s: \(getDiagnostics(kind)))", sourceLocation: sourceLocation)
            }
            return found
        }

        package func check(_ patterns: [StringPattern], diagnostics: [String], kind: DiagnosticKind, failIfNotFound: Bool, sourceLocation: SourceLocation) -> Bool {
            Issue.record("\(type(of: self)).check() for multiple patterns is not yet implemented", sourceLocation: sourceLocation)
            return false
        }

        /// Find the target matching a particular name.
        ///
        /// It is a test error if multiple such targets exist.
        package func checkTarget(_ name: String, platformDiscriminator: String? = nil, sdkroot: String? = nil, sourceLocation: SourceLocation = #_sourceLocation, body: (ConfiguredTarget) throws -> Void) rethrows {
                    let matchedTargets = plannedTargets.filter { $0.target.name == name && (platformDiscriminator == nil || $0.platformDiscriminator == platformDiscriminator) && (sdkroot == nil || $0.parameters.overrides["SDKROOT"] == sdkroot) }
            if matchedTargets.isEmpty {
                Issue.record("unable to find target with name '\(name)'\(platformDiscriminator.map{", platform '\($0)'"} ?? "")", sourceLocation: sourceLocation)
            } else if matchedTargets.count > 1 {
                Issue.record("found multiple targets with name '\(name)'\(platformDiscriminator.map{", platform '\($0)'"} ?? ""): \(matchedTargets)", sourceLocation: sourceLocation)
            } else {
                let target = matchedTargets.first!

                // Remove the target from the considered set.
                plannedTargets.remove(target)

                try body(target)
            }
        }

        /// Find the target matching a particular name.
        ///
        /// It is a test error if multiple such targets exist.
        @_disfavoredOverload package func checkTarget(_ name: String, platformDiscriminator: String? = nil, sdkroot: String? = nil, sourceLocation: SourceLocation = #_sourceLocation, body: (ConfiguredTarget) async throws -> Void) async rethrows {
            let matchedTargets = plannedTargets.filter { $0.target.name == name && (platformDiscriminator == nil || $0.platformDiscriminator == platformDiscriminator) && (sdkroot == nil || $0.parameters.overrides["SDKROOT"] == sdkroot) }
            if matchedTargets.isEmpty {
                Issue.record("unable to find target with name '\(name)'\(platformDiscriminator.map{", platform '\($0)'"} ?? "")", sourceLocation: sourceLocation)
            } else if matchedTargets.count > 1 {
                Issue.record("found multiple targets with name '\(name)'\(platformDiscriminator.map{", platform '\($0)'"} ?? ""): \(matchedTargets)", sourceLocation: sourceLocation)
            } else {
                let target = matchedTargets.first!

                // Remove the target from the considered set.
                plannedTargets.remove(target)

                try await body(target)
            }
        }

        /// Find the target matching a particular name.
        ///
        /// It is a test error if multiple such targets exist.
        package func checkNoTarget(_ name: String, platformDiscriminator: String? = nil, sdkroot: String? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
            let matchedTargets = plannedTargets.filter { $0.target.name == name && (platformDiscriminator == nil || $0.platformDiscriminator == platformDiscriminator) && (sdkroot == nil || $0.parameters.overrides["SDKROOT"] == sdkroot) }
            if !matchedTargets.isEmpty {
                Issue.record("should not be able to find target with name '\(name)'\(platformDiscriminator.map{", platform '\($0)'"} ?? "")", sourceLocation: sourceLocation)
            }
        }

        /// The list of planned, but unmatched targets.
        package var otherTargets: [ConfiguredTarget] {
            return plannedTargets.sorted(by: \.target.name)
        }

        /// Get all tasks matching the given conditions.
        private func findAnyMatchingTasks(_ conditions: [TaskCondition]) -> [any PlannedTask] {
            return allPlannedTasks.filter { task -> Bool in
                for condition in conditions {
                    if !condition.match(task) {
                        return false
                    }
                }
                return true
            }
        }

        package func removeMatchedTask(_ task: any PlannedTask) {
            for i in 0..<plannedTasks.count {
                if plannedTasks[i] === task {
                    plannedTasks.remove(at: i)
                    break
                }
            }
        }

        /// Find a task matching the given conditions and construct and pass a `TestHeadermapContents` object to `body` to check the contents of the headermap.
        ///
        /// It is a test error if there is no such task, or if there are multiple tasks matching the given conditions.  It is a test error if the task does not generate a headermap file, or if the contents of the headermap are malformed.
        package func checkHeadermapGenerationTask(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation, body: (TestHeadermapContents) -> Void) {
            // Find the task matching the conditions.
            let matchedTasks = findMatchingTasks(conditions)
            if matchedTasks.isEmpty {
                Issue.record("unable to find any task matching conditions '\(conditions)', among tasks: '\(sortedPlannedTasks.map{ String(describing: $0) }.joined(separator: ",\n\t"))'", sourceLocation: sourceLocation)
            } else if matchedTasks.count > 1 {
                Issue.record("found multiple tasks matching conditions '\(conditions)', found: \(matchedTasks)", sourceLocation: sourceLocation)
            } else {
                let task = matchedTasks[0]

                // Construct the TestHeadermapContents object.
                guard let action = (task.execTask as? SWBTaskExecution.Task)?.action else {
                    Issue.record("headermap generation task does not have a task action", sourceLocation: sourceLocation)
                    return
                }
                guard let auxFileAction = action as? AuxiliaryFileTaskAction else {
                    Issue.record("headermap generation task action is not a '\(AuxiliaryFileTaskAction.toolIdentifier)' action", sourceLocation: sourceLocation)
                    return
                }
                guard let headermap = try? TestHeadermapContents(taskPlanningDelegate.fs.read(auxFileAction.context.input).bytes) else {
                    Issue.record("unable to parse contents of headermap generation task action", sourceLocation: sourceLocation)
                    return
                }

                // Remove the task.
                removeMatchedTask(task)

                // Run the matcher.
                body(headermap)
            }
        }

        package func checkWriteAuxiliaryFileTask(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation, check: (any PlannedTask, ByteString) throws -> Void) rethrows {
            try checkWriteAuxiliaryFileTask(conditions, sourceLocation: sourceLocation, check: { task, contents, _ in try check(task, contents) })
        }

        package func checkWriteAuxiliaryFileTask(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation, check: (any PlannedTask, ByteString, Int?) throws -> Void) rethrows {
            try checkWriteAuxiliaryFileTask(conditions, sourceLocation: sourceLocation, check: check)
        }

        /// Find a WriteAuxiliaryFile task matching the given conditions and extract the contents from it and pass it to `check` to check the contents of what it will generate.
        ///
        /// It is a test error if there is no such task, or if there are multiple tasks matching the given conditions.  It is a test error if the task is not a WriteAuxiliaryFile task.
        package func checkWriteAuxiliaryFileTask(_ conditions: [TaskCondition], sourceLocation: SourceLocation = #_sourceLocation, check: (any PlannedTask, ByteString, Int?) throws -> Void) rethrows {
            // Find the task matching the conditions.
            let matchedTasks = findMatchingTasks(conditions)
            if matchedTasks.isEmpty {
                Issue.record("unable to find any task matching conditions '\(conditions)', among tasks: '\(sortedPlannedTasks.map{ String(describing: $0) }.joined(separator: ",\n\t"))'", sourceLocation: sourceLocation)
            } else if matchedTasks.count > 1 {
                Issue.record("found multiple tasks matching conditions '\(conditions)', found: \(matchedTasks)", sourceLocation: sourceLocation)
            } else {
                let task = matchedTasks[0]

                // Construct the TestHeadermapContents object.
                guard let action = (task.execTask as? SWBTaskExecution.Task)?.action else {
                    Issue.record("write-auxiliary-file task does not have a task action", sourceLocation: sourceLocation)
                    return
                }
                guard let auxFileAction = action as? AuxiliaryFileTaskAction else {
                    Issue.record("task action is not a '\(AuxiliaryFileTaskAction.toolIdentifier)' action", sourceLocation: sourceLocation)
                    return
                }
                // Currently we don't pass the permissions to the check block.

                // Remove the task.
                removeMatchedTask(task)

                // Run the matcher.
                let contents: ByteString
                do {
                    contents = try taskPlanningDelegate.fs.read(auxFileAction.context.input)
                } catch {
                    Issue.record("could not read auxiliary file: \(error.localizedDescription)", sourceLocation: sourceLocation)
                    return
                }
                try check(task, contents, auxFileAction.context.permissions)
            }
        }

        /// Check that a task has a strong dependency on a prior task.
        package func checkTaskFollows(_ task: any PlannedTask, antecedent: any PlannedTask, sourceLocation: SourceLocation = #_sourceLocation) {
            let distance: Int?
            do {
                distance = try taskGraph.predecessorDistance(from: task, to: antecedent)
            } catch {
                Issue.record(error)
                return
            }
            #expect(distance != nil, "task '\(task.testIssueDescription)' has no edge forcing it to follow '\(antecedent.testIssueDescription)'", sourceLocation: sourceLocation)
        }

        /// Check that a task is ordered after a prior task, which could be due to an explicit dependency through file nodes, or an ordering dependency through gate tasks.
        ///
        /// It is a test error if there is no such task, or if there are multiple tasks matching the given conditions.
        package func checkTaskFollows(_ task: any PlannedTask, _ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) {
            checkTaskFollows(task, conditions, sourceLocation: sourceLocation)
        }

        /// Check that a task is ordered after a prior task, which could be due to an explicit dependency through file nodes, or an ordering dependency through gate tasks.
        ///
        /// It is a test error if there is no such task, or if there are multiple tasks matching the given conditions.
        package func checkTaskFollows(_ task: any PlannedTask, _ conditions: [TaskCondition], sourceLocation: SourceLocation = #_sourceLocation) {
            // Find the task matching the conditions.
            let matchedTasks = findAnyMatchingTasks(conditions)
            guard matchedTasks.count == 1 else {
                Issue.record("unable to check ordering, expected \(task) but found: \(matchedTasks) using conditions: \(conditions)", sourceLocation: sourceLocation)
                return
            }

            checkTaskFollows(task, antecedent: matchedTasks[0], sourceLocation: sourceLocation)
        }

        /// Check that a task is _not_ ordered after a prior task.
        ///
        /// It is a test error if there is such an ordering, and the error will include the first found chain of dependency edges.
        package func checkTaskDoesNotFollow(_ task: any PlannedTask, antecedent: any PlannedTask, sourceLocation: SourceLocation = #_sourceLocation) {
            do {
                if let distance = try taskGraph.predecessorDistance(from: task, to: antecedent) {
                    let path = try taskGraph.shortestPath(from: task, to: antecedent) ?? []
                    Issue.record(Comment(rawValue: "task '\(task.testIssueDescription)' has an edge forcing it to follow '\(antecedent.testIssueDescription)' " +
                                 "by \(distance) tasks, but it was not expected to have one:\n\n" +
                                 "\(taskGraphPathDebugInfo(path))"), sourceLocation: sourceLocation)
                }
            } catch {
                Issue.record(error, sourceLocation: sourceLocation)
            }
        }

        private func taskGraphPathDebugInfo(_ taskGraphPath: [Ref<any PlannedTask>]) -> String {
            // PlannedNode.description includes the ObjectIdentifier which is super unreadable... but don't break clients for now
            return taskGraphPath.map { task in task.instance.description + ["inputs": task.instance.inputs, "outputs": task.instance.outputs].map { key, nodes in "\n\t\(key):\n\t\t" + nodes.map { node in "\(type(of: node))(name: \(node.name), path: \(node.path.str))" }.joined(separator: "\n\t\t") }.joined() }.joined(separator: "\n\n")
        }

        /// Check that a task is _not_ ordered after a prior task with the given conditions.
        ///
        /// It is a test error if there is such an ordering, and the error will include the first found chain of dependency edges. It is also an error if more than one task matches the given conditions.
        package func checkTaskDoesNotFollow(_ task: any PlannedTask, _ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) {
            checkTaskDoesNotFollow(task, conditions, sourceLocation: sourceLocation)
        }

        /// Check that a task is _not_ ordered after a prior task with the given conditions.
        ///
        /// It is a test error if there is such an ordering, and the error will include the first found chain of dependency edges. It is also an error if more than one task matches the given conditions.
        package func checkTaskDoesNotFollow(_ task: any PlannedTask, _ conditions: [TaskCondition], sourceLocation: SourceLocation = #_sourceLocation) {
            // Find the task matching the conditions.
            let matchedTasks = findAnyMatchingTasks(conditions)
            guard matchedTasks.count == 1 else {
                Issue.record("unable to check ordering, expected one task but found: \(matchedTasks)", sourceLocation: sourceLocation)
                return
            }

            checkTaskDoesNotFollow(task, antecedent: matchedTasks[0], sourceLocation: sourceLocation)
        }

        /// Check that a task depends on a prior task. This is a stronger check than `checkTaskFollows()` - it ignores orderings via gate tasks, and should be used to check that a task has an explicit dependency through declared concrete inputs and outputs on the prior task.
        package func checkTaskDependsOn(_ task: any PlannedTask, antecedent: any PlannedTask, sourceLocation: SourceLocation = #_sourceLocation) {
            let distance: Int?
            do {
                distance = try taskGraph.predecessorDependencyDistance(from: task, to: antecedent)
            } catch {
                Issue.record(error)
                return
            }
            #expect(distance != nil, "task '\(task.testIssueDescription)' does not have an explicit dependency on '\(antecedent.testIssueDescription)'", sourceLocation: sourceLocation)
        }

        /// Check that all tasks have inputs that are either virtual, or are known to exist, or have producer commands.
        /// - parameter fs: The file system object to use.  In the event that the test workspace used to generate the results doesn't declare a file to exist, a test can write it to the fs object so it will be known to exist.  Alternately, a test which is using a local fs will be able to examine files that are actually on disk, e.g. in the system or the Xcode bundle.
        package func checkAllTasksForMissingInputs(fs: any FSProxy, sourceLocation: SourceLocation = #_sourceLocation) {
            for (taskRef, inputs) in taskGraph.taskInputs {
                let task = taskRef.instance
                for (origInput, input) in inputs {
                    // If the input node is virtual, then we don't need to consider it.
                    if input is (PlannedVirtualNode) {
                        continue
                    }
                    // llbuild apparently doesn't consider directory tree nodes to ever be 'missing', so we don't either since this logic is intended to be as close an approximation of llbuild's checking as is practical.
                    if origInput is (PlannedDirectoryTreeNode) {
                        continue
                    }
                    // If the input path is in the list of existing files, then we're good.
                    if existingFiles.contains(input.path) {
                        continue
                    }
                    // If the input path has a producer task, then we're good.
                    if let producers = taskGraph.producers[Ref(input)], !producers.isEmpty {
                        continue
                    }
                    // Check whether the file really exists in the file system.
                    // Note that since TaskConstructionTests don't perform a build, the filesystem is going to be very sparse in this check.
                    if fs.exists(input.path) {
                        continue
                    }
                    // See if the path or any of its ancestors are being produced by a symlink task.  In that case, we assume the file exists through the symlink.
                    // FIXME: We could refine this to be clever and try to follow the symlink (and potentially multiple symlinks) to see if we fully resolve it to a file which we can identify we produce.  The ROI of that project seems pretty low.  If we decide we need to do so, MergeableLibraryTests.testMultiProjectAutomaticMergedFrameworkCreation() is a test which which (at time of writing) has a linker task which links a framework through the BUILT_PRODUCTS_DIR symlink.
                    var ancestorPath = input.path.dirname
                    var inputPathIncludesSymlink = false
                    while !ancestorPath.str.isEmpty && !ancestorPath.isRoot {
                        let potentialProducers = findAnyMatchingTasks([.matchRuleItemBasename("SymLink"), .matchRuleItem(ancestorPath.str)])
                        for producer in potentialProducers {
                            if producer.outputs.map({ $0.path }).contains(where: { $0 == ancestorPath }) {
                                inputPathIncludesSymlink = true
                                break
                            }
                        }
                        if inputPathIncludesSymlink {
                            break
                        }
                        // Otherwise try the next ancestor.
                        ancestorPath = ancestorPath.dirname
                    }
                    if inputPathIncludesSymlink {
                        continue
                    }
                    // Otherwise, we have a problem.
                    Issue.record("missing input '\(input.path.str)' for task '\(task.ruleInfo.quotedDescription)' and no task to build it", sourceLocation: sourceLocation)
                }
            }
        }

        /// Check that no node has more than one producer task.
        package func checkAllNodesForMultipleProducerTasks(sourceLocation: SourceLocation = #_sourceLocation) {
            for (nodeRef, producers) in taskGraph.producers {
                // Filter out the producing tasks which are mutation tasks.
                let realProducers = producers.filter { !taskGraph.mutatingTasks.contains(Ref($0)) }
                if realProducers.count > 1 {
                    let node = nodeRef.instance
                    let producerTaskInfos = producers.map { $0.ruleInfo.joined(separator: " ") }.sorted()
                    Issue.record("node '\(node.path.str)' has multiple (\(producers.count)) producer tasks: \(producerTaskInfos)", sourceLocation: sourceLocation)
                }
            }
        }

        /// Check that all mutating tasks have a previous task which generates their input node.  This mimics the code in BuildDescription.construct() which generates warnings about mutation task problems.
        package func checkMutatingTasks(sourceLocation: SourceLocation = #_sourceLocation) {
            for mutatedNodeRef in taskGraph.mutatedNodes {
                // First make sure there's a non-mutating producer for this node.  If there isn't, then we error out.  If there's more than one then we error out because we don't want to arbitrarily trace back to one creator in case something really weird is going on and we can't get there. (highly unlikely, but this keeps the logic simpler).
                guard let producers = taskGraph.producers[mutatedNodeRef], !producers.isEmpty else {
                    Issue.record("missing creator task for mutated node '\(mutatedNodeRef.instance.path.str)'", sourceLocation: sourceLocation)
                    continue
                }
                let creators = Set<Ref<any PlannedTask>>(Array<any PlannedTask>(producers).map{ Ref($0) }).subtracting(taskGraph.mutatingTasks)
                guard !creators.isEmpty else {
                    Issue.record("missing creator task for mutated node '\(mutatedNodeRef.instance.path.str)' mutated by task '\(producers.first!.ruleInfo.quotedDescription)'", sourceLocation: sourceLocation)
                    continue
                }
                guard creators.count == 1 else {
                    Issue.record("multiple tasks produce '\(mutatedNodeRef.instance.path.str)'", sourceLocation: sourceLocation)
                    continue
                }

                /// Utility function to return the distance from `origin` to to `predecessor`, ignoring the given node.
                /// - parameter ignoring: The node to ignore. This means that the node will be disregarded when traversing the graph. This is useful when there are known to be multiple nodes connecting two tasks, as is the case in mutating tasks, which have the node being mutated as both an input and an output, but also a virtual node connecting the task to its predecessor. The concrete node is ignored and only the virtual nodes are used to traverse the graph.
                /// - returns: The distance between the two nodes, or `nil` if `predecessor` does not precede `origin` in the graph.
                func predecessorDistance(from origin: any PlannedTask, to predecessor: any PlannedTask, ignoring: any PlannedNode) -> Int? {
                    return minimumDistance(from: Ref(origin), to: Ref(predecessor), successors: { taskRef in
                            let inputNodes = taskGraph.taskInputs[taskRef] ?? []
                        let inputs = inputNodes.flatMap { input -> [Ref<any PlannedTask>] in
                                if input.uniqueNode === ignoring {
                                    return []
                                }

                                return taskGraph.producers[Ref(input.uniqueNode)]?.map{ Ref($0) } ?? []
                            }
                            return inputs
                        })
                }

                // Get the mutating tasks for this node and order them topologically, ignoring the node being mutated.
                let orderedMutatingTasks = (taskGraph.mutatedNodesToTasks[mutatedNodeRef] ?? []).sorted(by: {
                    // A task precedes another iff there is exists some path to it.
                    return predecessorDistance(from: $1, to: $0, ignoring: mutatedNodeRef.instance) != nil
                })
                var producer = creators.first!.instance
                for consumer in orderedMutatingTasks {
                    // Validate that this task is strongly ordered w.r.t. to the previous one (our sort only ensures that we see them in the right order if they are so ordered).
                    if predecessorDistance(from: consumer, to: producer, ignoring: mutatedNodeRef.instance) == nil {
                        Issue.record("unexpected mutating task '\(consumer.ruleInfo.quotedDescription)' with no relation to prior mutator '\(producer.ruleInfo.quotedDescription)'", sourceLocation: sourceLocation)
                    }
                    producer = consumer
                }
            }
        }

        /// Examine the task graph to verify that there are no cycles. If it finds a cycle, it will emit an error about the cycle and stop looking (i.e., no more than one cycle will be reported).
        package func checkNoCycles(sourceLocation: SourceLocation = #_sourceLocation) {
            var visitedNodes = Set<Ref<any PlannedNode>>()
            var foundCycle = false

            func lookForCycle(from nodeRef: Ref<any PlannedNode>, through producer: any PlannedTask, nodeList: Set<Ref<any PlannedNode>> = Set(), path: [(producer: any PlannedTask, node: any PlannedNode)] = []) {
                // If the producer is a mutating task (has the same node as both an input and an output) then skip it.  This will effectively jump over all mutating tasks back to the original producer task.
                // FIXME: We should be traversing the chain of mutating tasks rather than skipping them in case there's a cycle which involves them which isn't captured by the creator and consumer tasks of the node, but that's considerably trickier to do.
                guard !taskGraph.mutatingTasks.contains(Ref(producer)) else {
                    return
                }

                // Add the node and producer to the path.
                let newPath = [(producer, nodeRef.instance)] + path

                // If this node is already in the node list then we found a cycle, so report it and exit.
                if nodeList.contains(nodeRef) {
                    foundCycle = true
                    // Construct the chain for the cycle that we found.
                    var cycle = nodeRef.instance.path.basename
                    for item in path {
                        cycle += " -> " + (item.producer.ruleInfo.first ?? "<unknown>")
                        cycle += " -> " + item.node.path.basename
                        guard Ref(item.node) != nodeRef else {
                            // We closed the cycle - everything in the path after this is the entry point to the cycle, which we don't report because the entry point is nondeterministic.
                            break
                        }
                    }
                    // Note that the cycle reported here flows *downstream* (from producer task to output).  This is the reverse of the order in which cycles emitted by llbuild are printed (which shows the output first and then its producer task).  I don't remember why I did it this way.
                    Issue.record("dependency cycle found: \(cycle)", sourceLocation: sourceLocation)
                    return
                }

                // If we've already visited this node at some point, then we can skip it.
                guard !visitedNodes.contains(nodeRef) else {
                    return
                }
                visitedNodes.insert(nodeRef)
                var newNodeList = nodeList
                newNodeList.insert(nodeRef)

                // Go through all the input nodes and work back through their producer tasks.  This iterates through all the nodes in a nondeterministic order, which is fine because we just want coverage.
                for input in taskGraph.taskInputs[Ref(producer)] ?? [] {
                	let inputRef = Ref(input.uniqueNode)
                    for inputProducer in taskGraph.producers[inputRef] ?? [] {
                        lookForCycle(from: inputRef, through: inputProducer, nodeList: newNodeList, path: newPath)
                        // If we detected a cycle then bail out.
                        guard !foundCycle else {
                            return
                        }
                    }
                }
            }

            // Look for cycles for all of the nodes in the task graph.  The goal is to never visit a node more than once.
            for (nodeRef, producers) in taskGraph.producers {
                for producer in producers {
                    lookForCycle(from: nodeRef, through: producer)
                    // If we detected a cycle then bail out.
                    guard !foundCycle else {
                        return
                    }
                }
            }
        }

        /// Precomputed information on the graph of tasks and nodes.
        private struct TaskGraph {
            /// The list of producers of a particular node.
            ///
            /// This list also contains any mutators of the node.
            let producers: [Ref<any PlannedNode>: [any PlannedTask]]

            /// The mapping of tasks to resolved inputs, including the enforcement of `mustPrecede` relationships.
            ///
            /// The `originalNode` form is the actual node created in task construction, while the `uniqueNode` form has been normalized so directory and non-directory nodes can be compared. The `uniqueNode` form is almost always the correct one to use, unless you want to know if the original node is a directory tree node.  (This is a clunky approach but I didn't want to elide any nodes in case they were needed for other logic, and because having the magically disappear can make debugging confusing.)
            let taskInputs: [Ref<any PlannedTask>: [(originalNode: any PlannedNode, uniqueNode: any PlannedNode)]]

            /// The set of mutated nodes.
            let mutatedNodes: Set<Ref<any PlannedNode>>

            /// The set of mutating tasks.  These are tasks which have the same node as both an input and an output.
            let mutatingTasks: Set<Ref<any PlannedTask>>

            /// A map of mutated nodes to the tasks which mutate them.  Note that the array for each node will exclude the creator task(s) for that node.
            let mutatedNodesToTasks: [Ref<any PlannedNode>: [any PlannedTask]]

            init(producers: [Ref<any PlannedNode>: [any PlannedTask]], taskInputs: [Ref<any PlannedTask>: [(originalNode: any PlannedNode, uniqueNode: any PlannedNode)]], mutatingTasks: Set<Ref<any PlannedTask>>, mutatedNodesToTasks: [Ref<any PlannedNode>: [any PlannedTask]]) {
                self.producers = producers
                self.taskInputs = taskInputs
                self.mutatedNodesToTasks = mutatedNodesToTasks
                self.mutatedNodes = Set<Ref<any PlannedNode>>(mutatedNodesToTasks.keys)
                self.mutatingTasks = mutatingTasks
            }

            private func getTaskInputs(taskRef: Ref<any PlannedTask>) throws -> [(originalNode: any PlannedNode, uniqueNode: any PlannedNode)] {
                if let inputs = taskInputs[taskRef] {
                    return inputs
                } else {
                    throw StubError.error("Could not find task in graph: \(taskRef.instance.ruleInfo.joined(separator: " "))")
                }
            }

            private func _successors(taskRef: Ref<any PlannedTask>) throws -> [Ref<any PlannedTask>] {
                try getTaskInputs(taskRef: taskRef).flatMap { input -> [Ref<any PlannedTask>] in
                    // Ignore mutated nodes when traversing the graph, since they break the DAG.
                    if mutatedNodes.contains(Ref(input.uniqueNode)) {
                        return []

                    } else {
                        return producers[Ref(input.uniqueNode)]?.map{ Ref($0) } ?? []
                    }
                }
            }

            /// Compute the shortest distance from a task to a potential predecessors, in nodes.
            ///
            /// This will *not* include edges which traverse mutated nodes.
            func predecessorDistance(from origin: any PlannedTask, to predecessor: any PlannedTask) throws -> Int? {
                return (try minimumDistance(from: Ref(origin), to: Ref(predecessor), successors: _successors))
            }

            /// Compute the shortest path from a task to a potential predecessor and return the list of nodes.
            ///
            /// This will *not* include edges which traverse mutated nodes.
            func shortestPath(from origin: any PlannedTask, to predecessor: any PlannedTask) throws -> [Ref<any PlannedTask>]? {
                return (try SWBUtil.shortestPath(from: Ref(origin), to: Ref(predecessor), successors: _successors))
            }

            private func _dependencySuccessors(taskRef: Ref<any PlannedTask>) throws -> [Ref<any PlannedTask>] {
                try getTaskInputs(taskRef: taskRef).flatMap { input -> [Ref<any PlannedTask>] in
                    // Ignore mutated nodes when traversing the graph, since they break the DAG.
                    if mutatedNodes.contains(Ref(input.uniqueNode)) {
                        return []
                    }

                    return producers[Ref(input.uniqueNode)]?.compactMap { task in
                        // Ignore gate tasks.
                        return task.ruleInfo.first != "Gate" ? Ref(task) : nil
                    } ?? []
                }
            }

            /// Compute the shortest distance from a task to a potential direct dependency predecessors, in nodes, ignoring all gate tasks.  This effectively returns non-nil only if the origin has an expressed dependency on the predecessor, rather than merely being ordered after it through virtual nodes.
            ///
            /// This will *not* include edges which traverse mutated nodes.
            func predecessorDependencyDistance(from origin: any PlannedTask, to predecessor: any PlannedTask) throws -> Int? {
                return try minimumDistance(from: Ref(origin), to: Ref(predecessor), successors: _dependencySuccessors)
            }
        }

        /// Method to make sure we always use the same node for a given path in the `TaskGraph`.  In practice, one task might create a `PlannedNode` as an output, and another might create a `PlannedDirectoryNode` as an input, when both of them refer to the same path.  So we need to do this since `TaskGraph` is using `Ref`-wrapped nodes.
        func uniqueNode(for node: any PlannedNode) -> any PlannedNode {
            if let node = node as? (PlannedDirectoryTreeNode) {
                return self.taskPlanningDelegate.createNode(absolutePath: node.path)
            }
            return node
        }

        /// The task graph for the set of planned tasks.  We can use `lazy` here since this is only ever called from the main testing thread.
        private lazy var taskGraph: TaskGraph = { () -> TaskGraph in
            // Compute information on the tasks.
            var allMutatedNodes = Set<Ref<any PlannedNode>>()
            var mutatedNodesToTasks = [Ref<any PlannedNode>: [any PlannedTask]]()
            var allMutatingTasks = Set<Ref<any PlannedTask>>()
            var producers = Dictionary<Ref<any PlannedNode>, [any PlannedTask]>()
            var taskInputs = Dictionary<Ref<any PlannedTask>, [(originalNode: any PlannedNode, uniqueNode: any PlannedNode)]>()
            for task in self.allPlannedTasks {
                // Add this task as a producer of its outputs.
                for output in task.outputs {
                    producers[Ref(uniqueNode(for: output))] = (producers[Ref(uniqueNode(for: output))] ?? []) + [task]
                }

                // Set this task's inputs.
                taskInputs[Ref(task)] = (taskInputs[Ref(task)] ?? []) + task.inputs.map({ ($0, uniqueNode(for: $0)) })

                // Add inferred relations for must precede.
                for succ in task.mustPrecede {
                    taskInputs[Ref(succ.instance)] = (taskInputs[Ref(succ.instance)] ?? []) + task.outputs.map({ ($0, uniqueNode(for: $0)) })
                }

                // Compute information about mutated tasks and nodes in the graph.
                let mutatedNodes = Set<Ref<any PlannedNode>>(task.inputs.map{ Ref(uniqueNode(for: $0)) }).intersection(Set<Ref<any PlannedNode>>(task.outputs.map{ Ref(uniqueNode(for: $0)) }))
                if !mutatedNodes.isEmpty {
                    for mutatedNode in mutatedNodes {
                        let mutatingTasks = mutatedNodesToTasks.getOrInsert(mutatedNode, { [any PlannedTask]() })
                        mutatedNodesToTasks[mutatedNode] = (mutatedNodesToTasks[mutatedNode] ?? []) + [task]
                    }
                    allMutatingTasks.insert(Ref(task))
                }
            }

            return TaskGraph(producers: producers, taskInputs: taskInputs, mutatingTasks: allMutatingTasks, mutatedNodesToTasks: mutatedNodesToTasks)
        }()

        /// Dump the task graph, for debugging purposes.
        package func dumpGraph() -> String {
            let graph = taskGraph

            var graphString = String()
            for task in allPlannedTasks.sorted(by: { $0.ruleInfo.lexicographicallyPrecedes($1.ruleInfo) }) {
                graphString += "\(task.testIssueDescription)\n"
                graphString += "  inputs:\n"
                for input in graph.taskInputs[Ref(task)]! {
                    graphString += "    \(input)\n"
                }
                graphString += "  outputs:\n"
                for output in task.outputs {
                    graphString += "    \(output)\n"
                }
                graphString += "\n"
            }
            return graphString
        }
    }

    /// The core in use.
    package let core: Core

    /// The workspace being tested.
    package let workspace: Workspace

    /// The paths to all source files in the workspace.  This is used to validate whether all input files for tasks either already exist, or have a producer task.
    let sourceFiles: [Path]

    package init(_ core: Core, _ testWorkspace: TestWorkspace) throws {
        self.core = core
        self.workspace = try testWorkspace.load(core)
        self.sourceFiles = testWorkspace.findSourceFiles()
    }

    /// Convenience initializer for single project workspace tests.
    package convenience init(_ core: Core, _ testProject: TestProject) throws {
        try self.init(core, TestWorkspace("Test", sourceRoot: testProject.sourceRoot, projects: [testProject]))
    }

    /// Returns the effective build parameters to use for the build.
    private func effectiveBuildParameters(_ parameters: BuildParameters?, runDestination: SWBProtocol.RunDestinationInfo?, useDefaultToolChainOverride: Bool) -> BuildParameters {
        // Indexing tests pass exactly the parameters they want to use, so we don't mess with them.
        if let parameters, parameters.action == .indexBuild {
            return parameters
        }

        // Always start with some set of build parameters.
        let parameters = parameters ?? BuildParameters(configuration: "Debug")

        // If the build parameters don't specify a run destination, but we were passed one, then use the one we were passed. (checkBuild() defaults this to .macOS.)
        let activeRunDestination: RunDestinationInfo? = switch (parameters.activeRunDestination, runDestination) {
        case let (.some(lhs), (.some(rhs))):
            preconditionFailure("Specified run destinations from both explicit build parameters and default destination: \(lhs), \(rhs)")
        case let (.some(destination), nil):
            destination
        case let (nil, .some(destination)):
            destination
        case (nil, nil):
            nil
        }

        // Define a default set of overrides.
        var overrides = [
            // Always use separate headermaps by forcing ALWAYS_SEARCH_USER_PATHS off, unless the build parameters passed to checkBuild() explicitly enables it. (Since traditional headermaps are currently not supported by Swift Build, doing so is not presently useful.)  Doing this also suppresses the warning of traditional headermaps being unsupported.
            "ALWAYS_SEARCH_USER_PATHS": "NO",
        ]

        if useDefaultToolChainOverride {
            // Always use the default toolchain by default so we don't pick a toolchain from SDK settings. Clients will need to pass TOOLCHAINS as an override if they actually want to use some other toolchain.
            overrides["TOOLCHAINS"] = "default"
        }

        // If we have a run destination, then we default ONLY_ACTIVE_ARCH to YES. This means when they build with a non-generic run destination, that run destination's architecture will be used rather than building universal.
        // If we don't have a run destination, then defaulting ONLY_ACTIVE_ARCH is probably the wrong thing to do.
        if activeRunDestination != nil {
            overrides["ONLY_ACTIVE_ARCH"] = "YES"
        }
        // Add overrides from the parameters we were passed, which will supersede the default overrides above.
        overrides.addContents(of: parameters.overrides)

        // Create and return the effective parameters.
        return BuildParameters(action: parameters.action, configuration: parameters.configuration, activeRunDestination: activeRunDestination, activeArchitecture: parameters.activeArchitecture, overrides: overrides, commandLineOverrides: parameters.commandLineOverrides, commandLineConfigOverridesPath: parameters.commandLineConfigOverridesPath, commandLineConfigOverrides: parameters.commandLineConfigOverrides, environmentConfigOverridesPath: parameters.environmentConfigOverridesPath, environmentConfigOverrides: parameters.environmentConfigOverrides, arena: parameters.arena)
    }

    /// Returns the effective build request to use for the build.
    private func effectiveBuildRequest(_ buildRequest: BuildRequest?, targetName: String?, parameters: BuildParameters) -> BuildRequest {
        if let buildRequest {
            // If we were passed a build request, then reconstruct it using the parameters.
            let buildTargets = buildRequest.buildTargets.map({ BuildRequest.BuildTargetInfo(parameters: parameters, target: $0.target) })
            return buildRequest.with(parameters: parameters, buildTargets: buildTargets)
        }
        else {
            // If we weren't passed a build request, then create one with some default characteristics we use in most task construction tests.
            let project = workspace.projects[0]
            let target: Target
            if let targetName = targetName {
                if let foundTarget = project.targets.first(where: { $0.name == targetName }) {
                    target = foundTarget
                } else {
                    preconditionFailure("couldn't find target named \(targetName)")
                }
            } else {
                target = project.targets[0]
            }
            let buildTarget = BuildRequest.BuildTargetInfo(parameters: parameters, target: target)
            return BuildRequest(parameters: parameters, buildTargets: [buildTarget], dependencyScope: .workspace, continueBuildingAfterErrors: true, useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)
        }
    }

    /// Construct the tasks for the given build parameters, and test the result.
    /// - parameter runDestination: If the run destination in `parameter` is nil, then the value passed here will be used instead. Due to the defined default value, this means that tests build for macOS unless they specify otherwise.
    /// - parameter checkTaskGraphIntegrity: If `true` (the default), then the task graph's integrity will be checked, and test errors will be emitted for scenarios such as missing producers for nodes, and multiple producers for nodes.  A test may wish to pass `false` for this if it is deliberately constructing a bad task graph in order to examine the resulting errors.
    package func checkBuild(_ inputParameters: BuildParameters? = nil, runDestination: SWBProtocol.RunDestinationInfo?, targetName: String? = nil, buildRequest inputBuildRequest: BuildRequest? = nil, provisioningOverrides: ProvisioningTaskInputs? = nil, processEnvironment: [String: String] = [:], fs: any FSProxy = PseudoFS(), userPreferences: UserPreferences? = nil, clientDelegate: (any TaskPlanningClientDelegate)? = nil, checkTaskGraphIntegrity: Bool = true, useDefaultToolChainOverride: Bool = true, systemInfo: SystemInfo? = nil, sourceLocation: SourceLocation = #_sourceLocation, body: (PlanningResults) async throws -> Void) async rethrows {
        // For test stability we modify the build parameters we were passed.
        let parameters = effectiveBuildParameters(inputParameters ?? inputBuildRequest?.parameters, runDestination: runDestination, useDefaultToolChainOverride: useDefaultToolChainOverride)

        // Create a workspace context.
        let workspaceContext = WorkspaceContext(core: core, workspace: workspace, fs: fs, processExecutionCache: .sharedForTesting)

        // Configure fake user and system info.
        workspaceContext.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid:12345, home: Path("/Users/whoever"), environment: processEnvironment))
        workspaceContext.updateSystemInfo(systemInfo ?? SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: "x86_64"))
        workspaceContext.updateUserPreferences(userPreferences ?? UserPreferences.defaultForTesting)

        // Create a build request.
        let buildRequest: BuildRequest
        if let inputBuildRequest, inputBuildRequest.parameters.action == .indexBuild {
            // Indexing tests pass exactly the build request they want to use, so we don't mess with it.
            buildRequest = inputBuildRequest
        }
        else {
            buildRequest = effectiveBuildRequest(inputBuildRequest, targetName: targetName, parameters: parameters)
        }

        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        // Get a build plan for this request.
        let delegate = TestTaskPlanningDelegate(clientDelegate: clientDelegate ?? MockTestTaskPlanningClientDelegate(), workspace: workspace, fs: fs)
        let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext)
        var provisioningInputs = [ConfiguredTarget: ProvisioningTaskInputs]()
        for target in buildGraph.allTargets {
            provisioningInputs[target] = TaskConstructionTester.computeProvisioningInputs(for: target, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, provisioningOverrides: provisioningOverrides)
        }
        let buildPlanRequest = BuildPlanRequest(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, buildGraph: buildGraph, provisioningInputs: provisioningInputs)
        guard let buildPlan = await BuildPlan(planRequest: buildPlanRequest, taskPlanningDelegate: delegate) else {
            Issue.record("Build plan construction was unexpectedly cancelled", sourceLocation: sourceLocation)
            return
        }
        let results = PlanningResults(core, workspace, sourceFiles, buildRequest, buildPlanRequest, buildPlan, delegate)

        /*@MainActor func addAttachments() {
            // TODO: This `runActivity` call should be wider in scope, but this would significantly complicate the code flow due to threading requirements without having async/await.
            XCTContext.runActivity(named: "Plan Build") { activity in
                // TODO: <rdar://59432231> Longer term, we should find a way to share code with CoreQualificationTester, which has a number of APIs for emitting build operation debug info.
                activity.attach(name: "Task Graph", string: results.dumpGraph())
            }
        }

        await addAttachments()*/

        // Check the results.
        try await body(results)
        results.validate(sourceLocation: sourceLocation)

        // Unless instructed to skip doing so (usually because a test is specifically testing erroneous conditions), check the integrity of the task graph.
        if checkTaskGraphIntegrity {
            // Check that no tasks have missing inputs.
            results.checkAllTasksForMissingInputs(fs: fs, sourceLocation: sourceLocation)
            // Check that no nodes have more than one producer task.
            results.checkAllNodesForMultipleProducerTasks(sourceLocation: sourceLocation)
            // Check that all mutating tasks has prior mutators or producers for their inputs.
            results.checkMutatingTasks(sourceLocation: sourceLocation)
            // Check that there are no cycles in the graph.
            results.checkNoCycles(sourceLocation: sourceLocation)
        }
    }

    /// Helper function for computing mock provisioning inputs.
    package static func computeProvisioningInputs(for configuredTarget: ConfiguredTarget, workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, provisioningOverrides: ProvisioningTaskInputs? = nil) -> ProvisioningTaskInputs {
        func mergeProvisioningTaskInputs(inputs: ProvisioningTaskInputs, overrides: ProvisioningTaskInputs?) -> ProvisioningTaskInputs {
            guard let overrides else { return inputs }
            return ProvisioningTaskInputs(
                identityHash: overrides.identityHash ?? inputs.identityHash,
                identityName: overrides.identityName ?? inputs.identityName,
                profileName: overrides.profileName ?? inputs.profileName,
                profileUUID: overrides.profileUUID ?? inputs.profileUUID,
                profilePath: overrides.profilePath ?? inputs.profilePath,
                designatedRequirements: overrides.designatedRequirements ?? inputs.designatedRequirements,
                signedEntitlements: overrides.signedEntitlements.isEmpty ? inputs.signedEntitlements : overrides.signedEntitlements,
                simulatedEntitlements: overrides.simulatedEntitlements.isEmpty ? inputs.simulatedEntitlements : overrides.simulatedEntitlements,
                appIdentifierPrefix: overrides.appIdentifierPrefix ?? inputs.appIdentifierPrefix,
                teamIdentifierPrefix: overrides.teamIdentifierPrefix ?? inputs.teamIdentifierPrefix,
                isEnterpriseTeam: overrides.isEnterpriseTeam ?? inputs.isEnterpriseTeam,
                keychainPath: overrides.keychainPath ?? inputs.keychainPath)
        }

        // Otherwise evaluated $(CODE_SIGN_IDENTITY) to use a default set of inputs.
        let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
        let scope = settings.globalScope
        let codeSignIdentity = scope.evaluate(BuiltinMacros.CODE_SIGN_IDENTITY)
        let productName = scope.evaluate(BuiltinMacros.PRODUCT_NAME)

        // Compute the signed and simulated entitlements based on the platform.
        // FIXME: In theory we could take CODE_SIGN_ENTITLEMENTS into account here to generate slightly different entitlements if it exists, but right now we don't (nor do any tests check the contents of the entitlements file, as far as I know).  The logic below reflects the expected default entitlements when building for each platform.
        let signedEntitlements: [String: PropertyListItem]
        let simulatedEntitlements: [String: PropertyListItem]
        let appIdentifierPrefix = "F154D0C"
        let teamIdentifierPrefix = appIdentifierPrefix
        let appIdentifier = "\(appIdentifierPrefix).com.apple.dt.\(productName)"
        switch settings.platform?.familyName {
        case "driverkit":
            signedEntitlements = [:]
            simulatedEntitlements = [:]
        case "macosx":
            signedEntitlements = [
                "com.apple.security.get-task-allow": 1,
            ]
            simulatedEntitlements = [:]
        default:
            if settings.platform?.isSimulator == true {
                // For a simulator platform, the signed entitlements get passed to codesign for the simulator bundle (they're macOS entitlements), while the simulated entitlements get passed to the linker (they're the entitlements for the platform itself, i.e. that would be passed to codesign when building for a device).
                signedEntitlements = [
                    "com.apple.security.get-task-allow": 1,
                ]
                simulatedEntitlements = [
                    "application-identifier": .plString(appIdentifier),
                    "com.apple.developer.team-identifier": .plString(teamIdentifierPrefix),
                    "get-task-allow": 1,
                    "keychain-access-groups": [
                        appIdentifier
                    ],
                ]
            }
            else {
                signedEntitlements = [
                    "application-identifier": .plString(appIdentifier),
                    "com.apple.developer.team-identifier": .plString(teamIdentifierPrefix),
                    "get-task-allow": 1,
                    "keychain-access-groups": [
                        appIdentifier
                    ],
                ]
                simulatedEntitlements = [:]
            }
        }

        // Create the provisioning task inputs.
        let isMacOS = settings.platform?.familyName == "macOS"
        switch codeSignIdentity {
            // FIXME: <rdar://problem/29092604> Remove workaround for projects in ExternalTests data which are still using the deprecated value "Don't Code Sign" for CODE_SIGN_IDENTITY.
        case "", "Don't Code Sign":
            // Don't sign
            return ProvisioningTaskInputs()
        case "-":
            // Ad-hoc signing - we support all platforms here.
            return mergeProvisioningTaskInputs(
                inputs: ProvisioningTaskInputs(identityHash: "-", identityName: "-", signedEntitlements: .plDict(signedEntitlements), simulatedEntitlements: .plDict(simulatedEntitlements)),
                overrides: provisioningOverrides)
        case "Mac Developer",
             "Apple Development" where isMacOS:
            // Mac developer signing - we never have simulated entitlements here.
            return mergeProvisioningTaskInputs(
                inputs: ProvisioningTaskInputs(identityHash: "3ACDE4E702E4", identityName: codeSignIdentity, signedEntitlements: .plDict(signedEntitlements)),
                overrides: provisioningOverrides)
        case "iOS Developer", "iPhone Developer",
             "Apple Development" where !isMacOS:
            // iOS developer signing
            let profileUUID = "8db0e92c-592c-4f06-bfed-9d945841b78d"
            return mergeProvisioningTaskInputs(
                inputs: ProvisioningTaskInputs(identityHash: "105DE4E702E4", identityName: codeSignIdentity, profileName: "iOS Team Provisioning Profile: *", profileUUID: profileUUID, profilePath: workspaceContext.userInfo!.home.join("Library/MobileDevice/Provisioning Profiles/\(profileUUID).mobileprovision"), signedEntitlements: .plDict(signedEntitlements), simulatedEntitlements: .plDict(simulatedEntitlements), appIdentifierPrefix: "\(appIdentifierPrefix).", teamIdentifierPrefix: "\(teamIdentifierPrefix).", isEnterpriseTeam: false),
                overrides: provisioningOverrides)
        default:
            // We have no default inputs for this identity.
            fatalError("unsupported CODE_SIGN_IDENTITY '\(codeSignIdentity)' - no default provisioning task inputs available for this identity")
        }
    }
}

@available(*, unavailable)
extension TaskConstructionTester: Sendable { }

@available(*, unavailable)
extension TaskConstructionTester.PlanningResults: Sendable { }

extension TaskConstructionTester {
    /// Construct the tasks for an index build operation, and test the result.
    package func checkIndexBuild(
        targets: [any TestTarget]? = nil,
        workspaceOperation: Bool? = nil,
        runDestination: RunDestinationInfo? = nil,
        systemInfo: SystemInfo? = nil,
        sourceLocation: SourceLocation = #_sourceLocation,
        body: (PlanningResults) throws -> Void
    ) async throws {
        let workspaceOperation = workspaceOperation ?? (targets == nil)
        let buildRequest = try BuildOperationTester.buildRequestForIndexOperation(
            workspace: workspace,
            buildTargets: targets,
            workspaceOperation: workspaceOperation,
            runDestination: runDestination,
            sourceLocation: sourceLocation
        )
        return try await checkBuild(runDestination: runDestination, buildRequest: buildRequest, systemInfo: systemInfo, sourceLocation: sourceLocation, body: body)
    }
}


package final class TestHeadermapContents {
    package let rawBytes: [UInt8]
    package private(set) var contents = [String: String]()

    init?(_ bytes: [UInt8]) {
        self.rawBytes = bytes
        guard let hmap = try? Headermap(bytes: bytes) else {
            return nil
        }
        for entry in hmap {
            contents[entry.0.asReadableString()] = entry.1.asReadableString()
        }
    }

    /// Check that the headermap value for 'key' is 'value', and consume the entry.
    ///
    /// It is a test error if there is no entry for 'key' at all.
    package func checkEntry(_ key: String, _ value: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let actualValue = contents[key] else {
            Issue.record("no value in headermap for '\(key)'", sourceLocation: sourceLocation)
            return
        }
        #expect(actualValue == value, sourceLocation: sourceLocation)
        contents.removeValue(forKey: key)
    }

    /// Check that there are no more entries.
    package func checkNoEntries(sourceLocation: SourceLocation = #_sourceLocation) {
        if !contents.isEmpty {
            let entries = contents.map({ "\($0) -> \($1)" }).sorted()
            Issue.record("found unexpected headermap entries: \(entries)", sourceLocation: sourceLocation)
        }
    }
}

@available(*, unavailable)
extension TestHeadermapContents: Sendable { }

/// Helper protocol to share command-line checking functions
/// between PlannedTaskBuilder and MockTestTask.
package protocol TaskOrTaskBuilder: CommandLineCheckable {
    var ruleInfo: [String] { get }
    var environment: EnvironmentBindings { get }
}

extension PlannedTaskBuilder: TaskOrTaskBuilder {
    package var commandLineAsByteStrings: [ByteString] {
        return self.commandLine.map(\.asByteString)
    }
}
extension Task: TaskOrTaskBuilder {}

// Extensions of protocols cannot have inheritance clauses, so we cannot conform PlannedTask to TaskOrTaskBuilder.
private struct _ConstructedTask: TaskOrTaskBuilder {
    let commandLineAsByteStrings: [ByteString]
    let ruleInfo: [String]
    let environment: EnvironmentBindings

    init(_ task: any PlannedTask) {
        self.commandLineAsByteStrings = task.execTask.commandLine.map(\.asByteString)
        self.ruleInfo = task.ruleInfo
        self.environment = task.environment
    }
}

extension TaskOrTaskBuilder {
    package func checkRuleInfo(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(self.ruleInfo == strings, sourceLocation: sourceLocation)
    }

    package func checkRuleInfo(_ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
        XCTAssertMatch(self.ruleInfo, patterns, sourceLocation: sourceLocation)
    }

    package func checkEnvironment(_ patterns: [String: StringPattern?], exact: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        environment.checkEnvironment(patterns, exact: exact, sourceLocation: sourceLocation)
    }
}

// Extensions of protocols cannot have inheritance clauses, so we cannot conform PlannedTask to TaskOrTaskBuilder.
extension PlannedTask {
    package func checkCommandLine(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkCommandLine(strings, sourceLocation: sourceLocation)
    }

    package func checkCommandLineContains(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkCommandLineContains(strings, sourceLocation: sourceLocation)
    }

    package func checkCommandLineContainsUninterrupted(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkCommandLineContainsUninterrupted(strings, sourceLocation: sourceLocation)
    }

    package func checkCommandLineDoesNotContain(_ string: String, sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkCommandLineDoesNotContain(string, sourceLocation: sourceLocation)
    }

    package func checkCommandLineMatches(_ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkCommandLineMatches(patterns, sourceLocation: sourceLocation)
    }

    package func checkCommandLineNoMatch(_ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkCommandLineNoMatch(patterns, sourceLocation: sourceLocation)
    }

    package func checkCommandLineLastArgumentEqual(_ string: String, sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkCommandLineLastArgumentEqual(string, sourceLocation: sourceLocation)
    }

    package func checkRuleInfo(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkRuleInfo(strings, sourceLocation: sourceLocation)
    }

    package func checkRuleInfo(_ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkRuleInfo(patterns, sourceLocation: sourceLocation)
    }

    package func checkEnvironment(_ patterns: [String: StringPattern?], exact: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkEnvironment(patterns, exact: exact, sourceLocation: sourceLocation)
    }

    package func checkSandboxedCommandLine(_ strings: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        _ConstructedTask(self).checkSandboxedCommandLine(strings, sourceLocation: sourceLocation)
    }
}

// MARK: Checking support

private func XCTAssertEqual(_ lhs: EnvironmentBindings, _ rhs: [String: String], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs.bindingsDictionary == rhs, sourceLocation: sourceLocation)
}

private func XCTAssertEqualStrings(_ lhs: String, _ rhs: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(lhs == rhs, sourceLocation: sourceLocation)
}

/// Helper for specifying a node to check.
package enum NodePattern: Sendable {
    /// Accept any node (i.e., ignore this for checking purposes).
    case any
    /// Match an exact path.
    case path(String)
    /// Match a path pattern.
    case pathPattern(StringPattern)
    /// Match an exact name.
    case name(String)
    /// Match a name pattern.
    case namePattern(StringPattern)
}

extension PlannedTaskBuilder: PlannedTaskInputsOutputs {}

/// Helper assertion functions for checking task properties.
package extension PlannedTaskInputsOutputs {
    private func checkNodes(nodes: [any PlannedNode], name: String, patterns: [NodePattern], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(nodes.count == patterns.count, "unexpected \(name) count (\(nodes) vs \(patterns))", sourceLocation: sourceLocation)
        if nodes.count == patterns.count {
            for (lhs, rhs) in zip(nodes, patterns) {
                switch rhs {
                case .any:
                    continue
                case .path(let rhs):
                    // Node paths should always be fully normalized and the slash distinction does not matter
                    #expect(lhs.path == Path(rhs), sourceLocation: sourceLocation)
                case .pathPattern(let rhs):
                    // Node paths should always be fully normalized and the slash distinction does not matter
                    XCTAssertMatch(lhs.path.strWithPosixSlashes, rhs.withPOSIXSlashes, sourceLocation: sourceLocation)
                case .name(let rhs):
                    #expect(lhs.name == rhs, sourceLocation: sourceLocation)
                case .namePattern(let rhs):
                    XCTAssertMatch(lhs.name, rhs, sourceLocation: sourceLocation)
                }
            }
        }
    }

    /// Checks that the inputs for this task matches `patterns` in number and kind.
    func checkInputs(_ patterns: [NodePattern], sourceLocation: SourceLocation = #_sourceLocation) {
        checkNodes(nodes: self.inputs, name: "inputs", patterns: patterns, sourceLocation: sourceLocation)
    }

    /// Checks that the outputs for this task matches `patterns` in number and kind.
    func checkOutputs(_ patterns: [NodePattern], sourceLocation: SourceLocation = #_sourceLocation) {
        checkNodes(nodes: self.outputs, name: "outputs", patterns: patterns, sourceLocation: sourceLocation)
    }

    private func checkNodes(nodes: [any PlannedNode], name: String, contain patterns: [NodePattern], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(nodes.count >= patterns.count, "too many patterns for \(name) (\(nodes) vs \(patterns))", sourceLocation: sourceLocation)
        if nodes.count >= patterns.count {
            for pattern in patterns {
                var foundPattern = false
                for node in nodes {
                    let nodeMatchesPattern: Bool
                    switch pattern {
                    case .any:
                        nodeMatchesPattern = true
                    case .path(let path):
                        // Node paths should always be fully normalized and the slash distinction does not matter
                        nodeMatchesPattern = (node.path == Path(path))
                    case .pathPattern(let pathPattern):
                        // Node paths should always be fully normalized and the slash distinction does not matter
                        nodeMatchesPattern = (pathPattern.withPOSIXSlashes ~= node.path.strWithPosixSlashes)
                    case .name(let name):
                        nodeMatchesPattern = (node.name == name)
                    case .namePattern(let namePattern):
                        nodeMatchesPattern = (namePattern ~= node.name)
                    }
                    if nodeMatchesPattern {
                        foundPattern = true
                        break
                    }
                }
                if !foundPattern {
                    Issue.record("could not match pattern '\(pattern)' against \(name): \(nodes)", sourceLocation: sourceLocation)
                }
            }
        }
    }

    /// Checks that the inputs for this task contain `patterns`.  Note that the same node might match multiple patterns, so the patterns should be constructed to avoid matching multiple nodes.
    func checkInputs(contain patterns: [NodePattern], sourceLocation: SourceLocation = #_sourceLocation) {
        checkNodes(nodes: self.inputs, name: "inputs", contain: patterns, sourceLocation: sourceLocation)
    }

    /// Checks that the outputs for this task contain `patterns`.  Note that the same node might match multiple patterns, so the patterns should be constructed to avoid matching multiple nodes.
    func checkOutputs(contain patterns: [NodePattern], sourceLocation: SourceLocation = #_sourceLocation) {
        checkNodes(nodes: self.outputs, name: "outputs", contain: patterns, sourceLocation: sourceLocation)
    }

    /// Checks that the given list of nodes do *not* contain `patterns`.
    private func checkNodes(nodes: [any PlannedNode], name: String, doNotContain patterns: [NodePattern], sourceLocation: SourceLocation = #_sourceLocation) {
        for pattern in patterns {
            var foundNode: (any PlannedNode)? = nil
            for node in nodes {
                let nodeMatchesPattern: Bool
                switch pattern {
                case .any:
                    nodeMatchesPattern = true
                case .path(let path):
                    nodeMatchesPattern = (node.path.str == path)
                case .pathPattern(let pathPattern):
                    nodeMatchesPattern = (pathPattern ~= node.path.str)
                case .name(let name):
                    nodeMatchesPattern = (node.name == name)
                case .namePattern(let namePattern):
                    nodeMatchesPattern = (namePattern ~= node.name)
                }
                if nodeMatchesPattern {
                    foundNode = node
                    break
                }
            }
            if let foundNode {
                Issue.record("pattern '\(pattern)' matches \(name) node: \(foundNode)", sourceLocation: sourceLocation)
            }
        }
    }

    /// Checks that the inputs for this task do *not* contain `patterns`.
    func checkNoInputs(contain patterns: [NodePattern], sourceLocation: SourceLocation = #_sourceLocation) {
        checkNodes(nodes: self.inputs, name: "input", doNotContain: patterns, sourceLocation: sourceLocation)
    }

    /// Checks that the outputs for this task do *not* contain `patterns`.
    func checkNoOutputs(contain patterns: [NodePattern], sourceLocation: SourceLocation = #_sourceLocation) {
        checkNodes(nodes: self.outputs, name: "output", doNotContain: patterns, sourceLocation: sourceLocation)
    }
}

package extension PlannedTask {
    func checkAdditionalOutput(_ expectedOutput: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        execTask.checkAdditionalOutput(expectedOutput, sourceLocation: sourceLocation)
    }

    func checkDependencyData(_ expected: DependencyDataStyle?, sourceLocation: SourceLocation = #_sourceLocation) {
        execTask.checkDependencyData(expected, sourceLocation: sourceLocation)
    }
}

extension ExecutableTask {
    func checkAdditionalOutput(_ expectedOutput: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(self.additionalOutput == expectedOutput, sourceLocation: sourceLocation)
    }

    func checkDependencyData(_ expected: DependencyDataStyle?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(self.dependencyData == expected, sourceLocation: sourceLocation)
    }
}

extension EnvironmentBindings {
    /// Check whether the values for the keys in `patterns` exist in the task's environment.  The values are optional, which means:
    /// - If the value is nil, then the key must *not* be present in the environment.
    /// - If the value is non-nil, then the key must be present in the environment and match the provided pattern.
    /// - parameter exact: If true, then there must be no other keys defined in the environment beyond the ones specified.
    func checkEnvironment(_ patterns: [String: StringPattern?], exact: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        var environmentDict = self.bindingsDictionary
        for (key, patternOpt) in patterns {
            let valueOpt = environmentDict[key]
            environmentDict.removeValue(forKey: key)
            if let pattern = patternOpt {
                if let value = valueOpt {
                    XCTAssertMatch(value, pattern, "environment variable '\(key)' is '\(value)' which does not match pattern '\(pattern)'", sourceLocation: sourceLocation)
                } else {
                    Issue.record("environment value '\(key)' should be defined but is nil", sourceLocation: sourceLocation)
                }
            }
            else {
                #expect(valueOpt == nil, "environment value '\(key)' should be nil but is '\(valueOpt!)'", sourceLocation: sourceLocation)
            }
        }
        if exact && environmentDict.count > 0 {
            let unexpectedKeys = environmentDict.keys.sorted().joined(separator: " ")
            #expect(environmentDict.isEmpty, "unexpected keys in environment: \(unexpectedKeys)", sourceLocation: sourceLocation)
        }
    }
}

extension PlannedTask {
    package func checkTaskAction(toolIdentifier: String?, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let task = try #require(execTask as? Task, sourceLocation: sourceLocation)
        if let toolIdentifier {
            let action = try #require(task.action, sourceLocation: sourceLocation)
            #expect(Swift.type(of: action).toolIdentifier == toolIdentifier, sourceLocation: sourceLocation)
        } else {
            #expect(task.action == nil, sourceLocation: sourceLocation)
        }
    }
}
