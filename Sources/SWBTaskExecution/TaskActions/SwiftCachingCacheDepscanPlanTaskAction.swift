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

public import SWBCore
import SWBCAS
import SWBUtil

import Foundation

final public class SwiftCachingCacheDepscanPlanTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        "swift-caching-cache-depscan-plan"
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        fatalError("Unexpectedly called the old version of isResultValid")
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue, fallback: (BuildValue) -> Bool) -> Bool {
        // Remote cache query tasks should always run when requested.
        return false
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        guard let payload = task.payload as? SwiftDriverPayload else {
            outputDelegate.emitError("Invalid payload for Swift caching cache depscan plan task")
            return .failed
        }
        guard let casOptions = payload.casOptions else {
            outputDelegate.emitError("Missing CAS options?")
            return .failed
        }
        let cas: ToolchainCAS
        do {
            try cas = dynamicExecutionDelegate.operationContext.getOrCreateCAS(options: casOptions.creationOpts)
        } catch {
            outputDelegate.emitError("failed initializing the CAS: \(error.localizedDescription)")
            return .failed
        }

        let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
        do {
            try await performAction(
                task,
                payload: payload,
                graph: graph,
                cas: cas,
                casOptions: casOptions,
                dynamicExecutionDelegate: dynamicExecutionDelegate,
                executionDelegate: executionDelegate,
                outputDelegate: outputDelegate,
            )
        } catch {
            outputDelegate.emitError(error.localizedDescription)
            return .failed
        }

        return .succeeded
    }

    private func performAction(
        _ task: any ExecutableTask,
        payload: SwiftDriverPayload,
        graph: SwiftModuleDependencyGraph,
        cas: ToolchainCAS,
        casOptions: CASOptions,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        outputDelegate: any TaskOutputDelegate,
    ) async throws {
        let plannedBuild = try graph.queryPlannedBuild(for: payload.uniqueID)
        let globalSignature = try payload.computeGlobalSignature(fs: executionDelegate.fs, workingDirectory: task.workingDirectory)
        let signatureID = try await cas.store(object: ToolchainCASObject(data: globalSignature, refs: []))
        let sz = MsgPackSerializer()
        try plannedBuild.serialize(to: sz)
        let planID = try await cas.store(object: ToolchainCASObject(data: sz.byteString, refs: []))
        if casOptions.enableDiagnosticRemarks {
            outputDelegate.note("serialized \(cas.printID(planID)) for key: \(cas.printID(signatureID))")
        }
        try await cas.cache(objectID: planID, forKeyID: signatureID)
        if casOptions.hasRemoteCache {
            dynamicExecutionDelegate.operationContext.compilationCachingUploader.upload(
                objectID: planID,
                forKeyID: signatureID,
                cas: cas,
                enableDiagnosticRemarks: casOptions.enableDiagnosticRemarks,
                enableStrictCASErrors: casOptions.enableStrictCASErrors,
                target: task.forTarget,
                activityReporter: dynamicExecutionDelegate,
            )
        }
    }
}
