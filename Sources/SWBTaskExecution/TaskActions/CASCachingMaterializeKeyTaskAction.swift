//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBUtil
public import SWBCore
public import SWBLLBuild
import SWBCAS
import Foundation

/// Used only when remote caching is enabled, to manage tasks for remote key
/// querying and CAS output downloading as dependency tasks.
/// The task on its own doesn't perform any work.
///
/// After this task is finished, the dependent tasks only need to query the
/// local CAS for accessing the data related to a cache key.
public final class CASCachingMaterializeKeyTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        return "cas-caching-materialize-key"
    }

    private let taskKey: CASCachingTaskCacheKey

    package init(key: CASCachingTaskCacheKey) {
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
        case waitingForKeyQuery(jobTaskIDBase: UInt, keyID: ToolchainDataID, cas: ToolchainCAS)
        /// Waiting for the outputs to finish downloading.
        case waitingForObjectDownload
        /// Not waiting for any other dependency
        case done

        /// The action failed internally.
        case executionError(any Error)

        mutating func reset() {
            self = .initial
        }
    }

    private var state = State.initial

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        fatalError("Unexpectedly called the old version of isResultValid")
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue, fallback: (BuildValue) -> Bool) -> Bool {
        // Remote cache query tasks should always run when requested.
        return false
    }

    public override func taskSetup(
        _ task: any ExecutableTask,
        executionDelegate: any TaskExecutionDelegate,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate
    ) {
        state.reset()

        do {
            let cas = try dynamicExecutionDelegate.operationContext.getOrCreateCAS(options: taskKey.casOptions.creationOpts)
            let keyID = try cas.objectID(forPrintedID: taskKey.cacheKey)

            if let dataID = try cas.lookupCachedObject(for: keyID, globally: false) {
                let wasRequested = try requestObject(dataID, cas: cas, dynamicExecutionDelegate: dynamicExecutionDelegate, jobTaskIDBase: 0)
                if wasRequested {
                    state = .waitingForObjectDownload
                } else {
                    state = .done
                }
            } else {
                let dependencyID: UInt = 0
                dynamicExecutionDelegate.requestDynamicTask(
                    toolIdentifier: CASCachingKeyQueryTaskAction.toolIdentifier,
                    taskKey: .casCachingKeyQuery(taskKey),
                    taskID: dependencyID,
                    singleUse: true,
                    workingDirectory: Path(""),
                    environment: .init(),
                    forTarget: nil,
                    priority: .network,
                    showEnvironment: false,
                    reason: .wasCompilationCachingQuery
                )
                state = .waitingForKeyQuery(jobTaskIDBase: dependencyID + 1, keyID: keyID, cas: cas)
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
        case .waitingForKeyQuery(jobTaskIDBase: let jobTaskIDBase, keyID: let keyID, cas: let cas):
            do {
                guard let dataID = try cas.lookupCachedObject(for: keyID, globally: false) else {
                    state = .done
                    return // key not found.
                }
                let wasRequested = try requestObject(dataID, cas: cas, dynamicExecutionDelegate: dynamicExecutionDelegate, jobTaskIDBase: jobTaskIDBase)
                if wasRequested {
                    state = .waitingForObjectDownload
                } else {
                    state = .done
                }
            } catch {
                state = .executionError(error)
                return
            }
        case .waitingForObjectDownload:
            break
        case .done:
            state = .executionError(StubError.error("taskDependencyReady unexpectedly called while not waiting on a dependency"))
        case .executionError(_):
            break
        }
    }

    private func requestObject(
        _ dataID: ToolchainDataID,
        cas: ToolchainCAS,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        jobTaskIDBase: UInt
    ) throws -> Bool {
        if try cas.isMaterialized(id: dataID) {
            return false
        }
        let objectMaterializeKey = CASCachingObjectMaterializerTaskKey(
            casID: cas.printID(dataID),
            casOptions: taskKey.casOptions,
        )
        dynamicExecutionDelegate.requestDynamicTask(
            toolIdentifier: CASCachingObjectMaterializerTaskAction.toolIdentifier,
            taskKey: .casCachingObjectMaterializer(objectMaterializeKey),
            taskID: jobTaskIDBase,
            singleUse: true,
            workingDirectory: Path(""),
            environment: .init(),
            forTarget: nil,
            priority: .network,
            showEnvironment: false,
            reason: .wasCompilationCachingQuery
        )
        return true
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
