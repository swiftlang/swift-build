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
public import SWBCore
public import SWBLLBuild
import Foundation

/// Used only when remote caching is enabled, to manage tasks for remote key
/// querying and compilation output downloading as dependency tasks.
/// The task on its own doesn't perform any work.
///
/// After this task is finished, the dependent compilation tasks only need to
/// query the local CAS for accessing the data related to a cache key.
public final class ClangCachingMaterializeKeyTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "clang-caching-materialize-key"
    }

    private let taskKey: ClangCachingTaskCacheKey

    package init(key: ClangCachingTaskCacheKey) {
        self.taskKey = key
        super.init()
    }

    /// It doesn't perform any work, no need to be scheduled for an execution lane.
    override public var shouldExecuteDetached: Bool {
        return true
    }

    private enum State {
        /// The action is in its initial state, and has not yet performed any work.
        case initial
        /// Waiting for the caching key query to finish.
        case waitingForKeyQuery(jobTaskIDBase: UInt, casDBs: ClangCASDatabases)
        /// Waiting for the outputs to finish downloading.
        case waitingForOutputDownloads
        /// Not waiting for any other dependency
        case done

        /// The action failed internally.
        case executionError(any Error)

        mutating func reset() {
            self = .initial
        }
    }

    private var state = State.initial

    public override func taskSetup(
        _ task: any ExecutableTask,
        executionDelegate: any TaskExecutionDelegate,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate
    ) {
        state.reset()

        let clangModuleDependencyGraph = dynamicExecutionDelegate.operationContext.clangModuleDependencyGraph
        do  {
            guard let casDBs = try clangModuleDependencyGraph.getCASDatabases(
                libclangPath: taskKey.libclangPath,
                casOptions: taskKey.casOptions
            ) else {
                throw StubError.error("unable to use CAS databases")
            }

            if let cachedComp = try casDBs.getLocalCachedCompilation(cacheKey: taskKey.cacheKey) {
                let numOutputsToDownload = requestCompilationOutputs(cachedComp, dynamicExecutionDelegate: dynamicExecutionDelegate, jobTaskIDBase: 0)
                if numOutputsToDownload == 0 {
                    state = .done
                } else {
                    state = .waitingForOutputDownloads
                }
            } else {
                let dependencyID: UInt = 0
                dynamicExecutionDelegate.requestDynamicTask(
                    toolIdentifier: ClangCachingKeyQueryTaskAction.toolIdentifier,
                    taskKey: .clangCachingKeyQuery(taskKey),
                    taskID: dependencyID,
                    singleUse: true,
                    workingDirectory: Path(""),
                    environment: .init(),
                    forTarget: nil,
                    priority: .network,
                    showEnvironment: false,
                    reason: .wasCompilationCachingQuery
                )
                state = .waitingForKeyQuery(jobTaskIDBase: dependencyID + 1, casDBs: casDBs)
            }
        } catch {
            state = .executionError(error)
            return
        }
    }

    public override func taskDependencyReady(
        _ task: any ExecutableTask,
        _ dependencyID: UInt,
        _ buildValueKind: BuildValueKind?,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate
    ) {
        switch state {
        case .initial:
            state = .executionError(StubError.error("taskDependencyReady unexpectedly called in initial state"))
        case .waitingForKeyQuery(jobTaskIDBase: let jobTaskIDBase, casDBs: let casDBs):
            do {
                guard let cachedComp = try casDBs.getLocalCachedCompilation(cacheKey: taskKey.cacheKey) else {
                    state = .done
                    return // compilation key not found.
                }
                let numOutputsToDownload = requestCompilationOutputs(cachedComp, dynamicExecutionDelegate: dynamicExecutionDelegate, jobTaskIDBase: jobTaskIDBase)
                if numOutputsToDownload == 0 {
                    state = .done
                } else {
                    state = .waitingForOutputDownloads
                }
            } catch {
                state = .executionError(error)
                return
            }
        case .waitingForOutputDownloads:
            break
        case .done:
            state = .executionError(StubError.error("taskDependencyReady unexpectedly called while not waiting on a dependency"))
        case .executionError(_):
            break
        }
    }

    private func requestCompilationOutputs(
        _ cachedComp: ClangCASCachedCompilation,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        jobTaskIDBase: UInt
    ) -> Int {
        var numOutputsToDownload = 0
        for output in cachedComp.getOutputs() {
            guard !cachedComp.isOutputMaterialized(output) else {
                continue
            }

            let outputMaterializeKey = ClangCachingOutputMaterializerTaskKey(
                libclangPath: taskKey.libclangPath,
                casOptions: taskKey.casOptions,
                casID: output.casID,
                outputName: output.name
            )
            dynamicExecutionDelegate.requestDynamicTask(
                toolIdentifier: ClangCachingOutputMaterializerTaskAction.toolIdentifier,
                taskKey: .clangCachingOutputMaterializer(outputMaterializeKey),
                taskID: jobTaskIDBase + UInt(numOutputsToDownload),
                singleUse: true,
                workingDirectory: Path(""),
                environment: .init(),
                forTarget: nil,
                priority: .network,
                showEnvironment: false,
                reason: .wasCompilationCachingQuery
            )
            numOutputsToDownload += 1
        }
        return numOutputsToDownload
    }

    public override func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        defer {
            state.reset()
        }

        if case .executionError(let error) = state {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }

        return .succeeded
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(taskKey)
        super.serialize(to: serializer)
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.taskKey = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}
