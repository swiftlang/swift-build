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

import SWBUtil
import SWBLibc
public import SWBCore
public import enum SWBLLBuild.BuildValueKind
import Foundation
import SWBProtocol

open class SwiftDriverJobSchedulingTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        assertionFailure("Subclass responsibility")
        return ""
    }


     private enum State {
         /// The action is in it's initial state, and has not yet performed any work
         case initial
         /// The action is waiting for execution inputs to be produced. Execution inputs include everything that would be considered an input to a standalone invocation of the driver (source files, output file map, gate tasks, etc.).
         case waitingForExecutionInputs(openExecutionInputIDs: Set<UInt>, jobTaskIDBase: UInt)
         /// The action has requested a planning task for a target, and is waiting for the resulting planned build.
         case planning(jobTaskIDBase: UInt)
         /// A planned build is available, and the action is requesting and running tasks for individual jobs.
         case requestingDriverJobs(primaryJobsTaskIDs: Set<UInt>, secondaryJobTaskIDs: Set<UInt>, discoveredJobTaskIDs: Set<UInt>, jobTaskIDBase: UInt)

         /// A dependency of the action failed.
         case failedDependencies
         /// The action failed internally
         case executionError(any Error)

         mutating func reset() {
             self = .initial
         }
     }

    private var state = State.initial

    public override func taskSetup(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        state.reset()

        // Request execution inputs and move to the `waitingForExecutionInputs` state
        if let executionInputs = task.executionInputs {
            let openExecutionInputIDs = Set(executionInputs.indices.map(UInt.init))
            // `jobTaskIDBase` represents the first ID corresponding to a planned driver job. 0..<executionInputs.count are execution input IDs, executionInputs.count is the dynamic planning ID, and (executionInputs.count + 1)... are driver job IDs.
            let jobTaskIDBase = UInt(executionInputs.count) + 1
            state = .waitingForExecutionInputs(openExecutionInputIDs: openExecutionInputIDs, jobTaskIDBase: jobTaskIDBase)
            for (index, input) in executionInputs.enumerated() {
                dynamicExecutionDelegate.requestInputNode(node: input, nodeID: UInt(index))
            }
        }
    }

    public override func taskDependencyReady(_ task: any ExecutableTask, _ dependencyID: UInt, _ buildValueKind: BuildValueKind?, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate) {
        guard let buildValueKind else {
            state = .failedDependencies
            return
        }
        if buildValueKind.isFailed {
            if case .prepareForIndexing = executionDelegate.buildCommand, case .waitingForExecutionInputs = state {
                // Ignore the failed dependency.
            } else {
                state = .failedDependencies
                return
            }
        }

        guard let payload = task.payload as? SwiftTaskPayload, let driverPayload = payload.driverPayload else {
            state = .executionError(StubError.error("Invalid payload for Swift explicit module support"))
            return
        }

        let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph

        switch state {
        case .initial:
            state = .executionError(StubError.error("taskDependencyReady unexpectedly called in initial state"))
        case .waitingForExecutionInputs(openExecutionInputIDs: var openExecutionInputIDs, jobTaskIDBase: let jobTaskIDBase):
            if openExecutionInputIDs.contains(dependencyID) {
                openExecutionInputIDs.remove(dependencyID)
                state = .waitingForExecutionInputs(openExecutionInputIDs: openExecutionInputIDs, jobTaskIDBase: jobTaskIDBase)
            }
            // If all execution inputs are now available, request the driver planning task and move to the `planning` state.
            if openExecutionInputIDs.isEmpty {
                dynamicExecutionDelegate.requestDynamicTask(toolIdentifier: SwiftDriverTaskAction.toolIdentifier,
                                                            taskKey: .swiftDriverPlanning(.init(swiftPayload: payload)),
                                                            taskID: jobTaskIDBase - 1,
                                                            singleUse: true,
                                                            workingDirectory: task.workingDirectory,
                                                            environment: task.environment,
                                                            forTarget: task.forTarget,
                                                            priority: .unblocksDownstreamTasks,
                                                            showEnvironment: task.showEnvironment,
                                                            reason: .wasScheduledBySwiftDriver)
                state = .planning(jobTaskIDBase: jobTaskIDBase)
            }
            return
        case .planning(jobTaskIDBase: let jobTaskIDBase):
            if buildValueKind == .skippedCommand {
                // If planning was skipped, for example because it didn't start in a prepare-for-indexing build, move into the failed dependencies state so that we cancel.
                state = .failedDependencies
                return
            }
            // If the planning task is complete, begin requesting dynamic tasks for jobs and move to the `requestingDriverJobs` state.
            guard dependencyID == jobTaskIDBase - 1 else { return }
            do {
                let plannedBuild = try graph.queryPlannedBuild(for: driverPayload.uniqueID)
                let primaryJobs = primaryJobs(for: plannedBuild, driverPayload: driverPayload)
                let untrackedPrimaryJobs = untrackedPrimaryJobs(for: plannedBuild, driverPayload: driverPayload)
                if !primaryJobs.isEmpty {
                    var primaryJobsTaskIDs: Set<UInt> = []
                    scheduleJobs(dynamicExecutionDelegate, task, driverPayload: driverPayload, plannedBuild: plannedBuild, primaryJobs, cacheTaskID: { primaryJobsTaskIDs.insert($0) }, jobTaskIDBase: jobTaskIDBase)
                    scheduleJobs(dynamicExecutionDelegate, task, driverPayload: driverPayload, plannedBuild: plannedBuild, untrackedPrimaryJobs, jobTaskIDBase: jobTaskIDBase)
                    state = .requestingDriverJobs(primaryJobsTaskIDs: primaryJobsTaskIDs, secondaryJobTaskIDs: [], discoveredJobTaskIDs: [], jobTaskIDBase: jobTaskIDBase)
                } else {
                    var secondaryJobTaskIDs: Set<UInt> = []
                    scheduleJobs(dynamicExecutionDelegate, task, driverPayload: driverPayload, plannedBuild: plannedBuild, secondaryJobs(for: plannedBuild, driverPayload: driverPayload), cacheTaskID: { secondaryJobTaskIDs.insert($0) }, jobTaskIDBase: jobTaskIDBase)
                    state = .requestingDriverJobs(primaryJobsTaskIDs: [], secondaryJobTaskIDs: secondaryJobTaskIDs, discoveredJobTaskIDs: [], jobTaskIDBase: jobTaskIDBase)
                }
            } catch {
                state = .executionError(error)
            }
        case .requestingDriverJobs(primaryJobsTaskIDs: var primaryJobsTaskIDs, secondaryJobTaskIDs: var secondaryJobTaskIDs, discoveredJobTaskIDs: var discoveredJobTaskIDs, jobTaskIDBase: let jobTaskIDBase):
            do {
                func scheduleDiscoveredJobs(for dependencyID: UInt) throws {
                    let plannedBuild = try graph.queryPlannedBuild(for: driverPayload.uniqueID)

                    guard let jobFinished = plannedBuild.plannedTargetJob(for: .targetJob(Int(dependencyID - jobTaskIDBase))) else {
                        return
                    }

                    let signatureCtx = InsecureHashContext()
                    signatureCtx.add(string: task.identifier.rawValue)
                    signatureCtx.add(string: "swiftdriverjobdiscoveryactivity")
                    signatureCtx.add(number: dependencyID)

                    try dynamicExecutionDelegate.withActivity(ruleInfo: "SwiftDriverJobDiscovery \(driverPayload.variant) \(driverPayload.architecture) \(jobFinished.description)", executionDescription: "Discovering Swift tasks after '\(jobFinished.description)'", signature: signatureCtx.signature, target: task.forTarget, parentActivity: nil) { _ in
                        let discovered = try plannedBuild.getDiscoveredJobsAfterFinishing(job: jobFinished)
                        scheduleJobs(dynamicExecutionDelegate, task, driverPayload: driverPayload, plannedBuild: plannedBuild, discovered, cacheTaskID: { discoveredJobTaskIDs.insert($0) }, jobTaskIDBase: jobTaskIDBase)
                        return .succeeded
                    }
                }

                if primaryJobsTaskIDs.contains(dependencyID) {
                    primaryJobsTaskIDs.remove(dependencyID)

                    // Explicit module tasks have no secondary or discovered, etc. jobs.
                    if Self.toolIdentifier != "swift-driver-explicit-modules" {
                        try scheduleDiscoveredJobs(for: dependencyID)

                        if primaryJobsTaskIDs.isEmpty {
                            // Primary tasks done, schedule secondary tasks
                            let plannedBuild = try graph.queryPlannedBuild(for: driverPayload.uniqueID)
                            scheduleJobs(dynamicExecutionDelegate, task, driverPayload: driverPayload, plannedBuild: plannedBuild, secondaryJobs(for: plannedBuild, driverPayload: driverPayload), cacheTaskID: { secondaryJobTaskIDs.insert($0) }, jobTaskIDBase: jobTaskIDBase)
                        }
                    }
                } else if secondaryJobTaskIDs.contains(dependencyID) {
                    secondaryJobTaskIDs.remove(dependencyID)
                    try scheduleDiscoveredJobs(for: dependencyID)
                } else if discoveredJobTaskIDs.contains(dependencyID) {
                    discoveredJobTaskIDs.remove(dependencyID)
                    try scheduleDiscoveredJobs(for: dependencyID)
                } else {
                    // Ignore any other reported inputs
                }
                state = .requestingDriverJobs(primaryJobsTaskIDs: primaryJobsTaskIDs, secondaryJobTaskIDs: secondaryJobTaskIDs, discoveredJobTaskIDs: discoveredJobTaskIDs, jobTaskIDBase: jobTaskIDBase)
            } catch {
                state = .executionError(error)
            }
        case .failedDependencies:
            break
        case .executionError(_):
            break
        }
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        defer {
            state.reset()
        }

        if case .executionError(let error) = state {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }

        if case .failedDependencies = state {
            return .cancelled
        }

        guard let driverPayload = (task.payload as? SwiftTaskPayload)?.driverPayload else {
            outputDelegate.error(StubError.error("Invalid payload for Swift explicit module support"))
            return .failed
        }

        // Report skipped jobs if this is the last task action to run
        let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
        do {
            let plannedBuild = try graph.queryPlannedBuild(for: driverPayload.uniqueID)
            guard case .requestingDriverJobs(primaryJobsTaskIDs: let primaryJobsTaskIDs, secondaryJobTaskIDs: let secondaryJobTaskIDs, discoveredJobTaskIDs: let discoveredJobTaskIDs, jobTaskIDBase: let jobTaskIDBase) = state else {
                throw StubError.error("Finished job execution in unexpected state: \(state)")
            }
            guard primaryJobsTaskIDs.isEmpty, secondaryJobTaskIDs.isEmpty, discoveredJobTaskIDs.isEmpty else {
                let jobs = primaryJobsTaskIDs.union(secondaryJobTaskIDs).union(discoveredJobTaskIDs).compactMap {
                    plannedBuild.plannedTargetJob(for: .targetJob(Int($0 - jobTaskIDBase)))
                }
                throw StubError.error("Internal error with integrated Swift driver. Some planned jobs weren't tracked accordingly: [\(jobs.map(\.debugDescription))]")
            }

            if shouldReportSkippedJobs(driverPayload: driverPayload) {
                try reportSkippedJobs(task, outputDelegate: outputDelegate, driverPayload: driverPayload, plannedBuild: plannedBuild, dynamicExecutionDelegate: dynamicExecutionDelegate)
            }

            let planningDependencies = try graph.queryPlanningDependencies(for: driverPayload.uniqueID)
            if executionDelegate.userPreferences.enableDebugActivityLogs {
                outputDelegate.emitOutput(ByteString(encodingAsUTF8: "Discovered dependency nodes:\n" + planningDependencies.joined(separator: "\n") + "\n"))
            }

            if driverPayload.verifyScannerDependencies {
                if case .makefileIgnoringSubsequentOutputs(let makefilePath) = task.dependencyData {
                    // This is a very rudimentary parser for make-style dependencies as emitted by swiftc.
                    let contents = try executionDelegate.fs.read(makefilePath)
                    let firstLine = contents.asString.split("\n").0
                    let inputs = firstLine.split(":").1.components(separatedBy: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    let makeStyleInputs = Set(inputs)
                    let scannerInputs = Set(planningDependencies)
                    let inputsMissedByScanner = makeStyleInputs.subtracting(scannerInputs)
                    for missedInput in inputsMissedByScanner.sorted() {
                        outputDelegate.emitError("Dependency scanner failed to report input '\(missedInput)' present in '\(makefilePath.str)'")
                    }
                }
            }

            let dependencyFilteringRootPathString = driverPayload.dependencyFilteringRootPath?.str
            for dep in planningDependencies {
                if let dependencyFilteringRootPathString {
                    // We intentionally do a prefix check instead of an ancestor check here, for performance reasons. The filtering path (SDK path) and paths returned by the compiler are guaranteed to be normalized, which makes this safe.
                    if !dep.hasPrefix(dependencyFilteringRootPathString) {
                        dynamicExecutionDelegate.discoveredDependencyNode(ExecutionNode(identifier: dep))
                    }
                } else {
                    dynamicExecutionDelegate.discoveredDependencyNode(ExecutionNode(identifier: dep))
                }
            }
        } catch {
            outputDelegate.error(error)
            return .failed
        }

        return .succeeded
    }


    open func primaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        assertionFailure("Subclass responsibility")
        return []
    }

    open func untrackedPrimaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        assertionFailure("Subclass responsibility")
        return []
    }

    open func secondaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        return []
    }

    open func shouldReportSkippedJobs(driverPayload: SwiftDriverPayload) -> Bool {
        /// Open to subclasses to decide
        false
    }

    private func reportSkippedJobs(_ task: any ExecutableTask, outputDelegate: any TaskOutputDelegate, driverPayload: SwiftDriverPayload, plannedBuild: LibSwiftDriver.PlannedBuild, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) throws {
        let spec = SwiftDriverJobDynamicTaskSpec()
        try plannedBuild.reportSkippedJobs { job in
            if job.driverJob.ruleInfoType == "Compile" {
                // When reported as skipped, compile jobs are treated like per-file virtual subtasks which have been 'hoisted' up as top-level tasks.
                guard let target = task.forTarget, let singleInput = job.driverJob.displayInputs.only else {
                    return
                }
                outputDelegate.previouslyBatchedSubtaskUpToDate(signature: SwiftCompilerSpec.computeRuleInfoAndSignatureForPerFileVirtualBatchSubtask(variant: driverPayload.variant, arch: driverPayload.architecture, path: singleInput).1, target: target)
            } else {
                // Other jobs are reported as skipped/up-to-date in the usual way.
                let taskKey = SwiftDriverJobTaskKey(identifier: driverPayload.uniqueID, variant: driverPayload.variant, arch: driverPayload.architecture, driverJobKey: job.key, driverJobSignature: job.driverJob.signature, isUsingWholeModuleOptimization: driverPayload.isUsingWholeModuleOptimization, compilerLocation: driverPayload.compilerLocation, casOptions: driverPayload.casOptions)
                let dynamicTask = DynamicTask(toolIdentifier: SwiftDriverJobTaskAction.toolIdentifier, taskKey: .swiftDriverJob(taskKey), workingDirectory: task.workingDirectory, environment: task.environment, target: task.forTarget, showEnvironment: task.showEnvironment)
                let subtask = try spec.buildExecutableTask(dynamicTask: dynamicTask, context: dynamicExecutionDelegate.operationContext)
                outputDelegate.subtaskUpToDate(subtask)
            }
        }
    }

    internal func constructDriverJobTaskKey(driverPayload: SwiftDriverPayload,
                                            plannedJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob) -> DynamicTaskKey {
        let key: DynamicTaskKey
        if plannedJob.driverJob.categorizer.isExplicitDependencyBuild {
            key = .swiftDriverExplicitDependencyJob(SwiftDriverExplicitDependencyJobTaskKey(
                arch: driverPayload.architecture,
                driverJobKey: plannedJob.key,
                driverJobSignature: plannedJob.driverJob.signature,
                compilerLocation: driverPayload.compilerLocation,
                casOptions: driverPayload.casOptions))
        } else {
            key = .swiftDriverJob(SwiftDriverJobTaskKey(
                identifier: driverPayload.uniqueID,
                variant: driverPayload.variant,
                arch: driverPayload.architecture,
                driverJobKey: plannedJob.key,
                driverJobSignature: plannedJob.driverJob.signature,
                isUsingWholeModuleOptimization: driverPayload.isUsingWholeModuleOptimization,
                compilerLocation: driverPayload.compilerLocation,
                casOptions: driverPayload.casOptions))
        }
        return key
    }

    private func scheduleJobs<S: Collection>(_ dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, _ task: any ExecutableTask, driverPayload: SwiftDriverPayload, plannedBuild: LibSwiftDriver.PlannedBuild, _ jobs: S, cacheTaskID: ((UInt) -> Void)? = nil, jobTaskIDBase: UInt) where S.Element == LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob {
        for plannedJob in jobs {
            let isExplicitDependencyBuildJob = plannedJob.driverJob.categorizer.isExplicitDependencyBuild
            let taskID: UInt
            switch plannedJob.key {
                case .targetJob(let index):
                    taskID = UInt(index) + jobTaskIDBase
                case .explicitDependencyJob(let index):
                    taskID = UInt(index) + jobTaskIDBase + UInt(plannedBuild.targetBuildJobCount)
            }
            cacheTaskID?(taskID)
            let taskKey = constructDriverJobTaskKey(driverPayload: driverPayload, plannedJob: plannedJob)
            dynamicExecutionDelegate.requestDynamicTask(
                toolIdentifier: SwiftDriverJobTaskAction.toolIdentifier,
                taskKey: taskKey,
                taskID: taskID,
                singleUse: true,
                workingDirectory: plannedJob.workingDirectory,
                environment: task.environment,
                forTarget: isExplicitDependencyBuildJob ? nil : task.forTarget,
                priority: plannedJob.driverJob.categorizer.priority,
                showEnvironment: task.showEnvironment,
                reason: .wasScheduledBySwiftDriver
            )
        }
    }
}
