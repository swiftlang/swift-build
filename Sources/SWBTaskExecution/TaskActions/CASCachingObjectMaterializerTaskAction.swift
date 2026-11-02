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

/// Used only when remote caching is enabled for downloading a task output,
/// using its ID, into the local CAS.
public final class CASCachingObjectMaterializerTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        return "cas-caching-object-materializer"
    }

    private let key: CASCachingObjectMaterializerTaskKey

    package init(key: CASCachingObjectMaterializerTaskKey) {
        self.key = key
        super.init()
    }

    /// Network task so avoid blocking or being restricted by the execution lanes.
    override public var shouldExecuteDetached: Bool {
        return true
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
            let dataID = try cas.objectID(forPrintedID: key.casID)

            let obj: ToolchainCASObject?
            do {
                obj = try await cas.load(id: dataID)
            } catch {
                guard !key.casOptions.enableStrictCASErrors else { throw error }
                outputDelegate.warning(error.localizedDescription)
                obj = nil
            }
            if obj == nil {
                if key.casOptions.enableDiagnosticRemarks {
                    outputDelegate.note("missing CAS object: \(key.casID)")
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
