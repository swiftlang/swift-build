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
import Foundation

/// Used only when remote caching is enabled, for remote cache key querying.
/// After the task completes, if the remote key is found, the local CAS will
/// contain the association of the cache key with compilation output IDs.
public final class ClangCachingKeyQueryTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "clang-caching-key-query"
    }

    private let key: ClangCachingTaskCacheKey

    package init(key: ClangCachingTaskCacheKey) {
        self.key = key
        super.init()
    }

    override public var shouldExecuteDetached: Bool {
        return key.casOptions.enableDetachedKeyQueries
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        let clangModuleDependencyGraph = dynamicExecutionDelegate.operationContext.clangModuleDependencyGraph
        do  {
            guard let casDBs = try clangModuleDependencyGraph.getCASDatabases(
                libclangPath: key.libclangPath,
                casOptions: key.casOptions
            ) else {
                throw StubError.error("unable to use CAS databases")
            }

            let cachedComp: ClangCASCachedCompilation?
            do {
                if key.casOptions.enableDetachedKeyQueries {
                    cachedComp = try await casDBs.getCachedCompilation(cacheKey: key.cacheKey)
                } else {
                    // Sync call; key queries are expected to be local and fast (~2ms) and an await call here
                    // just introduces artificial latency, making the execution duration 2.5x slower.
                    cachedComp = try casDBs.getCachedCompilation(cacheKey: key.cacheKey, globally: true)
                }
            } catch {
                guard !key.casOptions.enableStrictCASErrors else { throw error }
                outputDelegate.warning(error.localizedDescription)
                cachedComp = nil
            }
            if key.casOptions.enableDiagnosticRemarks {
                outputDelegate.note("cache \(cachedComp != nil ? "hit" : "miss")")
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
