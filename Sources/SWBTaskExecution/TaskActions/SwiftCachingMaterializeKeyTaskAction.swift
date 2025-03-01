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

/// Used only when remote caching is enabled, to manage tasks for remote key
/// querying and compilation output downloading as dependency tasks.
/// The task on its own doesn't perform any work.
///
/// After this task is finished, the dependent compilation tasks only need to
/// query the local CAS for accessing the data related to a cache key.
public final class SwiftCachingMaterializeKeyTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "swift-caching-materialize-key"
    }

    private let taskKey: SwiftCachingKeyQueryTaskKey

    package init(key: SwiftCachingKeyQueryTaskKey) {
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
        case waitingForKeyQuery(jobTaskIDBase: UInt, cas: SwiftCASDatabases, key: String)
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

        let swiftModuleDependencyGraph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
        do  {
            guard let cas = try swiftModuleDependencyGraph.getCASDatabases(casOptions: taskKey.casOptions, compilerLocation: taskKey.compilerLocation) else {
                throw StubError.error("unable to use CAS databases")
            }
            let jobTaskIDBase: UInt = 0
            if let cachedComp = try cas.queryLocalCacheKey(taskKey.cacheKey) {
                if try requestCompilationOutputs(cachedComp,
                                                 dynamicExecutionDelegate: dynamicExecutionDelegate,
                                                 cacheKey: taskKey.cacheKey,
                                                 jobTaskIDBase: jobTaskIDBase) != 0 {
                    state = .waitingForOutputDownloads
                } else {
                    state = .done
                }
            } else {
                let key = SwiftCachingKeyQueryTaskKey(casOptions: taskKey.casOptions, cacheKey: taskKey.cacheKey, compilerLocation: taskKey.compilerLocation)
                dynamicExecutionDelegate.requestDynamicTask(
                    toolIdentifier: SwiftCachingKeyQueryTaskAction.toolIdentifier,
                    taskKey: .swiftCachingKeyQuery(key),
                    taskID: jobTaskIDBase,
                    singleUse: true,
                    workingDirectory: Path(""),
                    environment: .init(),
                    forTarget: nil,
                    priority: .network,
                    showEnvironment: false,
                    reason: .wasCompilationCachingQuery
                )
                state = .waitingForKeyQuery(jobTaskIDBase: jobTaskIDBase + 1, cas: cas, key: taskKey.cacheKey)
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
        case .waitingForKeyQuery(jobTaskIDBase: let jobTaskIDBase, cas: let cas, key: let key):
            do {
                guard let cachedComp = try cas.queryLocalCacheKey(key) else {
                    state = .done
                    return // compilation key not found.
                }
                if try requestCompilationOutputs(cachedComp,
                                                 dynamicExecutionDelegate: dynamicExecutionDelegate,
                                                 cacheKey: key,
                                                 jobTaskIDBase: jobTaskIDBase) != 0 {
                    state = .waitingForOutputDownloads
                } else {
                    state = .done
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
        _ cachedComp: SwiftCachedCompilation,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        cacheKey: String,
        jobTaskIDBase: UInt
    ) throws -> UInt {
        let requested = try cachedComp.getOutputs().reduce(into: UInt(0)) { (numRequested, output) in
            if output.isMaterialized { return }
            let outputMaterializeKey = SwiftCachingOutputMaterializerTaskKey(casOptions: taskKey.casOptions,
                                                                             casID: output.casID,
                                                                             outputKind: output.kindName,
                                                                             compilerLocation: taskKey.compilerLocation)
            dynamicExecutionDelegate.requestDynamicTask(
                toolIdentifier: SwiftCachingOutputMaterializerTaskAction.toolIdentifier,
                taskKey: .swiftCachingOutputMaterializer(outputMaterializeKey),
                taskID: jobTaskIDBase + numRequested,
                singleUse: true,
                workingDirectory: Path(""),
                environment: .init(),
                forTarget: nil,
                priority: .network,
                showEnvironment: false,
                reason: .wasCompilationCachingQuery
            )
            numRequested += 1
        }
        return requested
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

