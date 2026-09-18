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

public import SWBCore
import SWBLibc
import SWBUtil
import Foundation

final public class SwiftDriverCompilationRequirementTaskAction: SwiftDriverJobSchedulingTaskAction {
    public override class var toolIdentifier: String {
        "swift-driver-compilation-requirement"
    }

    public override func primaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        plannedBuild.compilationRequirementsPlannedDriverJobs()
    }

    public override func untrackedPrimaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        []
    }

    public override func secondaryJobs(for plannedBuild: LibSwiftDriver.PlannedBuild, driverPayload: SwiftDriverPayload) -> ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob> {
        if !driverPayload.eagerCompilationEnabled {
            return plannedBuild.afterCompilationPlannedDriverJobs()
        }
        return []
    }

    public override func shouldReportSkippedJobs(driverPayload: SwiftDriverPayload) -> Bool {
        !driverPayload.eagerCompilationEnabled
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        let result = await super.performTaskAction(task, dynamicExecutionDelegate: dynamicExecutionDelegate, executionDelegate: executionDelegate, clientDelegate: clientDelegate, outputDelegate: outputDelegate)
        if result == .succeeded {
            writeIndexExplicitModuleInfo(task, dynamicExecutionDelegate: dynamicExecutionDelegate, executionDelegate: executionDelegate, outputDelegate: outputDelegate)
        }
        return result
    }

    /// During index-build-arena preparation, persist the explicit-module inputs the scan just resolved so that
    /// background indexing can reuse the modules prep built instead of re-scanning and rebuilding them.
    ///
    /// Best effort: any failure leaves no sidecar, and indexing simply falls back to today's behavior.
    private func writeIndexExplicitModuleInfo(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, outputDelegate: any TaskOutputDelegate) {
        guard case .prepareForIndexing(_, let enableIndexBuildArena) = executionDelegate.buildCommand, enableIndexBuildArena else { return }
        guard let driverPayload = (task.payload as? SwiftTaskPayload)?.driverPayload, driverPayload.explicitModulesEnabled else { return }

        do {
            let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
            let plannedBuild = try graph.queryPlannedBuild(for: driverPayload.uniqueID)
            guard let job = plannedBuild.compilationRequirementsPlannedDriverJobs().first else { return }
            let commandLine = job.driverJob.commandLine.map { $0.asString }
            // Only record when the scan actually resolved an explicit module map, i.e. there is a handoff worth making.
            guard commandLine.contains("-explicit-swift-module-map-file") else { return }
            let info = IndexExplicitModuleInfo(uniqueID: driverPayload.uniqueID, resolvedArguments: commandLine)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let contents = try ByteString(encoder.encode(info))
            let path = driverPayload.indexExplicitModuleInfoPath
            try executionDelegate.fs.createDirectory(path.dirname, recursive: true)
            _ = try executionDelegate.fs.writeIfChanged(path, contents: contents)
        } catch {
            outputDelegate.warning("Unable to write explicit modules index info: \(error)")
        }
    }

    public override func copyForConcurrentExecution() -> TaskAction? {
        // Carries a per-execution scheduling state machine and no configuration, so a
        // fresh instance is equivalent and isolates concurrent engines from each other.
        SwiftDriverCompilationRequirementTaskAction()
    }
}
