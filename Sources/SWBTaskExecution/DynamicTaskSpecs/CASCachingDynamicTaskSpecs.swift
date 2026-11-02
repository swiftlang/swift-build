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

import SWBCore
public import SWBUtil

public struct CASCachingTaskCacheKey: Serializable, CustomDebugStringConvertible {
    let cacheKey: String
    let casOptions: CASOptions

    init(cacheKey: String, casOptions: CASOptions) {
        self.cacheKey = cacheKey
        self.casOptions = casOptions
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(2) {
            serializer.serialize(cacheKey)
            serializer.serialize(casOptions)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        cacheKey = try deserializer.deserialize()
        casOptions = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<CASCachingTaskCacheKey cacheKey=\(cacheKey) casOptions=\(casOptions)>"
    }
}

final class CASCachingMaterializeKeyDynamicTaskSpec: DynamicTaskSpec {
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> Task {
        guard case let .casCachingMaterializeKey(casCachingTaskKey) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTask.taskKey)")
        }

        let cacheKey = casCachingTaskKey.cacheKey
        return Task(
            type: self,
            payload: nil,
            forTarget: dynamicTask.target,
            ruleInfo: ["CASCachingMaterializeKey", cacheKey],
            commandLine: ["builtin-CASCachingMaterializeKey", .literal(ByteString(encodingAsUTF8: cacheKey))],
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: "CAS caching materialize key \(cacheKey)",
            priority: .network,
            isDynamic: true
        )
    }

    package func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        guard case let .casCachingMaterializeKey(casCachingTaskKey) = dynamicTaskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTaskKey)")
        }
        return CASCachingMaterializeKeyTaskAction(key: casCachingTaskKey)
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Should always start if requested.
        return true
    }
}

final class CASCachingKeyQueryDynamicTaskSpec: DynamicTaskSpec {
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> Task {
        guard case let .casCachingKeyQuery(casCachingKeyQueryTaskKey) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTask.taskKey)")
        }

        let cacheKey = casCachingKeyQueryTaskKey.cacheKey
        return Task(
            type: self,
            payload: nil,
            forTarget: dynamicTask.target,
            ruleInfo: ["CASCachingKeyQuery", cacheKey],
            commandLine: ["builtin-CASCachingKeyQuery", .literal(ByteString(encodingAsUTF8: cacheKey))],
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: "CAS caching query key \(cacheKey)",
            priority: .network,
            isDynamic: true
        )
    }

    package func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        guard case let .casCachingKeyQuery(casCachingKeyQueryTaskKey) = dynamicTaskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTaskKey)")
        }
        return CASCachingKeyQueryTaskAction(key: casCachingKeyQueryTaskKey)
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Should always start if requested.
        return true
    }
}

public struct CASCachingObjectMaterializerTaskKey: Serializable, CustomDebugStringConvertible {
    let casID: String
    let casOptions: CASOptions

    init(
        casID: String,
        casOptions: CASOptions,
    ) {
        self.casID = casID
        self.casOptions = casOptions
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(2) {
            serializer.serialize(casID)
            serializer.serialize(casOptions)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        casID = try deserializer.deserialize()
        casOptions = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<CASCachingObjectMaterializer casID=\(casID) casOptions=\(casOptions)>"
    }
}

final class CASCachingObjectMaterializerDynamicTaskSpec: DynamicTaskSpec {
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> Task {
        guard case let .casCachingObjectMaterializer(objectMaterializerTaskKey) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTask.taskKey)")
        }

        let casID = objectMaterializerTaskKey.casID
        return Task(
            type: self,
            payload: nil,
            forTarget: dynamicTask.target,
            ruleInfo: ["CASCachingObjectMaterializer", casID],
            commandLine: ["builtin-CASCachingObjectMaterializer", .literal(ByteString(encodingAsUTF8: casID))],
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: "CAS caching materialize object \(casID)",
            priority: .network,
            isDynamic: true
        )
    }

    package func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        guard case let .casCachingObjectMaterializer(casCachingObjectMaterializerTaskKey) = dynamicTaskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTaskKey)")
        }
        return CASCachingObjectMaterializerTaskAction(key: casCachingObjectMaterializerTaskKey)
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Should always start if requested.
        return true
    }
}
