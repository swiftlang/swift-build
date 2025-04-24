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
public final class SwiftCachingKeyQueryTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "swift-caching-key-query"
    }

    private let key: SwiftCachingKeyQueryTaskKey

    package init(key: SwiftCachingKeyQueryTaskKey) {
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
        let swiftModuleDependencyGraph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
        do  {
            guard let cas = try swiftModuleDependencyGraph.getCASDatabases(casOptions: key.casOptions, compilerLocation: key.compilerLocation) else {
                throw StubError.error("unable to use CAS databases")
            }

            do {
                // Request global query to get maximum search space that the database supports
                for cacheKey in key.cacheKeys {
                    let cacheHit = try await cas.queryCacheKey(cacheKey, globally: true) != nil
                    if key.casOptions.enableDiagnosticRemarks {
                        outputDelegate.note("cache key query \(cacheHit ? "hit" : "miss")")
                    }
                    guard cacheHit else {
                        // return on first failure.
                        return .succeeded
                    }
                }
            } catch {
                guard !key.casOptions.enableStrictCASErrors else { throw error }
                outputDelegate.warning(error.localizedDescription)
                if key.casOptions.enableDiagnosticRemarks {
                    outputDelegate.note("cache key query failed")
                }
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

