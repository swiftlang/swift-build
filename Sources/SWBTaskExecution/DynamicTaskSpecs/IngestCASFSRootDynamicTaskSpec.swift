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

public struct IngestCASFSRootTaskKey: Serializable, CustomDebugStringConvertible {
    let payload: IngestCASFSRootTaskPayload
    let ingestion: SwiftCASFSIngestionInfo
    let moduleName: String

    init(payload: IngestCASFSRootTaskPayload, ingestion: SwiftCASFSIngestionInfo, moduleName: String) {
        self.payload = payload
        self.ingestion = ingestion
        self.moduleName = moduleName
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(payload)
            serializer.serialize(ingestion)
            serializer.serialize(moduleName)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.payload = try deserializer.deserialize()
        self.ingestion = try deserializer.deserialize()
        self.moduleName = try deserializer.deserialize()
    }

    public var debugDescription: String {
        "<IngestCASFSRoot output=\(ingestion.casFSRootPath.str)>"
    }
}

final class IngestCASFSRootDynamicTaskSpec: DynamicTaskSpec {
    var payloadType: (any TaskPayload.Type)? {
        IngestCASFSRootTaskPayload.self
    }

    func buildExecutableTask(dynamicTask: DynamicTask, context: DynamicTaskOperationContext) -> Task {
        guard case .ingestCASFSRoot(let key) = dynamicTask.taskKey else {
            fatalError("Unexpected dynamic task: \(dynamicTask)")
        }
        let casFSRootPath = key.ingestion.casFSRootPath
        return Task(type: self,
                    payload: key.payload,
                    forTarget: dynamicTask.target,
                    ruleInfo: ["IngestCASFSRoot", casFSRootPath.str],
                    commandLine: ["builtin-ingest-casfs-root", casFSRootPath.str, key.ingestion.jsonInput.str].map { .literal(ByteString(encodingAsUTF8: $0)) },
                    environment: dynamicTask.environment,
                    workingDirectory: dynamicTask.workingDirectory,
                    showEnvironment: dynamicTask.showEnvironment,
                    execDescription: "Ingest CASFS Root of \(key.moduleName)",
                    preparesForIndexing: true,
                    inputPaths: [key.ingestion.jsonInput],
                    outputPaths: [casFSRootPath],
                    priority: .unblocksDownstreamTasks,
                    isDynamic: true
                )
    }

    func buildTaskAction(dynamicTaskKey: DynamicTaskKey, context: DynamicTaskOperationContext) -> TaskAction {
        return IngestCASFSRootTaskAction()
    }
}
