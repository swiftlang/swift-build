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
import SWBCAS
import Foundation

/// Used only when remote caching is enabled, for remote cache key querying.
/// After the task completes, if the remote key is found, the local CAS will
/// contain the association of the cache key with output IDs.
public final class CASCachingKeyQueryTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        return "cas-caching-key-query"
    }

    private let key: CASCachingTaskCacheKey

    package init(key: CASCachingTaskCacheKey) {
        self.key = key
        super.init()
    }

    override public var shouldExecuteDetached: Bool {
        return key.casOptions.enableDetachedKeyQueries
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        fatalError("Unexpectedly called the old version of isResultValid")
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue, fallback: (BuildValue) -> Bool) -> Bool {
        // Remote cache query tasks should always run when requested.
        return false
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        do {
            let cas = try dynamicExecutionDelegate.operationContext.getOrCreateCAS(options: key.casOptions.creationOpts)
            let keyID = try cas.objectID(forPrintedID: key.cacheKey)

            let dataID: ToolchainDataID?
            do {
                if key.casOptions.enableDetachedKeyQueries {
                    dataID = try await cas.lookupCachedObjectGlobally(for: keyID)
                } else {
                    // Sync call; key queries are expected to be local and fast (~2ms) and an await call here
                    // just introduces artificial latency, making the execution duration 2.5x slower.
                    dataID = try cas.lookupCachedObject(for: keyID, globally: true)
                }
            } catch {
                guard !key.casOptions.enableStrictCASErrors else { throw error }
                outputDelegate.warning(error.localizedDescription)
                dataID = nil
            }
            if key.casOptions.enableDiagnosticRemarks {
                outputDelegate.note("cache \(dataID != nil ? "hit" : "miss")")
            }
            return .succeeded
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }
    }

    public override func cancelDetached() {
        // FIXME: Cancellation.
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(key)
        super.serialize(to: serializer)
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.key = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}
