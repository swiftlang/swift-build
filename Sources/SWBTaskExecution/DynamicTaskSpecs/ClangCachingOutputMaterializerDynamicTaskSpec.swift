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
public import SWBUtil

public struct ClangCachingOutputMaterializerTaskKey: Serializable, CustomDebugStringConvertible {
    let libclangPath: Path
    let casOptions: CASOptions
    let casID: String
    let outputName: String

    init(
        libclangPath: Path,
        casOptions: CASOptions,
        casID: String,
        outputName: String
    ) {
        self.libclangPath = libclangPath
        self.casOptions = casOptions
        self.casID = casID
        self.outputName = outputName
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(4) {
            serializer.serialize(libclangPath)
            serializer.serialize(casOptions)
            serializer.serialize(casID)
            serializer.serialize(outputName)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        libclangPath = try deserializer.deserialize()
        casOptions = try deserializer.deserialize()
        casID = try deserializer.deserialize()
        outputName = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<ClangCachingOutputMaterializer libclangPath=\(libclangPath) casOptions=\(casOptions) casID=\(casID) outputName=\(outputName)>"
    }
}

final class ClangCachingOutputMaterializerDynamicTaskSpec: DynamicTaskSpec {
    package func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> any ExecutableTask {
        guard case let .clangCachingOutputMaterializer(outputMaterializerTaskKey) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTask.taskKey)")
        }

        let outputName = outputMaterializerTaskKey.outputName
        let casID = outputMaterializerTaskKey.casID
        return Task(
            type: self,
            payload: nil,
            forTarget: dynamicTask.target,
            ruleInfo: ["ClangCachingOutputMaterializer", outputName, casID],
            commandLine: ["builtin-clangCachingOutputMaterializer", .literal(ByteString(encodingAsUTF8: outputName)), .literal(ByteString(encodingAsUTF8: casID))],
            environment: dynamicTask.environment,
            workingDirectory: dynamicTask.workingDirectory,
            showEnvironment: dynamicTask.showEnvironment,
            execDescription: "Clang caching materialize \(outputName) from \(casID)",
            priority: .network,
            isDynamic: true
        )
    }

    package func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        guard case let .clangCachingOutputMaterializer(clangCachingOutputMaterializerTaskKey) = dynamicTaskKey else {
            fatalError("Unexpected dynamic task key \(dynamicTaskKey)")
        }
        return ClangCachingOutputMaterializerTaskAction(key: clangCachingOutputMaterializerTaskKey)
    }

    package func shouldStart(_ task: any ExecutableTask, buildCommand: BuildCommand) -> Bool {
        // Should always start if requested.
        return true
    }
}
