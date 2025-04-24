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

package import Foundation
package import SWBCore
import SWBCAS
package import struct SWBProtocol.BuildOperationTaskStarted
package import struct SWBProtocol.BuildOperationTaskUpToDate
package import struct SWBProtocol.BuildOperationTaskEnded
package import SWBServiceCore
import SWBTaskConstruction
package import SWBTaskExecution
package import SWBUtil
package import struct SWBProtocol.TargetDescription
package import struct SWBProtocol.PreparedForIndexResultInfo
package import struct SWBProtocol.RunDestinationInfo
package import struct SWBProtocol.BuildOperationEnded
package import struct SWBProtocol.BuildOperationBacktraceFrameEmitted
package import enum SWBProtocol.BuildOperationTaskSignature
package import class Foundation.ProcessInfo
package import struct SWBProtocol.TargetDependencyRelationship
package import struct SWBProtocol.BuildOperationMetrics
private import SWBLLBuild
package import SWBMacro

/// Delegate protocol used to communicate build operation results and status.
package protocol BuildOperationDelegate {
    /// The proxy to use for file system access, if desired.
    ///
    /// If not provided, proxying will be completely disabled.
    var fs: (any FSProxy)? { get }

    /// Report the map of copied files in the build operation.
    func reportPathMap(_ operation: BuildOperation, copiedPathMap: [String: String], generatedFilesPathMap: [String: String])

    /// Called when the build has been started.
    ///
    /// This method is responsible for returning an output delegate that can be used to communicate status from the overall build (not associated with any individual task).
    func buildStarted(_ operation: any BuildSystemOperation) -> any BuildOutputDelegate

    /// Called when the build is complete.
    ///
    /// - Parameters:
    ///   - status: Overall build operation status to override the build result with. This can be used when the operation was aborted (the build could not run to completion, e.g. due to discovery of a cycle) or cancelled and wants to propagate that status regardless of the status of the individual build tasks in the underlying (llbuild) build system. `nil` will use the status based on the result status of the tasks in the underlying llbuild build system.
    ///   - delegate: The task output delegate provided by the \see buildStarted() method.
    @discardableResult func buildComplete(_ operation: any BuildSystemOperation, status: BuildOperationEnded.Status?, delegate: any BuildOutputDelegate, metrics: BuildOperationMetrics?) -> BuildOperationEnded.Status

    /// Called when an individual task has been started.
    ///
    /// This method is responsible for returning an output delegate that can be used to communicate further task status.
    //
    // FIXME: Should document requirements w.r.t. threading exposure of the delegate.
    func taskStarted(_ operation: any BuildSystemOperation, taskIdentifier: TaskIdentifier, task: any ExecutableTask, dependencyInfo: CommandLineDependencyInfo?) -> any TaskOutputDelegate

    /// Called when a task requested dynamic tasks via the `DynamicTaskExecutionDelegate` API.
    func taskRequestedDynamicTask(_ operation: any BuildSystemOperation, requestingTask: any ExecutableTask, dynamicTaskIdentifier: TaskIdentifier)

    /// Called when a dynamic task is registered via the `DynamicTaskExecutionDelegate` API.
    func registeredDynamicTask(_ operation: any BuildSystemOperation, task: any ExecutableTask, dynamicTaskIdentifier: TaskIdentifier)

    /// Called when an individual task has been determined to be up-to-date.
    func taskUpToDate(_ operation: any BuildSystemOperation, taskIdentifier: TaskIdentifier, task: any ExecutableTask)

    /// Called when an subtask previously batched with other tasks has been determined to be up-to-date.
    func previouslyBatchedSubtaskUpToDate(_ operation: any BuildSystemOperation, signature: ByteString, target: ConfiguredTarget)

    /// Called when the command progress has changed.
    func totalCommandProgressChanged(_ operation: BuildOperation, forTargetName targetName: String?, statistics: BuildOperation.ProgressStatistics)

    /// Called when an individual task has been completed.
    ///
    /// - Parameters:
    ///   - delegate: The task output delegate provided by the \see taskStarted() method.
    func taskComplete(_ operation: any BuildSystemOperation, taskIdentifier: TaskIdentifier, task: any ExecutableTask, delegate: any TaskOutputDelegate)

    /// Sends a started event for the specified activity.
    ///
    /// Must be paired with a corresponding `endActivity` call.
    func beginActivity(_ operation: any BuildSystemOperation, ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID

    /// Sends an ended event for the specified activity.
    ///
    /// Must be paired with a corresponding `beginActivity` call.
    func endActivity(_ operation: any BuildSystemOperation, id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status)

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString)
    func emit(diagnostic: SWBUtil.Diagnostic, for activity: ActivityID, signature: ByteString)

    var hadErrors: Bool { get }

    /// Called when the tasks for a target start being prepared.
    func targetPreparationStarted(_ operation: any BuildSystemOperation, configuredTarget: ConfiguredTarget)

    /// Called when the tasks for a target are starting to run.  If no task for this target is actually run in this build, then this will never be called.
    func targetStarted(_ operation: any BuildSystemOperation, configuredTarget: ConfiguredTarget)

    /// Called when the tasks for a target are complete.
    func targetComplete(_ operation: any BuildSystemOperation, configuredTarget: ConfiguredTarget)

    /// Called when a target has been "prepared-for-index", passing along the results info.
    func targetPreparedForIndex(_ operation: any BuildSystemOperation, target: Target, info: PreparedForIndexResultInfo)

    /// Update the progress of an ongoing build operation
    func updateBuildProgress(statusMessage: String, showInLog: Bool)

    func recordBuildBacktraceFrame(identifier: SWBProtocol.BuildOperationBacktraceFrameEmitted.Identifier, previousFrameIdentifier: BuildOperationBacktraceFrameEmitted.Identifier?, category: BuildOperationBacktraceFrameEmitted.Category, kind: BuildOperationBacktraceFrameEmitted.Kind, description: String)

    var aggregatedCounters: [BuildOperationMetrics.Counter: Int] { get }
    var aggregatedTaskCounters: [String: [BuildOperationMetrics.TaskCounter: Int]] { get }
}

package struct CommandLineDependencyInfo {
    package let inputDependencyPaths: [Path]
    package let executionInputIdentifiers: [String]
    package let outputDependencyPaths: [Path]

    package init(task: any ExecutableTask) {
        self.inputDependencyPaths = task.inputPaths
        self.executionInputIdentifiers = task.executionInputs?.map { $0.identifier } ?? []
        self.outputDependencyPaths = task.outputPaths
    }
}

package protocol BuildSystemOperation: AnyObject, Sendable {
    var cachedBuildSystems: any BuildSystemCache { get }
    var request: BuildRequest { get }
    var requestContext: BuildRequestContext { get }
    var subtaskProgressReporter: (any SubtaskProgressReporter)? { get }
    var uuid: UUID { get }

    @discardableResult func build() async -> BuildOperationEnded.Status
    func cancel()
    func abort()
}

package extension BuildSystemOperation {
    func showConnectionModeMessage(_ connectionMode: ServiceHostConnectionMode, _ buildOutputDelegate: any BuildOutputDelegate) {
        switch connectionMode {
        case .inProcess:
            buildOutputDelegate.note("Using build service in-process")
        case .outOfProcess:
            buildOutputDelegate.note("Using build service at: \(CommandLine.arguments[0]) (PID \(ProcessInfo.processInfo.processIdentifier))" + (getEnvironmentVariable("DYLD_IMAGE_SUFFIX").map { ", DYLD_IMAGE_SUFFIX=\($0) is being inherited" } ?? ""))
        }
    }
}

/// An in-flight build operation created in response to a build request.
package final class BuildOperation: BuildSystemOperation {
    /// Statistics on an executing operation.
    ///
    /// These statistics do not necessarily include all low-level commands.
    package struct ProgressStatistics {
        /// A conservative estimate for the number of commands which will be scanned by the build.
        ///
        /// The actual number of tasks is guaranteed to be greater than this number.
        package let numCommandsLowerBound: Int

        /// The total number of commands which have been scanned.
        package var numCommandsScanned: Int = 0

        /// The number of commands which have been started.
        package var numCommandsStarted: Int = 0

        /// The number of commands which have completed scanning (are up-to-date or were executed).
        package var numCommandsCompleted: Int = 0

        /// The number of commands which are currently being scanned but have not completed.
        package var numCommandsActivelyScanning: Int = 0

        /// The number of commands which were up-to-date (and did not need to execute).
        package var numCommandsUpToDate: Int = 0

        package init(numCommandsLowerBound: Int) {
            self.numCommandsLowerBound = numCommandsLowerBound
        }

        /// Compute the "possible" number of maximum commands that could be run.
        ///
        /// This is only the "possible" max because we can start running commands before dependency scanning is complete -- we include the number of commands that are being scanned so that this number will always be greater than the number of commands that have been executed until the very last command is run, but it could be less than the actual maximum because there is always the potential to discover more work to scan.
        package var numPossibleMaxExecutedCommands: Int {
            // The current total number of max commands is the number of commands which have completed, plus the number that are scanning (and could run).
            let totalPossibleMaxCommands = numCommandsCompleted + numCommandsActivelyScanning

            // The number of max commands to show is that total, minus the commands which have were up-to-date.
            return totalPossibleMaxCommands - numCommandsUpToDate
        }

        mutating func reset() {
            self = .init(numCommandsLowerBound: numCommandsLowerBound)
        }
    }

    /// A unique identifier that can remain unique even when persisted over time.  This is used, for example, to identify logs from different build operations.
    package let uuid: UUID

    /// The original build request.
    package let request: BuildRequest

    package let requestContext: BuildRequestContext

    /// The build description.
    package let buildDescription: BuildDescription

    /// The environment to operate with.
    package let environment: [String: String]?

    /// The operation delegate.
    package let delegate: any BuildOperationDelegate

    /// Whether the build results should be persisted (for incremental builds).
    package let persistent: Bool

    /// Whether the build should force serial execution.
    package let serial: Bool

    /// Queue used to protect shared state (like cancellation flag).
    private let queue: SWBQueue

    /// A delegate to allow tasks to communicate with the client during their execution.
    package let clientDelegate: any ClientDelegate

    /// An output delegate that can be used to communicate status from the overall build
    private var buildOutputDelegate: (any BuildOutputDelegate)!

    /// The underlying LLBuild build system
    private var system: BuildSystem?

    /// The progress reporter for subtasks.
    ///
    /// This is only present during an active build.
    package weak var subtaskProgressReporter: (any SubtaskProgressReporter)?

    /// Cancellation state
    private var wasCancellationRequested = false
    private var wasAbortRequested = false

    /// Optional map of a subset of files to build and their desired output paths
    private let buildOutputMap: [String:String]?

    /// Optional list of a subset of nodes to build
    private let nodesToBuild: [BuildDescription.BuildNodeToPrepareForIndex]?

    /// `true` if this build operation may request the build of more than one node sequentially.
    var mayBuildMultipleNodes: Bool {
        buildOutputMap != nil || nodesToBuild != nil
    }

    /// The workspace being built
    package let workspace: SWBCore.Workspace

    /// Core
    let core: Core

    /// User preferences from the client
    package let userPreferences: UserPreferences

    package let cachedBuildSystems: any BuildSystemCache

    package init(_ request: BuildRequest, _ requestContext: BuildRequestContext, _ buildDescription: BuildDescription, environment: [String: String]? = nil, _ delegate: any BuildOperationDelegate, _ clientDelegate: any ClientDelegate, _ cachedBuildSystems: any BuildSystemCache, persistent: Bool = false, serial: Bool = false, buildOutputMap: [String:String]? = nil, nodesToBuild: [BuildDescription.BuildNodeToPrepareForIndex]? = nil, workspace: SWBCore.Workspace, core: Core, userPreferences: UserPreferences) {
        self.uuid = UUID()
        self.request = request
        self.requestContext = requestContext
        self.environment = environment
        self.buildDescription = buildDescription
        self.delegate = delegate
        self.clientDelegate = clientDelegate
        self.persistent = persistent
        self.serial = serial
        self.buildOutputMap = buildOutputMap
        self.nodesToBuild = nodesToBuild
        self.workspace = workspace
        self.core = core
        self.userPreferences = userPreferences
        self.queue = SWBQueue(label: "SWBBuildSystem.BuildOperation.queue", qos: request.qos, autoreleaseFrequency: .workItem)
        self.cachedBuildSystems = cachedBuildSystems
    }

    /// Perform the build.
    package func build() async -> BuildOperationEnded.Status {
        // Inform the client the build has started.
        buildOutputDelegate = delegate.buildStarted(self)

        // Report the copied path map.
        delegate.reportPathMap(self, copiedPathMap: buildDescription.copiedPathMap, generatedFilesPathMap: buildOutputMap ?? [String:String]())

        // Report the diagnostics from task construction.
        //
        // We report these on every build.
        for (target, diagnostics) in buildDescription.diagnostics {
            let context: TargetDiagnosticContext = target.map { .overrideTarget($0) } ?? .global
            for diagnostic in diagnostics {
                buildOutputDelegate.emit(context, diagnostic)
            }
        }

        // Diagnose attempts to use "dry run" mode, which we don't support yet.
        if request.useDryRun {
            buildOutputDelegate.error("-dry-run is not yet supported in the new build system")
            let effectiveStatus = BuildOperationEnded.Status.failed
            delegate.buildComplete(self, status: effectiveStatus, delegate: buildOutputDelegate, metrics: nil)
            return effectiveStatus
        }

        // Helper method to emit information to the CAPTURED_BUILD_INFO_DIR.  This is mainly to be able to gracefully return after emitting a warning if something goes wrong, because not being able to emit this info is typically not serious enough to want to abort the whole build.
        func emitCapturedBuildInfo(to path: Path) {
            // If the build description doesn't have captured build info, then we don't emit it.  Otherwise we proceed.
            guard let capturedBuildInfo = buildDescription.capturedBuildInfo else {
                buildOutputDelegate.warning("no captured build info available for incremental build - not emitting it")
                return
            }

            guard path.isAbsolute else {
                buildOutputDelegate.warning("CAPTURED_BUILD_INFO_DIR must be an absolute path, but is \(path.str) (skipping emitting captured build info)")
                return
            }

            // Create the directory if necessary.
            if !fs.exists(path) {
                do {
                    try fs.createDirectory(path, recursive: true)
                }
                catch {
                    buildOutputDelegate.warning("Could not create directory for CAPTURED_BUILD_INFO_DIR (\(path.str)): \(error) (skipping emitting captured build info)")
                    return
                }
            }
            else {
                guard fs.isDirectory(path) else {
                    buildOutputDelegate.warning("CAPTURED_BUILD_INFO_DIR (\(path.str)) exists but is not a directory (skipping emitting captured build info)")
                    return
                }
            }

            // The output path includes our process ID, since there might be multiple builds dumping information here, e.g. if there's a script which invokes another xcodebuild instance.
            let pid = ProcessInfo.processInfo.processIdentifier
            let outputFilePath = path.join("xcodebuildCapturedInfo_\(pid).\(capturedBuildInfoFileExtension)")

            // Write the captured build info to the file.
            do {
                try fs.write(outputFilePath, contents: capturedBuildInfo.propertyListItem.asJSONFragment() + "\n")
            }
            catch {
                buildOutputDelegate.warning("Could not write captured build info to '\(outputFilePath.str)': \(error)")
                return
            }

            buildOutputDelegate.note("Wrote captured build info to \(outputFilePath.str)")
        }

        // If we were asked to emit information about the targets being built, then do so now, unless we're in "dry run" mode.
        if !request.useDryRun, let capturedBuildInfoDir = environment?["CAPTURED_BUILD_INFO_DIR"] {
            if !capturedBuildInfoDir.isEmpty {
                // If the resolved path is not empty, then emit the captured build info.
                emitCapturedBuildInfo(to: Path(capturedBuildInfoDir))
            } else {
                buildOutputDelegate.warning("CAPTURED_BUILD_INFO_DIR is set but is empty (skipping emitting captured build info)")
            }
        }

        // If task construction had errors, fail the build immediately, unless `continueBuildingAfterErrors` is set.
        if !request.continueBuildingAfterErrors && buildDescription.hadErrors {
            let effectiveStatus = BuildOperationEnded.Status.failed
            delegate.buildComplete(self, status: effectiveStatus, delegate: buildOutputDelegate, metrics: nil)
            return effectiveStatus
        }

        if userPreferences.enableDebugActivityLogs {
            showConnectionModeMessage(core.connectionMode, buildOutputDelegate)

            for path in await core.loadedPluginPaths {
                buildOutputDelegate.note("SWBBuildService loaded plugin at \(path.str)")
            }

            buildOutputDelegate.emit(Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("File system mode: \(fs.fileSystemMode.manifestLabel)")))

            enum OverrideSource {
                case table([String: String])
                case file(Path)
            }

            func emitRequestParametersOverrides(_ infix: String, _ overrides: OverrideSource?) {
                switch overrides {
                case let .table(overrides):
                    if !overrides.isEmpty {
                        buildOutputDelegate.emit(Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Applying \(infix) build settings"), childDiagnostics: overrides.sorted(by: \.0).map { (key, value) in
                            Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("\(key)=\(value)"))
                        }))
                    }
                case let .file(path):
                    buildOutputDelegate.emit(Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Applying \(infix) build settings from path: \(path.str)")))
                case nil:
                    break
                }
            }

            emitRequestParametersOverrides("overriding", .table(request.parameters.overrides))
            emitRequestParametersOverrides("command line", .table(request.parameters.commandLineOverrides))
            emitRequestParametersOverrides("command line config", request.parameters.commandLineConfigOverridesPath.map { .file($0) })
            emitRequestParametersOverrides("environment config", request.parameters.environmentConfigOverridesPath.map { .file($0) })
        }

        // If the build has been cancelled before it really began, we can bail out early
        do {
            let isCancelled = await queue.sync{ self.wasCancellationRequested }
            if !UserDefaults.skipEarlyBuildOperationCancellation && isCancelled {
                let effectiveStatus = BuildOperationEnded.Status.cancelled
                delegate.buildComplete(self, status: effectiveStatus, delegate: buildOutputDelegate, metrics: nil)
                return effectiveStatus
            }
        }

        // Perform any needed steps before we kick off the build.
        if let (warnings, errors) = prepareForBuilding() {
            // Emit any warnings and errors.  If there were any errors, then bail out.
            for message in warnings { buildOutputDelegate.warning(message) }
            for message in errors { buildOutputDelegate.error(message) }
            guard errors.isEmpty else {
                let effectiveStatus = BuildOperationEnded.Status.failed
                delegate.buildComplete(self, status: effectiveStatus, delegate: buildOutputDelegate, metrics: nil)
                return effectiveStatus
            }
        }

        let dbPath = persistent ? buildDescription.buildDatabasePath : Path("")

        // Enable build debugging, if requested.
        let traceFile: Path?
        let debuggingDataPath: Path?

        if userPreferences.enableBuildDebugging {
            // Create a timestamp to represent this build.
            let now = Date()
            let signature = "\(now.timeIntervalSince1970)"

            // Create a directory to hold the artifacts.
            debuggingDataPath = buildDescription.dir.join("buildDebugging-\(signature)")

            traceFile = buildDescription.dir.join("build.trace")
            traceFile.map { traceFile in
                // If the trace file is present, copy it aside for post-mortem analysis.
                if fs.exists(traceFile) {
                    saveBuildDebuggingData(from: traceFile, to: "prior-build.trace", type: "prior trace", debuggingDataPath: debuggingDataPath)
                }
            }

            // If the build database is present, copy it aside for post-mortem analysis.
            if fs.exists(dbPath) {
                saveBuildDebuggingData(from: dbPath, to: "prior-build.db", type: "prior database", debuggingDataPath: debuggingDataPath)
            }

            // Save the current manifest and description for post-mortem analysis.
            saveBuildDebuggingData(from: buildDescription.packagePath, to: "current-manifest.swiftbuilddata", type: "swiftbuilddata", debuggingDataPath: debuggingDataPath)
        } else {
            traceFile = nil
            debuggingDataPath = nil
        }

        var buildEnvironment: [String:String] = [:]

        if let actualEnvironment = environment {
            buildEnvironment.addContents(of: actualEnvironment)
        }

        do {
            try await buildEnvironment.addContents(of: BuildOperationExtensionPoint.additionalEnvironmentVariables(pluginManager: core.pluginManager, fromEnvironment: buildEnvironment, parameters: request.parameters))
        } catch {
            self.buildOutputDelegate.error("unable to retrieve additional environment variables via the BuildOperationExtensionPoint.")
        }

        struct Context: EnvironmentExtensionAdditionalEnvironmentVariablesContext {
            var hostOperatingSystem: OperatingSystem
            var fs: any FSProxy
        }

        do {
            try await buildEnvironment.addContents(of: EnvironmentExtensionPoint.additionalEnvironmentVariables(pluginManager: core.pluginManager, context: Context(hostOperatingSystem: core.hostOperatingSystem, fs: fs)))
        } catch {
            self.buildOutputDelegate.error("unable to retrieve additional environment variables via the EnvironmentExtensionPoint.")
        }

        // If we use a cached build system, be sure to release it on build completion.
        if userPreferences.enableBuildSystemCaching {
            // Get the build system to use, keyed by the directory containing the (sole) database.
            let entry = cachedBuildSystems.getOrInsert(buildDescription.buildDatabasePath.dirname, { SystemCacheEntry() })
            return await entry.lock.withLock { [buildEnvironment] _ in
                await _build(cacheEntry: entry, dbPath: dbPath, traceFile: traceFile, debuggingDataPath: debuggingDataPath, buildEnvironment: buildEnvironment)
            }
        } else {
            return await _build(cacheEntry: nil, dbPath: dbPath, traceFile: traceFile, debuggingDataPath: debuggingDataPath, buildEnvironment: buildEnvironment)
        }
    }

    private func saveBuildDebuggingData(from sourcePath: Path, to filename: String, type: String, debuggingDataPath: Path?) {
        guard let debuggingDataPath else {
            return
        }
        do {
            try fs.createDirectory(debuggingDataPath, recursive: true)
            let savedPath = debuggingDataPath.join(filename)
            try fs.copy(sourcePath, to: savedPath)
            self.buildOutputDelegate.note("build debugging is enabled, \(type): '\(savedPath.str)'")
        } catch {
            self.buildOutputDelegate.warning("unable to preserve \(type) for post-mortem debugging: \(error)")
        }
    }

    private func _build(cacheEntry entry: SystemCacheEntry?, dbPath: Path, traceFile: Path?, debuggingDataPath: Path?, buildEnvironment: [String: String]) async -> BuildOperationEnded.Status {
        let algorithm: BuildSystem.SchedulerAlgorithm = {
            if let algorithmString = UserDefaults.schedulerAlgorithm {
                if let algorithm = BuildSystem.SchedulerAlgorithm(rawValue: algorithmString) {
                    return algorithm
                } else {
                    self.buildOutputDelegate.warning("unsupported value for SchedulerAlgorithm user default: '\(algorithmString)'")
                }
            }
            return .commandNamePriority
        }()

        let laneWidth = UserDefaults.schedulerLaneWidth ?? 0

        // Create the low-level build system.
        let adaptor: OperationSystemAdaptor
        let system: BuildSystem
        
        let llbQoS: SWBLLBuild.BuildSystem.QualityOfService?
        switch request.qos {
        case .default: llbQoS = .default
        case .userInitiated: llbQoS = .userInitiated
        case .utility: llbQoS = .utility
        case .background: llbQoS = .background
        default: llbQoS = nil
        }

        if let entry {
            // If the entry is valid, reuse it.
            if let cachedAdaptor = entry.adaptor, entry.environment == buildEnvironment, entry.buildDescription! === buildDescription, entry.llbQoS == llbQoS {
                adaptor = cachedAdaptor
                await adaptor.reset(operation: self, buildOutputDelegate: buildOutputDelegate)
            } else {
                adaptor = OperationSystemAdaptor(operation: self, buildOutputDelegate: buildOutputDelegate, core: core)
                entry.environment = buildEnvironment
                entry.adaptor = adaptor
                entry.buildDescription = buildDescription
                entry.llbQoS = llbQoS
                entry.fileSystemMode = fs.fileSystemMode
                entry.system = SWBLLBuild.BuildSystem(buildFile: buildDescription.manifestPath.str, databaseFile: dbPath.str, delegate: adaptor, environment: buildEnvironment, serial: serial, traceFile: traceFile?.str, schedulerAlgorithm: algorithm, schedulerLanes: laneWidth, qos: llbQoS)
            }
            system = entry.system!
        } else {
            // Dispatch the build, using llbuild.
            //
            // FIXME: Eventually, we want this to be structured so that we can share the loaded build engine across multiple in process build invocations. We probably would want the low-level build system to be cached at the BuildManager level, I'm guessing.
            adaptor = OperationSystemAdaptor(operation: self, buildOutputDelegate: buildOutputDelegate, core: core)
            await queue.sync {
                if let system = self.system {
                    assertionFailure("A previous build is still running: \(system)")
                }
            }
            system = SWBLLBuild.BuildSystem(buildFile: buildDescription.manifestPath.str, databaseFile: dbPath.str, delegate: adaptor, environment: buildEnvironment, serial: serial, traceFile: traceFile?.str, schedulerAlgorithm: algorithm, schedulerLanes: laneWidth, qos: llbQoS)
        }

        // FIXME: This API is not thread safe, and we can't fix the concurrency issues outside of llbuild itself.
        // Take advantage of the fact that the default is false, and only call the API if we want to turn it on
        // if it isn't already on... this way we'll never have concurrent readers and writers of the flag if we
        // have not requested to enable tracing. <rdar://58495189>
        if UserDefaults.enableTracing {
            BuildSystem.setTracing(enabled: true)
        }

        // Dispatch the build.
        let result: Bool
        do {
            let isCancelled: Bool = await queue.sync {
                self.system = system
                self.subtaskProgressReporter = adaptor
                return self.wasCancellationRequested
            }
            // FIXME: There is a race here, we might install the system after we receive the cancellation, but before the low-level build starts.
            if isCancelled {
                result = false
            } else {
                if let buildOnlyTheseOutputs = buildOutputMap?.keys {
                    // Build selected outputs, the build fails if one operation failed.
                    result = await _Concurrency.Task.detachNewThread(name: "llb_buildsystem_build_node") {
                        !buildOnlyTheseOutputs.map({ return system.build(node: Path($0).strWithPosixSlashes) }).contains(false)
                    }
                } else if let buildOnlyTheseNodes = nodesToBuild {
                    // Build selected nodes, the build fails if one operation failed.
                    var currResult = true
                    for nodeToPrepare in buildOnlyTheseNodes {
                        let isCancelled = await queue.sync{ self.wasCancellationRequested }
                        if isCancelled {
                            currResult = false
                            break
                        }
                        let success = await _Concurrency.Task.detachNewThread(name: "llb_buildsystem_build_node") { system.build(node: nodeToPrepare.nodeName) }

                        // Pass the modification time of the 'prepare-for-index' marker file to the client.
                        // The client can use this info to determine whether it needs to update its state or not.
                        // We do this even when `success == false`, the client can decide what to do with the info when the operation returns 'fail' as result.
                        do {
                            let modTime = try fs.getFileInfo(Path(nodeToPrepare.nodeName)).modificationDate
                            // Report to the client the timestamp of the 'preparation' operation for the target it requested.
                            // From the client's perspective it's not relevant how many configured targets were build as part of this operation, so it's ok to "drop" the context of the configured target for the callback.
                            self.delegate.targetPreparedForIndex(self, target: nodeToPrepare.target.target, info: PreparedForIndexResultInfo(timestamp: modTime))
                        } catch {
                            self.buildOutputDelegate.warning("unable to get timestamp for '\(nodeToPrepare.nodeName)': \(error)")
                        }

                        if !success && !request.continueBuildingAfterErrors {
                            currResult = false
                            break
                        }
                        currResult = currResult && success
                    }
                    result = currResult
                } else {
                    result = await _Concurrency.Task.detachNewThread(name: "llb_buildsystem_build") { system.build() }
                }
            }
        }

        let (wasCancelled, wasAborted) = await queue.sync { (self.wasCancellationRequested, self.wasAbortRequested) }

        let wasSuccessful = result && !(wasCancelled || wasAborted)

        if self.request.generatePrecompiledModulesReport {
            if !adaptor.dynamicOperationContext.clangModuleDependencyGraph.isEmpty {
                let clangReportPath = buildDescription.packagePath.dirname.join("clangmodulesreport")
                try? fs.createDirectory(clangReportPath)
                await adaptor.withActivity(ruleInfo: "GenerateClangModulesReport", executionDescription: "Generate Clang modules report", signature: "generate_clang_modules_report", target: nil, parentActivity: nil) { activity in
                    do {
                        let summary = try await adaptor.dynamicOperationContext.clangModuleDependencyGraph.generatePrecompiledModulesReport(in: clangReportPath, fs: fs)
                        adaptor.emit(data: ByteString(encodingAsUTF8: summary).bytes, for: activity, signature: "generate_clang_modules_report")
                    } catch {
                        return .failed
                    }
                    return .succeeded
                }
            }
            if !adaptor.dynamicOperationContext.swiftModuleDependencyGraph.isEmpty {
                let swiftReportPath = buildDescription.packagePath.dirname.join("swiftmodulesreport")
                try? fs.createDirectory(swiftReportPath)
                await adaptor.withActivity(ruleInfo: "GenerateSwiftModulesReport", executionDescription: "Generate Swift modules report", signature: "generate_swift_modules_report", target: nil, parentActivity: nil) { activity in

                    do {
                        let summary = try await adaptor.dynamicOperationContext.swiftModuleDependencyGraph.generatePrecompiledModulesReport(in: swiftReportPath, fs: fs)
                        adaptor.emit(data: ByteString(encodingAsUTF8: summary).bytes, for: activity, signature: "generate_swift_modules_report")
                    } catch {
                        return .failed
                    }
                    return .succeeded
                }
            }
        }

        let aggregatedCounters = await adaptor.getAggregatedCounters()
        let aggregatedTaskCounters = await adaptor.getAggregatedTaskCounters()
        do {
            let cacheHits: Int
            let cacheMisses: Int
            do {
                let swiftCacheHits = aggregatedCounters[.swiftCacheHits, default: 0]
                let swiftCacheMisses = aggregatedCounters[.swiftCacheMisses, default: 0]
                let clangCacheHits = aggregatedCounters[.clangCacheHits, default: 0]
                let clangCacheMisses = aggregatedCounters[.clangCacheMisses, default: 0]
                cacheHits = swiftCacheHits + clangCacheHits
                cacheMisses = swiftCacheMisses + clangCacheMisses
            }
            if cacheHits + cacheMisses > 0 {
                let signature = ByteString(encodingAsUTF8: "compilation_cache_metrics")
                adaptor.withActivity(ruleInfo: "CompilationCacheMetrics", executionDescription: "Report compilation cache metrics", signature: signature, target: nil, parentActivity: nil) { activity in
                    func getSummary(hits: Int, misses: Int) -> String {
                        let hitPercent = Int((Double(hits) / Double(hits + misses) * 100).rounded())
                        return "\(hits) hit\(hits == 1 ? "" : "s") (\(hitPercent)%), \(misses) miss\(misses == 1 ? "" : "es")"
                    }
                    delegate.emit(diagnostic: Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData(getSummary(hits: cacheHits, misses: cacheMisses))), for: activity, signature: signature)
                    return .succeeded
                }

            }
        }

        if SWBFeatureFlag.enableCacheMetricsLogs.value {
            adaptor.withActivity(ruleInfo: "RawCacheMetrics", executionDescription: "Report raw cache metrics", signature: "raw_cache_metrics", target: nil, parentActivity: nil) { activity in
                struct AllCounters: Encodable {
                    var global: [String: Double] = [:]
                    var tasks: [String: [String: Double]] = [:]
                }
                var serializedCounters = AllCounters()
                for (key, value) in aggregatedCounters {
                    serializedCounters.global[key.rawValue] = Double(value)
                }
                for (taskId, taskCounters) in aggregatedTaskCounters {
                    var serialTaskCounters: [String: Double] = [:]
                    for (counterKey, counterValue) in taskCounters {
                        serialTaskCounters[counterKey.rawValue] = Double(counterValue)
                    }
                    serializedCounters.tasks[taskId] = serialTaskCounters
                }
                delegate.emit(data: ByteString(encodingAsUTF8: "\(serializedCounters)").bytes, for: activity, signature: "raw_cache_metrics")
                return .succeeded
            }
        }

        // Ensure the adaptor is complete before notifying of build termination.
        // FIXME: <rdar://58766295> We need to get more metrics when the build wasCancelled and llbuild returned a
        // success value.
        await adaptor.waitForCompletion(buildSucceeded: wasSuccessful)

        // If we were tracing, also copy the trace file and final build database to the debugging directory.
        if let traceFile {
            if fs.exists(traceFile) {
                saveBuildDebuggingData(from: traceFile, to: "completed-build.trace", type: "completed trace", debuggingDataPath: debuggingDataPath)
            }

            let dbPath = buildDescription.buildDatabasePath
            if fs.exists(dbPath) {
                saveBuildDebuggingData(from: dbPath, to: "completed-build.db", type: "completed database", debuggingDataPath: debuggingDataPath)
            }
        }

        if let metricsPath: String = buildEnvironment["SWIFTBUILD_METRICS_PATH"]?.nilIfEmpty ?? buildEnvironment["XCBUILD_METRICS_PATH"]?.nilIfEmpty {
            do {
                struct AllCounters: Encodable {
                    var global: [String: Double] = [:]
                    var tasks: [String: [String: Double]] = [:]
                }
                var serializedCounters = AllCounters()
                for (key, value) in aggregatedCounters {
                    serializedCounters.global[key.rawValue] = Double(value)
                }
                for (taskId, taskCounters) in aggregatedTaskCounters {
                    var serialTaskCounters: [String: Double] = [:]
                    for (counterKey, counterValue) in taskCounters {
                        serialTaskCounters[counterKey.rawValue] = Double(counterValue)
                    }
                    serializedCounters.tasks[taskId] = serialTaskCounters
                }
                try fs.append(
                    Path(metricsPath),
                    contents: ByteString(
                        JSONEncoder(outputFormatting: .sortedKeys).encode(serializedCounters)
                    )
                )
            } catch {
                self.buildOutputDelegate.warning("unable to write metrics.json: \(error)")
            }
        }

        #if canImport(Darwin)
        do {
            if let xcbuildDataArchive = getEnvironmentVariable("XCBUILDDATA_ARCHIVE")?.nilIfEmpty.map(Path.init) {
                let archive = XCBuildDataArchive(filePath: xcbuildDataArchive)
                try archive.appendBuildDataDirectory(from: buildDescription.dir, uuid: uuid)
            }
        } catch {
            self.buildOutputDelegate.error("unable to process build ended event via the BuildOperationExtensionPoint: \(error)")
        }
        #endif

        if let swiftBuildTraceFilePath = getEnvironmentVariable("SWIFTBUILD_TRACE_FILE")?.nilIfEmpty.map(Path.init) ?? getEnvironmentVariable("XCBUILDDATA_ARCHIVE")?.nilIfEmpty.map(Path.init)?.dirname.join(".SWIFTBUILD_TRACE") {
            struct SwiftDataTraceEntry: Codable {
                let buildDescriptionSignature: String
                let isTargetParallelizationEnabled: Bool
                let name: String
                let path: String
            }
            do {
                let traceEntry  = SwiftDataTraceEntry(
                    buildDescriptionSignature: buildDescription.signature.asString,
                    isTargetParallelizationEnabled: request.useParallelTargets,
                    name: workspace.name,
                    path: workspace.path.str
                )
                let encoder = JSONEncoder(outputFormatting: .sortedKeys)
                try fs.append(swiftBuildTraceFilePath, contents: ByteString(encoder.encode(traceEntry)) + "\n")
            } catch {
                self.buildOutputDelegate.error("failed to write trace file at \(swiftBuildTraceFilePath.str): \(error)")
            }
        }

        let (isCancelled, isAborted): (Bool, Bool) = await queue.sync {
            self.system = nil
            return (self.wasCancellationRequested, self.wasAbortRequested)
        }

        let effectiveStatus: BuildOperationEnded.Status?
        switch (isCancelled, isAborted) {
        case (true, false), (true, true):
            effectiveStatus = .cancelled // cancelled always wins over aborted
        case (false, true):
            effectiveStatus = .failed
        case (false, false):
            effectiveStatus = nil
        }

        // `buildComplete()` should not run within `queue`, otherwise there can be a deadlock during cancelling.
        return delegate.buildComplete(self, status: effectiveStatus, delegate: buildOutputDelegate, metrics: .init(counters: aggregatedCounters))
    }

    func prepareForBuilding() -> ([String], [String])? {
        let warnings = [String]()       // Not presently used
        var errors = [String]()

        // Create the module session file if necessary.
        if let moduleSessionFilePath = buildDescription.moduleSessionFilePath {
            let now = Date()
            let fileContents = ByteString(encodingAsUTF8: "\(now.timeIntervalSince1970): Module build session file for module cache at \(moduleSessionFilePath.dirname)\n")
            do {
                try fs.createDirectory(moduleSessionFilePath.dirname, recursive: true)
                try fs.write(moduleSessionFilePath, contents: fileContents)
            }
            catch let err as SWBUtil.POSIXError {
                errors.append("unable to write module session file at '\(moduleSessionFilePath.str)': \(err.description)")
            }
            catch {
                errors.append("unable to write module session file at '\(moduleSessionFilePath.str)': unknown error")
            }
        }

        return (warnings.count > 0 || errors.count > 0) ? (warnings, errors) : nil
    }

    /// Cancel the executing build operation.
    package func cancel() {
        queue.blocking_sync() {
            wasCancellationRequested = true

            system?.cancel()
        }
    }

    /// Aborts the executing build operation.
    ///
    /// This is used to cancel the underlying (llbuild) build operation when "continue building after errors" is turned off.
    package func abort() {
        queue.blocking_sync {
            wasAbortRequested = true

            system?.cancel()
        }
    }

    private let dependenciesByDependentTargetGUID = LazyCache<[TargetDependencyRelationship], [String: Set<TargetDescription>]> {
        var result: [String: Set<TargetDescription>] = [:]
        for edge in $0 {
            result[edge.target.guid, default: []].formUnion(edge.targetDependencies)
        }
        return result
    }

    private let cachedDependencyQueries = Registry<Pair<String, String>, Bool>()

    private func transitiveDependencyExists(target: ConfiguredTarget, antecedent: ConfiguredTarget) -> Bool {
        cachedDependencyQueries.getOrInsert(.init(target.guid.stringValue, antecedent.guid.stringValue)) {
            let graph = dependenciesByDependentTargetGUID.getValue(buildDescription.targetDependencies)
            var queue = [target.guid.stringValue]
            var visited: Set<String> = []
            while let node = queue.popLast() {
                for next in graph[node]?.map(\.guid) ?? [] {
                    if visited.insert(next).inserted {
                        if next == antecedent.guid.stringValue {
                            return true
                        }
                        queue.append(next)
                    }
                }
            }
            return false
        }
    }

    package func taskDiscoveredRequiredTargetDependency(target: ConfiguredTarget, antecedent: ConfiguredTarget, reason: RequiredTargetDependencyReason, warningLevel: BooleanWarningLevel) {
        let diagnosticBehavior: SWBUtil.Diagnostic.Behavior
        switch warningLevel {
        case .yesError: diagnosticBehavior = .error
        case .yes: diagnosticBehavior = .warning
        case .no: return
        }
        let targetDiagnosticsEngine = buildOutputDelegate.diagnosticsEngine(for: target)

        if !transitiveDependencyExists(target: target, antecedent: antecedent) {
            // Ensure we only diagnose missing dependencies when platform and SDK variant match. We perform this check as late as possible since computing settings can be expensive.
            let targetSettings = requestContext.getCachedSettings(target.parameters, target: target.target)
            let antecedentSettings = requestContext.getCachedSettings(antecedent.parameters, target: antecedent.target)
            guard targetSettings.platform?.name == antecedentSettings.platform?.name && targetSettings.sdkVariant?.name == antecedentSettings.sdkVariant?.name else {
                return
            }
            // Implicit dependency domains allow projects to build multiple copies of a module in a workspace with implicit dependencies enabled, so never diagnose a cross-domain dependency.
            guard targetSettings.globalScope.evaluate(BuiltinMacros.IMPLICIT_DEPENDENCY_DOMAIN) == antecedentSettings.globalScope.evaluate(BuiltinMacros.IMPLICIT_DEPENDENCY_DOMAIN) else {
                return
            }

            let message: DiagnosticData
            if self.userPreferences.enableDebugActivityLogs {
                message = DiagnosticData("'\(target.target.name):\(target.guid.stringValue)' is missing a dependency on '\(antecedent.target.name):\(antecedent.guid.stringValue)' because \(reason)")
            } else {
                message = DiagnosticData("'\(target.target.name)' is missing a dependency on '\(antecedent.target.name)' because \(reason)")
            }

            targetDiagnosticsEngine.emit(Diagnostic(behavior: diagnosticBehavior, location: .unknown, data: message))
        }
    }
}

/// The operation itself also acts as the execution delegate for its tasks.
extension BuildOperation: TaskExecutionDelegate {
    package var fs: any FSProxy {
        return delegate.fs ?? SWBUtil.localFS
    }

    package var buildCommand: BuildCommand? {
        return request.buildCommand
    }

    package var schemeCommand: SchemeCommand? {
        return request.schemeCommand
    }

    package var infoLookup: any PlatformInfoLookup {
        return core
    }

    package var sdkRegistry: SDKRegistry {
        return core.sdkRegistry
    }

    package var specRegistry: SpecRegistry {
        core.specRegistry
    }

    package var platformRegistry: PlatformRegistry {
        core.platformRegistry
    }

    package var namespace: MacroNamespace {
        workspace.userNamespace
    }

    package var emitFrontendCommandLines: Bool {
        buildDescription.emitFrontendCommandLines
    }
}

// BuildOperation uses reference semantics.
extension BuildOperation: Hashable {
    package func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    package static func ==(lhs: BuildOperation, rhs: BuildOperation) -> Bool {
        return lhs === rhs
    }
}

// Serializing and deserializing ConfiguredTargets requires the use of a ConfiguredTargetSerializerDelegate and a
// ConfiguredTargetDeserializerDelegate, so we create them here since we don't need any particular implementation of
// these delegates.
final class CustomTaskSerializerDelegate: ConfiguredTargetSerializerDelegate {
    var currentBuildParametersIndex: Int = 0
    var buildParametersIndexes = [BuildParameters : Int]()
    var currentConfiguredTargetIndex: Int = 0
    var configuredTargetIndexes = [ConfiguredTarget : Int]()
}

final class CustomTaskDeserializerDelegate: ConfiguredTargetDeserializerDelegate {
    var workspace: SWBCore.Workspace
    var buildParameters: [BuildParameters] = []
    var configuredTargets: [ConfiguredTarget] = []

    init(workspace: SWBCore.Workspace) {
        self.workspace = workspace
    }
}

/// Implementation of the DynamicTaskExecutionDelegate for the OperatorSystemAdaptor.
///
/// This object contains a reference to llbuild's BuildSystemCommandInterface object which is scoped to the actual
/// command being evaluated. Any requests done into an OperatorSystemAdaptorDynamicContext will be forwarded to the
/// BuildSystemCommandInterface, which in turn will configure the dependencies of the command currently being evaluated.
private struct OperatorSystemAdaptorDynamicContext: DynamicTaskExecutionDelegate {
    private let commandInterface: BuildSystemCommandInterface
    private let adaptor: OperationSystemAdaptor
    private let task: any ExecutableTask
    private let jobContext: JobContext?
    fileprivate let allowsExternalToolExecution: Bool

    fileprivate init(
        commandInterface: BuildSystemCommandInterface,
        adaptor: OperationSystemAdaptor,
        task: any ExecutableTask,
        jobContext: JobContext? = nil,
        allowsExternalToolExecution: Bool
    ) {
        self.commandInterface = commandInterface
        self.adaptor = adaptor
        self.task = task
        self.jobContext = jobContext
        self.allowsExternalToolExecution = allowsExternalToolExecution
    }

    func requestInputNode(node: ExecutionNode, nodeID: UInt) {
        commandInterface.commandNeedsInput(key: BuildKey.Node(path: node.identifier), inputID: nodeID)
    }

    func discoveredDependencyNode(_ node: ExecutionNode) {
        commandInterface.commandDiscoveredDependency(key: BuildKey.Node(path: node.identifier))
    }

    func discoveredDependencyDirectoryTree(_ path: Path) {
        commandInterface.commandDiscoveredDependency(key: BuildKey.DirectoryTreeSignature(path: path.str, filters: []))
    }

    func requestDynamicTask(
        toolIdentifier: String,
        taskKey: DynamicTaskKey,
        taskID: UInt,
        singleUse: Bool,
        workingDirectory: Path,
        environment: EnvironmentBindings = EnvironmentBindings(),
        forTarget: ConfiguredTarget?,
        priority: TaskPriority,
        showEnvironment: Bool = false,
        reason: DynamicTaskRequestReason?
    ) {
        let dynamicTask = DynamicTask(
            toolIdentifier: toolIdentifier,
            taskKey: taskKey,
            workingDirectory: workingDirectory,
            environment: environment,
            target: forTarget,
            showEnvironment: showEnvironment
        )

        // Serializing all of this information into the CustomTask key is not ideal, but because dynamic actions are by
        // definition not known during task planning, we need to encode the complete context for SwiftBuild to be able
        // to construct the dynamic task on the createCustomCommand hook. This also acts as a signature for the
        // CustomTask so that it can be properly cached.
        let serializer = MsgPackSerializer(delegate: CustomTaskSerializerDelegate())
        serializer.serialize(dynamicTask)
        let bytes = serializer.byteString

        // The name of the build key doesn't really matter, it's just that it needs to be unique in order to construct
        // unique TaskIdentifiers on the createCustomCommand hook.
        let identifier = TaskIdentifier(forTarget: forTarget, dynamicTaskPayload: bytes, priority: priority)
        let buildKey = BuildKey.CustomTask(
            name: identifier.rawValue,
            taskDataBytes: bytes.bytes
        )
        adaptor.taskRequestsDynamicTask(task: task, identifier: identifier)
        if singleUse {
            if adaptor.operation.request.recordBuildBacktraces, let reason = reason {
                // Since this is a single use task, record a backtrace frame describing why it was requested
                adaptor.recordBuildBacktraceFrame(identifier: .task(.taskIdentifier(ByteString(encodingAsUTF8: identifier.rawValue))), previousFrameIdentifier: .task(.taskIdentifier(ByteString(encodingAsUTF8: task.identifier.rawValue))), category: .dynamicTaskRequest, kind: reason.backtraceFrameKind, description: reason.description )
            }
            commandInterface.commandsNeedsSingleUseInput(key: buildKey, inputID: taskID)
        } else {
            commandInterface.commandNeedsInput(key: buildKey, inputID: taskID)
        }
    }

    @discardableResult
    func spawn(commandLine: [String], environment: [String: String], workingDirectory: String, processDelegate: any ProcessDelegate) async throws -> Bool {
        guard let jobContext else {
            throw StubError.error("API misuse. Spawning processes is only allowed from `performTaskAction`.")
        }

        // This calls into llb_buildsystem_command_interface_spawn, which can block, so ensure it's shunted to a new thread so as not to block the Swift Concurrency thread pool. This shouldn't risk thread explosion because this function is only allowed to be called from performTaskAction, which in turn should be bounded to ncores based on the number of active llbuild lane threads.
        return await _Concurrency.Task.detachNewThread(name: "llb_buildsystem_command_interface_spawn") { [commandInterface, jobContext, processDelegate] in
            commandInterface.spawn(jobContext, commandLine: commandLine, environment: environment, workingDirectory: workingDirectory, processDelegate: processDelegate)
        }
    }

    var operationContext: DynamicTaskOperationContext {
        return adaptor.dynamicOperationContext
    }

    var continueBuildingAfterErrors: Bool { adaptor.operation.request.continueBuildingAfterErrors }

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        return adaptor.beginActivity(ruleInfo: ruleInfo, executionDescription: executionDescription, signature: signature, target: target, parentActivity: parentActivity)
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
        adaptor.endActivity(id: id, signature: signature, status: status)
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
        adaptor.emit(data: data, for: activity, signature: signature)
    }

    func emit(diagnostic: SWBUtil.Diagnostic, for activity: ActivityID, signature: ByteString) {
        adaptor.emit(diagnostic: diagnostic, for: activity, signature: signature)
    }

    var hadErrors: Bool {
        adaptor.hadErrors
    }

    func recordBuildBacktraceFrame(identifier: SWBProtocol.BuildOperationBacktraceFrameEmitted.Identifier, previousFrameIdentifier: BuildOperationBacktraceFrameEmitted.Identifier?, category: BuildOperationBacktraceFrameEmitted.Category, kind: BuildOperationBacktraceFrameEmitted.Kind, description: String) {
        adaptor.recordBuildBacktraceFrame(identifier: identifier, previousFrameIdentifier: previousFrameIdentifier, category: category, kind: kind, description: description)
    }
}

private class InProcessCommand: SWBLLBuild.ExternalCommand, SWBLLBuild.ExternalDetachedCommand {
    let task: any ExecutableTask
    let action: TaskAction
    let adaptor: OperationSystemAdaptor

    init(task: any ExecutableTask, action: TaskAction, adaptor: OperationSystemAdaptor) {
        self.task = task
        self.action = action
        self.adaptor = adaptor
    }

    func getSignature(_ command: Command) -> [UInt8] {
        let signature = action.getSignature(task, executionDelegate: adaptor.operation).bytes
        return signature
    }

    // temporary for compatibility
    var depedencyDataFormat: SWBLLBuild.DependencyDataFormat {
        dependencyDataFormat
    }

    var dependencyDataFormat: SWBLLBuild.DependencyDataFormat {
        switch task.dependencyData {
        case .makefile?, .makefiles?:
            return .makefile
        case .makefileIgnoringSubsequentOutputs:
            return .makefileIgnoringSubsequentOutputs
        case .dependencyInfo?:
            return .dependencyinfo
        case .none:
            return .unused
        }
    }

    var dependencyPaths: [String] {
        switch task.dependencyData {
        case let .makefile(path)?:
            return [path.str]
        case let .makefiles(paths)?:
            return paths.map(\.str)
        case let .makefileIgnoringSubsequentOutputs(path):
            return [path.str]
        case let .dependencyInfo(path)?:
            return [path.str]
        case .none:
            return []
        }
    }

    var workingDirectory: String? {
        task.workingDirectory.str
    }

    fileprivate func start(_ command: Command, _ commandInterface: BuildSystemCommandInterface) {
        let adaptorInterfaceDelegate = OperatorSystemAdaptorDynamicContext(
            commandInterface: commandInterface,
            adaptor: adaptor,
            task: task,
            allowsExternalToolExecution: adaptor.userPreferences.allowsExternalToolExecution
        )
        action.taskSetup(task, executionDelegate: adaptor.operation, dynamicExecutionDelegate: adaptorInterfaceDelegate)
    }

    fileprivate func provideValue(
        _ command: Command,
        _ commandInterface: BuildSystemCommandInterface,
        _ buildValue: BuildValue,
        _ inputID: UInt
    ) {
        let adaptorInterfaceDelegate = OperatorSystemAdaptorDynamicContext(
            commandInterface: commandInterface,
            adaptor: adaptor,
            task: task,
            allowsExternalToolExecution: adaptor.userPreferences.allowsExternalToolExecution
        )

        action.taskDependencyReady(task, inputID, BuildValueKind(buildValue.kind), dynamicExecutionDelegate: adaptorInterfaceDelegate, executionDelegate: adaptor.operation)
    }

    fileprivate func execute(_ command: Command, _ commandInterface: BuildSystemCommandInterface, _ jobContext: JobContext) -> CommandResult {
        // FIXME: This is unsafe and could deadlock due to thread starvation. rdar://107154900 tracks making this truly asynchronous, which requires some work at the llbuild layer as well.
        runAsyncAndBlock {
            await self.execute(command, commandInterface, jobContext)
        }
    }

    fileprivate func execute(_ command: Command, _ commandInterface: BuildSystemCommandInterface, _ jobContext: JobContext) async -> CommandResult {
        // Get the current output delegate from the adaptor.
        //
        // FIXME: This should never fail (since we are executing), but we have seen a crash here with that assumption. For now we are defensive until the source can be tracked down: <rdar://problem/31670274> Diagnose unexpected missing output delegate from: <rdar://problem/31669245> Crash in InProcessCommand.execute()
        guard let outputDelegate = adaptor.getActiveOutputDelegate(command) else {
            return .failed
        }

        let adaptorInterfaceDelegate = OperatorSystemAdaptorDynamicContext(
            commandInterface: commandInterface,
            adaptor: adaptor,
            task: task,
            jobContext: jobContext,
            allowsExternalToolExecution: adaptor.userPreferences.allowsExternalToolExecution
        )

        let timer = ElapsedTimer()
        let result = await action.performTaskAction(
            task,
            dynamicExecutionDelegate: adaptorInterfaceDelegate,
            executionDelegate:
            adaptor.operation,
            clientDelegate:
            adaptor.operation.clientDelegate,
            outputDelegate: outputDelegate
        )

        if outputDelegate.result == nil {
            let duration = timer.elapsedTime()
            let metrics = SWBCore.CommandMetrics(utime: duration.microseconds, stime: duration.microseconds, maxRSS: 0, wcDuration: duration)
            switch result {
            case .succeeded:
                outputDelegate.updateResult(.succeeded(metrics: metrics))
            case .failed:
                outputDelegate.updateResult(.exit(exitStatus: .exit(EXIT_FAILURE), metrics: metrics))
            default:
                // Not updating the result will update it in a callback from llbuild
                break
            }
        }

        return result
    }

    var shouldExecuteDetached: Bool {
        return action.shouldExecuteDetached
    }

    func executeDetached(
        _ command: Command,
        _ commandInterface: BuildSystemCommandInterface,
        _ jobContext: JobContext,
        _ resultFn: @escaping (CommandResult, BuildValue?) -> Void
    ) {
        _Concurrency.Task<Void, Never> {
            let result = await self.execute(command, commandInterface, jobContext)
            resultFn(result, nil)
        }
    }

    func cancelDetached(_ command: Command) {
        action.cancelDetached()
    }
}

private class BuildValueValidatingInProcessCommand: InProcessCommand, ProducesCustomBuildValue {
    func isResultValid(_ command: Command, _ buildValue: BuildValue) -> Bool {
        (action as! (any BuildValueValidatingTaskAction)).isResultValid(task, adaptor.dynamicOperationContext, buildValue: buildValue)
    }

    func isResultValid(_ command: Command, _ buildValue: BuildValue, _ fallback: (Command, BuildValue) -> Bool) -> Bool {
        func fallbackWrapper(_ buildValue: BuildValue) -> Bool {
            return fallback(command, buildValue)
        }

        return (action as! (any BuildValueValidatingTaskAction)).isResultValid(task, adaptor.dynamicOperationContext, buildValue: buildValue, fallback: fallbackWrapper)
    }

    func execute(_ command: Command, _ commandInterface: BuildSystemCommandInterface) -> BuildValue {
        // Returning an invalid build value makes llbuild fall back into the other API that returns a Bool
        BuildValue.Invalid()
    }
}



private final class InProcessTool:  SWBLLBuild.Tool {
    let actionType: TaskAction.Type
    let description: BuildDescription
    let adaptor: OperationSystemAdaptor

    init(actionType: TaskAction.Type, description: BuildDescription, adaptor: OperationSystemAdaptor) {
        self.actionType = actionType
        self.description = description
        self.adaptor = adaptor
    }

    func createCommand(_ name: String) -> (any SWBLLBuild.ExternalCommand)? {
        // FIXME: Find a better way to maintain command associations.
        guard let task = description.taskStore.task(for: TaskIdentifier(rawValue: name)) else {
            // This should never happen, unless perhaps the manifest and build description are out of sync.
            return nil
        }
        guard let taskAction = description.taskStore.taskAction(for: TaskIdentifier(rawValue: name)) else {
            return nil
        }

        // Validate the task's action.
        assert(type(of: taskAction) == actionType, "\(taskAction) (\(type(of: taskAction))) is not of expected type \(actionType).")

        if taskAction is (any BuildValueValidatingTaskAction) {
            return BuildValueValidatingInProcessCommand(task: task, action: taskAction, adaptor: adaptor)
        } else {
            return InProcessCommand(task: task, action: taskAction, adaptor: adaptor)
        }

    }

    func createCustomCommand(_ buildKey: BuildKey.CustomTask) -> (any ExternalCommand)? {
        let byteString = ByteString(buildKey.taskDataBytes)
        let deserializer = MsgPackDeserializer.init(
            byteString,
            delegate: CustomTaskDeserializerDelegate(workspace: adaptor.workspace)
        )

        guard let dynamicTask = try? DynamicTask(from: deserializer),
            let spec = DynamicTaskSpecRegistry.spec(for: dynamicTask.toolIdentifier) else {
            return nil
        }

        guard let executableTask = try? spec.buildExecutableTask(dynamicTask: dynamicTask, context: adaptor.dynamicOperationContext),
              let taskAction = try? spec.buildTaskAction(dynamicTaskKey: dynamicTask.taskKey, context: adaptor.dynamicOperationContext) else {
            return nil
        }

        adaptor.registerDynamicTask(identifier: TaskIdentifier(rawValue: buildKey.name), task: executableTask)

        if taskAction is (any BuildValueValidatingTaskAction) {
            return BuildValueValidatingInProcessCommand(task: executableTask, action: taskAction, adaptor: adaptor)
        } else {
            return InProcessCommand(task: executableTask, action: taskAction, adaptor: adaptor)
        }

    }
}

/// Private adaptor for translating the low-level build system's delegate protocol to the operation's delegate.
internal final class OperationSystemAdaptor: SWBLLBuild.BuildSystemDelegate, ActivityReporter {
    var fs: (any SWBLLBuild.FileSystem)? { return operation.delegate.fs.map(FileSystemImpl.init) }

    /// The operation this adaptor is being used for.
    ///
    /// This is mutable because we reuse the adaptor for multiple builds.
    fileprivate unowned var operation: BuildOperation

    /// The output delegate this adaptor is being used for.
    ///
    /// This is mutable because we reuse the adaptor for multiple builds.
    private var buildOutputDelegate: any BuildOutputDelegate

    private let core: Core

    private var isCompleted = false

    private var description: BuildDescription {
        return operation.buildDescription
    }

    fileprivate var workspace: SWBCore.Workspace {
        return operation.workspace
    }

    fileprivate var userPreferences: SWBCore.UserPreferences {
        return operation.userPreferences
    }

    private let dynamicTasks: LockedValue<[TaskIdentifier: any ExecutableTask]> = .init([:])

    /// Serial queue used to order interactions with the operation delegate.
    fileprivate let queue: SWBQueue

    /// Protected by `queue`.
    private var _progressStatistics: BuildOperation.ProgressStatistics

    /// The map of active commands to output delegates.
    ///
    /// - Precondition: Protected by `queue`.
    private var commandOutputDelegates: [Command: any TaskOutputDelegate] = [:]

    fileprivate let dynamicOperationContext: DynamicTaskOperationContext

    /// Returns the delegate's `aggregatedCounters` in a thread-safe manner.
    func getAggregatedCounters() async -> [BuildOperationMetrics.Counter: Int] {
        return await queue.sync { self.operation.delegate.aggregatedCounters }
    }

    /// Returns the delegate's `aggregatedTaskCounters` in a thread-safe manner.
    func getAggregatedTaskCounters() async -> [String: [BuildOperationMetrics.TaskCounter: Int]] {
        return await queue.sync { self.operation.delegate.aggregatedTaskCounters }
    }

    init(operation: BuildOperation, buildOutputDelegate: any BuildOutputDelegate, core: Core) {
        self.operation = operation
        self.buildOutputDelegate = buildOutputDelegate
        self._progressStatistics = BuildOperation.ProgressStatistics(numCommandsLowerBound: operation.buildDescription.targetTaskCounts.values.reduce(0, { $0 + $1 }))
        self.core = core
        let cas: ToolchainCAS?
        do {
            cas = try Self.setupCAS(core: core, operation: operation)
        } catch {
            buildOutputDelegate.error(error.localizedDescription)
            cas = nil
        }
        self.dynamicOperationContext = DynamicTaskOperationContext(core: core, definingTargetsByModuleName: operation.buildDescription.definingTargetsByModuleName, cas: cas)
        self.queue = SWBQueue(label: "SWBBuildSystem.OperationSystemAdaptor.queue", qos: operation.request.qos, autoreleaseFrequency: .workItem)
    }

    private static func setupCAS(core: Core, operation: BuildOperation) throws -> ToolchainCAS? {
        let settings = operation.requestContext.getCachedSettings(operation.request.parameters)
        let casOptions = try CASOptions.create(settings.globalScope, .generic)
        let casPlugin: ToolchainCASPlugin?
        if let pluginPath = casOptions.pluginPath {
            casPlugin = try? ToolchainCASPlugin(dylib: pluginPath)
        } else {
            casPlugin = core.lookupCASPlugin()
        }
        return try? casPlugin?.createCAS(path: casOptions.casPath, options: [:])
    }

    /// Reset the operation for a new build.
    func reset(operation: BuildOperation, buildOutputDelegate: any BuildOutputDelegate) async {
        self.operation = operation
        self.buildOutputDelegate = buildOutputDelegate

        assert(commandOutputDelegates.isEmpty)
        commandOutputDelegates.removeAll()
        startedTargets.removeAll()
        preparedTaskCounts.removeAll()
        completedTaskCounts.removeAll()
        await dynamicOperationContext.reset(completionToken: dynamicOperationContext.waitForCompletion())
        await queue.sync {
            self.isCompleted = false
            self._progressStatistics.reset()
        }
    }

    func taskRequestsDynamicTask(task: any ExecutableTask, identifier: TaskIdentifier) {
        queue.async {
            self.operation.delegate.taskRequestedDynamicTask(self.operation, requestingTask: task, dynamicTaskIdentifier: identifier)
        }
    }

    func registerDynamicTask(identifier: TaskIdentifier, task: any ExecutableTask) {
        dynamicTasks.withLock {
            $0[identifier] = task
        }
        queue.async {
            self.operation.delegate.registeredDynamicTask(self.operation, task: task, dynamicTaskIdentifier: identifier)
        }
    }

    func dynamicTask(for identifier: TaskIdentifier) -> (any ExecutableTask)? {
        return dynamicTasks.withLock { $0[identifier] }
    }

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        queue.blocking_sync {
            operation.delegate.beginActivity(operation, ruleInfo: ruleInfo, executionDescription: executionDescription, signature: signature, target: target, parentActivity: parentActivity)
        }
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
        queue.blocking_sync {
            operation.delegate.endActivity(operation, id: id, signature: signature, status: status)
        }
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
        queue.blocking_sync {
            operation.delegate.emit(data: data, for: activity, signature: signature)
        }
    }

    func emit(diagnostic: SWBUtil.Diagnostic, for activity: ActivityID, signature: ByteString) {
        queue.blocking_sync {
            operation.delegate.emit(diagnostic: diagnostic, for: activity, signature: signature)
        }
    }

    var hadErrors: Bool {
        queue.blocking_sync {
            operation.delegate.hadErrors
        }
    }

    func recordBuildBacktraceFrame(identifier: SWBProtocol.BuildOperationBacktraceFrameEmitted.Identifier, previousFrameIdentifier: BuildOperationBacktraceFrameEmitted.Identifier?, category: BuildOperationBacktraceFrameEmitted.Category, kind: BuildOperationBacktraceFrameEmitted.Kind, description: String) {
        queue.blocking_sync {
            operation.delegate.recordBuildBacktraceFrame(identifier: identifier, previousFrameIdentifier: previousFrameIdentifier, category: category, kind: kind, description: description)
        }
    }

    /// Wait for all status activity to be complete before returning.
    func waitForCompletion(buildSucceeded: Bool) async {
        let completionToken = await dynamicOperationContext.waitForCompletion()
        cleanupCompilationCache()

        await queue.sync {
            self.isCompleted = true

            // The build should be complete, validate the consistency of the target/task counts.
            self.validateTargetCompletion(buildSucceeded: buildSucceeded)

            // If the build failed, make sure we flush any pending incremental build records.
            // Usually, driver instances are cleaned up and write out their incremental build records when a target finishes building. However, this won't necessarily be the case if the build fails. Ensure we write out any pending records before tearing down the graph so we don't use a stale record on a subsequent build.
            if !buildSucceeded {
                self.dynamicOperationContext.swiftModuleDependencyGraph.cleanUpForAllKeys()
            }

            // Reset the DynamicOperationContext to free cached info from the finished build.
            self.dynamicOperationContext.reset(completionToken: completionToken)
        }
    }

    /// Cleanup the compilation cache to reduce resource usage in environments not configured to preserve it.
    func cleanupCompilationCache() {
        let settings = operation.requestContext.getCachedSettings(operation.request.parameters)
        if settings.globalScope.evaluate(BuiltinMacros.COMPILATION_CACHE_KEEP_CAS_DIRECTORY) {
            return // Keep the cache directory.
        }

        let cachePath = Path(settings.globalScope.evaluate(BuiltinMacros.COMPILATION_CACHE_CAS_PATH))
        guard !cachePath.isEmpty, operation.fs.exists(cachePath) else {
            return
        }

        let signatureCtx = InsecureHashContext()
        signatureCtx.add(string: "CleanupCompileCache")
        signatureCtx.add(string: cachePath.str)
        let signature = signatureCtx.signature

        withActivity(ruleInfo: "CleanupCompileCache \(cachePath.str)", executionDescription: "Cleanup compile cache at \(cachePath)", signature: signature, target: nil, parentActivity: nil) { activity in
            do {
                try operation.fs.removeDirectory(cachePath)
            } catch {
                // Log error but do not fail the build.
                emit(diagnostic: Diagnostic.init(behavior: .warning, location: .unknown, data: DiagnosticData("Error cleaning up \(cachePath): \(error.localizedDescription)")), for: activity, signature: signature)
            }
            return .succeeded
        }
    }

    /// Get the active output delegate for an executing command.
    ///
    /// - returns: The active delegate, or nil if not found.
    func getActiveOutputDelegate(_ command: Command) -> (any TaskOutputDelegate)? {
        // FIXME: This is a very bad idea, doing a sync against the response queue is introducing artificial latency when an in-process command needs to wait for the response queue to flush. However, we also can't simply move to a decoupled lock, because we don't want the command to start reporting output before it has been fully reported as having started. We need to move in-process task to another model.
        return queue.blocking_sync {
            self.commandOutputDelegates[command]
        }
    }

    // MARK: Target Task Tracking.
    //
    // We support delegate methods for notifying the client when a target has started and completed building. Historically, Xcode built on a per-target basis and this was easy to provide, but it doesn't integrate particularly cleanly with how the low-level build system sees the world. In particular, the combination of dynamic work discovery and our desire to be able to process arbitrary subgraphs makes it difficult to easily identify the exact set of work for a target in advance.
    //
    // Instead, we rely on a system which assumes that once any work for a target has begun (i.e., one of its commands is preparing to run, even if it hasn't yet been scheduled), that there will always be at least one other command for that target preparing to run. Conceptually this makes sense because once started, a target cannot be complete until no part of it is waiting to build. In theory, the low-level system is capable of allowing us to subsequently discover additional work for a target, but we take care to assert that we never generate tasks that would actually do that.

    /// Set of configured target guids of targets which have started building.  This means that at least one concrete (i.e., non-gate) task for that target has actually started running.
    ///
    /// Access to this variable should be protected by the delegate queue.
    private var startedTargets = Set<ConfiguredTarget.GUID>()

    // Presently there is not a 'completedTargets' property, because we have no need for it.

    /// Mapping of configured target guids to the number of prepared tasks for that target.
    ///
    /// Access to this variable should be protected by the delegate queue.
    private var preparedTaskCounts: [ConfiguredTarget.GUID: Int] = [:]

    /// Mapping of configured target guids to the number of completed tasks for that target.  These tasks may not have been actually run in this build, but merely noted to already be up-to-date.
    ///
    /// Access to this variable should be protected by the delegate queue.
    private var completedTaskCounts: [ConfiguredTarget.GUID: Int] = [:]

    /// Update the count of started associated tasks for a target.
    private func preparingTaskForTarget(_ target: ConfiguredTarget) {
        let count = (preparedTaskCounts[target.guid] ?? 0) + 1
        preparedTaskCounts[target.guid] = count

        // If this was the first task, then note that target preparation has started.
        if count == 1 {
            operation.delegate.targetPreparationStarted(operation, configuredTarget: target)
        }
    }

    /// Update the count of completed associated tasks for a target.
    private func completedTaskForTarget(_ target: ConfiguredTarget) {
        let count = (completedTaskCounts[target.guid] ?? 0) + 1
        completedTaskCounts[target.guid] = count

        if !operation.mayBuildMultipleNodes {
            // If we have seen every task for a target, we are done. Only perform this check if doing a traditional build of the entire graph. If we're building multiple nodes, we can't rely on this bookkeeping because the same task may be reported as complete, then up to date 0 or more additional times. `_completedTaskForTarget` will still be invoked once the entire build is complete.
            let expectedCount = operation.buildDescription.targetTaskCounts[target] ?? 0
            assert(count <= expectedCount)
            if count == expectedCount {
                _completedTaskForTarget(target)
            }
        }
    }

    /// Validate the consistency of the target task counts
    private func validateTargetCompletion(buildSucceeded: Bool) {
        if buildSucceeded {
            for (target, startedCount) in preparedTaskCounts {
                let completedCount = completedTaskCounts[target] ?? 0
                if startedCount != completedCount {
                    // In some cases, when a cycle occurs during the indexing build, the "continue building after failure" setting causes SwiftBuild to ignore the error. However, in this case llbuild cannot continue when a cycle is detected, so some command status callbacks may not have been called.
                    self.buildOutputDelegate.error("The build service has encountered an internal inconsistency error: unexpected incomplete target: \(target) (started: \(startedCount), completed: \(completedCount))")
                }
            }
        }

        // By the time we've completed the build, we've seen every task for a target by definition. This ensures that the target-completed event is always sent in cases where we may be building slices of a target, as in single file builds or other builds which only build a subset of tasks in the graph. Additionally, if we're building multiple nodes, make sure to mark the target completed regardless, since we don't mark it completed in completedTaskForTarget.
        for (targetGuid, count) in completedTaskCounts {
            if let target = operation.buildDescription.allConfiguredTargets.filter({ $0.guid == targetGuid }).only {
                let expectedCount = operation.buildDescription.targetTaskCounts[target] ?? 0
                if count < expectedCount || operation.mayBuildMultipleNodes {
                    _completedTaskForTarget(target)
                }
            }
        }
    }

    private func _completedTaskForTarget(_ target: ConfiguredTarget) {
        operation.delegate.targetComplete(operation, configuredTarget: target)

        // Once a target finishes, we can clean up the associated Swift driver memory
        // First, give it a chance to write out incremental state
        let driverIdentifiers = operation.buildDescription.taskStore.tasksForTarget(target).compactMap { ($0.payload as? SwiftTaskPayload)?.driverPayload?.uniqueID }
        for identifier in Set(driverIdentifiers) {
            dynamicOperationContext.swiftModuleDependencyGraph.cleanUp(key: identifier)
        }
    }

    // MARK: Delegate Methods

    func lookupTool(_ name: String) -> (any SWBLLBuild.Tool)? {
        // See if we a have a tool entry.
        if let type = self.description.taskActionMap[name] {
            return InProcessTool(actionType: type, description: description, adaptor: self)
        }

        return nil
    }

    private func lookupTask(_ identifier: TaskIdentifier) -> (any ExecutableTask)? {
        // Get the task for this command.
        //
        // FIXME: Find a better way to maintain command associations.
         if let registeredTask = description.taskStore.task(for: identifier) {
            return registeredTask
        } else if let dynamicTask = dynamicTask(for: identifier) {
            return dynamicTask
        } else {
            // If we didn't have a task, we just ignore the status currently. This could be a dynamic command from a
            // task, or it could be synthetic commands not correlated to any one task.
            //
            // FIXME: Design a strategy for reporting status of those things. We should at least be able to concretely
            // associate them to some record, so that we can detect programming errors.
            return nil
        }
    }

    func hadCommandFailure() {
        queue.blocking_sync() {
            if !operation.request.continueBuildingAfterErrors {
                // The cancel() operation is synchronous, waiting for all tasks in the build to
                // resolve. Since some of those tasks may be in the middle of calling back here
                // we can deadlock if this is done while still holding on to the internal queue.
                // To prevent this, we move the actual cancel onto a global queue. rdar://77560623
                let operation = self.operation
                SWBQueue.global().async(qos: SWBUtil.UserDefaults.defaultRequestQoS) {
                    operation.abort()
                }
            }
        }
    }

    func handleDiagnostic(_ diagnostic: SWBLLBuild.Diagnostic) {
        queue.async {
            // Determine the message.
            let location: SWBUtil.Diagnostic.Location
            if let llbLocation = diagnostic.location {
                location = .path(Path(llbLocation.filename), line: llbLocation.line, column: llbLocation.column)
            } else {
                location = .unknown
            }

            switch diagnostic.kind {
            case .error:
                self.buildOutputDelegate.error(diagnostic.message, location: location)
            case .warning:
                self.buildOutputDelegate.warning(diagnostic.message, location: location)
            case .note:
                self.buildOutputDelegate.note(diagnostic.message, location: location)
            @unknown default:
                fatalError("Unknown value '\(diagnostic.kind.rawValue)' in \(type(of: diagnostic.kind)) enumeration")
            }
        }
    }

    func commandStatusChanged(_ command: Command, kind: CommandStatusKind) {
        // Get the task for this command.
        guard let task = lookupTask(TaskIdentifier(command: command)) else {
            // See comments below.
            return
        }

        // Ignore gate tasks.
        guard !task.isGate else { return }

        // Update the target task counts.
        queue.async {
            switch kind {
            case .isScanning:
                self._progressStatistics.numCommandsScanned += 1
                self._progressStatistics.numCommandsActivelyScanning += 1
                if !task.isDynamic {
                    task.forTarget.map(self.preparingTaskForTarget)
                }

            case .isUpToDate:
                self._progressStatistics.numCommandsUpToDate += 1
                self._progressStatistics.numCommandsActivelyScanning -= 1
                self._progressStatistics.numCommandsCompleted += 1
                self.operation.delegate.taskUpToDate(self.operation, taskIdentifier: TaskIdentifier(command: command), task: task)
                if !task.isDynamic {
                    task.forTarget.map(self.completedTaskForTarget)
                }

            case .isComplete:
                self._progressStatistics.numCommandsActivelyScanning -= 1
                self._progressStatistics.numCommandsCompleted += 1
                if !task.isDynamic {
                    task.forTarget.map(self.completedTaskForTarget)
                }
            @unknown default:
                fatalError("Unknown value '\(kind.rawValue)' in \(type(of: kind)) enumeration")
            }

            self.operation.delegate.totalCommandProgressChanged(self.operation, forTargetName: task.forTarget?.target.name, statistics: self._progressStatistics)
        }
    }

    func commandPreparing(_ command: Command) {
        // Allow the build system to write out any dynamically created dependency information before the command is started.
        if let task = lookupTask(TaskIdentifier(command: command)) {
            if let spec = task.type as? CommandLineToolSpec, let data = task.dependencyData {
                do {
                    try spec.create(dependencyData: data, for: task, fs: operation.fs)
                } catch {
                    commandHadWarning(command, message: "Unable to create dependency info file: \(error.localizedDescription)")
                }
            }
        }
    }

    func shouldCommandStart(_ command: Command) -> Bool {
        // See comments in commandStarted about why missing tasks are OK.
        guard let task = lookupTask(TaskIdentifier(command: command)) else { return true }

        // Limit builds to top-level targets if requested.
        if let target = task.forTarget?.target, operation.request.shouldSkipExecution(target: target) {
            return false
        }

        // Limit builds to tasks that are active for the current build command.
        return task.type.shouldStart(task, buildCommand: operation.request.buildCommand)
    }

    func commandStarted(_ command: Command) {
        let taskIdentifier = TaskIdentifier(command: command)
        guard let task = lookupTask(taskIdentifier) else {
            return
        }

        if operation.request.recordBuildBacktraces, task.isDynamic {
            // Record an 'adapter' backtrace frame which bridges a dynamic task identifier to the identifier of the materialized task.
            recordBuildBacktraceFrame(identifier: .task(.taskIdentifier(ByteString(encodingAsUTF8: task.identifier.rawValue))), previousFrameIdentifier: .task(.taskIdentifier(ByteString(encodingAsUTF8: taskIdentifier.rawValue))), category: .dynamicTaskRegistration, kind: .unknown, description: "")
        }

        queue.async {
            // If this task should be shown in log, then record that this task's target (if any) has started running.  Then, if this is the first task to start running for that target, inform the operation client that the target has started.
            if task.showInLog, let forTarget = task.forTarget {
                if self.startedTargets.insert(forTarget.guid).inserted {
                    self.operation.delegate.targetStarted(self.operation, configuredTarget: forTarget)
                }
            }

            // Gate tasks are not counted when scanning, so they can't be counted here either.
            if !task.isGate {
                self._progressStatistics.numCommandsStarted += 1
            }

            let dependencyInfo: CommandLineDependencyInfo?
            if self.userPreferences.enableDebugActivityLogs {
                dependencyInfo = .init(task: task)
            } else {
                dependencyInfo = nil
            }

            // Notify the operation client.
            let outputDelegate = self.operation.delegate.taskStarted(self.operation, taskIdentifier: taskIdentifier, task: task, dependencyInfo: dependencyInfo)

            // Record the active delegate.
            self.commandOutputDelegates[command] = outputDelegate

            self.operation.delegate.totalCommandProgressChanged(self.operation, forTargetName: task.forTarget?.target.name, statistics: self._progressStatistics)

            let level = self.operation.buildDescription.levelForDiagnosticMessagesForTaskInputsWithoutProducer(task: task)
            if level == .no {
                return
            }

            for input in task.inputPaths {
                if let message = self.operation.buildDescription.diagnosticMessageForTaskInputWithoutProducer(path: input.withoutTrailingSlash(), isDiscoveredDependency: false, task: task, fs: self.operation.fs) {
                    switch level {
                    case .yesError:
                        outputDelegate.emitError(message)
                        outputDelegate.updateResult(.failedSetup)
                    case .yes:
                        outputDelegate.emitWarning(message)
                    case .no:
                        break
                    }
                }
            }
        }
    }

    func commandFinished(_ command: Command, result: CommandResult) {
        commandFinished(command, result: result, failedTaskSetup: false)
    }

    func commandFinished(_ command: Command, result: CommandResult, failedTaskSetup: Bool) {
        // Get the task for this command.
        let taskIdentifier = TaskIdentifier(command: command)
        guard let task = lookupTask(taskIdentifier) else {
            // See comments above.
            return
        }

        queue.async {
            // Find the output delegate, and remove it from the active set.
            guard let outputDelegate = self.commandOutputDelegates.removeValue(forKey: command) else {
                // If there's no outputDelegate, the command never started (i.e. it was skipped by shouldCommandStart().
                return
            }

            outputDelegate.emitSandboxingViolations(task: task, commandResult: result)

            // This may be updated by commandProcessFinished if it was an
            // ExternalCommand, so only update the exit status in output delegate if
            // it is nil. However, always update the status if the result is failed,
            // since that should override the result of the process execution (for
            // example if we failed to process discovered dependencies).
            if outputDelegate.result == nil || result == .failed {
                if failedTaskSetup {
                    outputDelegate.updateResult(.failedSetup)
                } else {
                    switch result {
                    case .failed:
                        outputDelegate.updateResult(.exit(exitStatus: .exit(1), metrics: nil))
                    case .cancelled:
                        outputDelegate.updateResult(.exit(exitStatus: .buildSystemCanceledTask, metrics: nil))
                    case .skipped:
                        outputDelegate.updateResult(.skipped)
                    case .succeeded:
                        outputDelegate.updateResult(.succeeded(metrics: nil))
                    @unknown default:
                        fatalError("Unknown value '\(result.rawValue)' in \(type(of: result)) enumeration")
                    }
                }
            }

            // Notify the operation client.
            self.operation.delegate.taskComplete(self.operation, taskIdentifier: taskIdentifier, task: task, delegate: outputDelegate)
        }
    }

    func commandFoundDiscoveredDependency(_ command: Command, path: String, kind: DiscoveredDependencyKind) {
        guard kind == .input else {
            return
        }

        guard let task = lookupTask(TaskIdentifier(command: command)) else {
            return
        }

        // Don't diagnose missing inputs from discovered dependencies of `SwiftStdLibToolSpec`. This spec creates
        // tasks which scan the contents of specified folders, and it would be non-trivial at this time to ensure
        // the producers of those files declare their outputs.
        if task.type is SwiftStdLibToolSpec {
            return
        }

        // For discovered dependencies, we want to resolve symlinks, since Clang's discovered dependencies may point to
        // unresolved symlinks (built products in SYMROOT are symlinks). This is similar to what we do in the spec
        // infrastructure for modifying ld64-style dependency info to resolve symlinks, and should probably be done
        // in the same way, but we would need a makefile parser for that.
        func effectivePath(for path: Path) throws -> Path {
            // Discovered dependencies can point to non-existent files outside the build directory; don't attempt to resolve those.
            let realPath = operation.buildDescription.isPathInBuildDirectory(path: path, task: task, fs: operation.fs) ? try operation.fs.realpath(path) : path
            if realPath != path && operation.userPreferences.enableDebugActivityLogs {
                commandHadNote(command, message: "Resolved symbolic link '\(path.str)' from discovered dependencies to '\(realPath.str)'.")
            }
            return realPath
        }

        do {
            let level = self.operation.buildDescription.levelForDiagnosticMessagesForTaskInputsWithoutProducer(task: task)
            if level == .no {
                return
            }

            if let message = try operation.buildDescription.diagnosticMessageForTaskInputWithoutProducer(path: effectivePath(for: Path(path)), isDiscoveredDependency: true, task: task, fs: operation.fs) {
                switch level {
                case .yesError:
                    commandHadError(command, message: message, failedTaskSetup: true)
                case .yes:
                    commandHadWarning(command, message: message)
                case .no:
                    break
                }
            }
        } catch {
            commandHadWarning(command, message: "Unable to validate discovered dependency: \(error.localizedDescription)")
        }
    }

    func commandHadNote(_ command: Command, message: String) {
        queue.async {
            if let outputDelegate = self.commandOutputDelegates[command] {
                outputDelegate.emitNote(message)
            } else {
                self.buildOutputDelegate.note(message)
            }
        }
    }

    func commandHadError(_ command: Command, message: String) {
        commandHadError(command, message: message, failedTaskSetup: false)
    }

    func commandHadError(_ command: Command, message: String, failedTaskSetup: Bool) {
        queue.async {
            if let outputDelegate = self.commandOutputDelegates[command] {
                outputDelegate.emitError(message)
                if failedTaskSetup {
                    outputDelegate.updateResult(.failedSetup)
                }
            } else {
                self.buildOutputDelegate.error(message)
            }
        }
    }

    func commandHadWarning(_ command: Command, message: String) {
        queue.async {
            if let outputDelegate = self.commandOutputDelegates[command] {
                outputDelegate.emitWarning(message)
            } else {
                self.buildOutputDelegate.warning(message)
            }
        }
    }

    func commandCannotBuildOutputDueToMissingInputs(_ command: Command, output: BuildKey, inputs: [BuildKey]) {
        self.commandCannotBuildOutputDueToMissingInputs(command, output: output as BuildKey?, inputs: inputs)
    }

    func commandCannotBuildOutputDueToMissingInputs(_ command: Command, output: BuildKey?, inputs: [BuildKey]) {
        let message: String
        let inputDescriptions: OrderedSet<String> = .init(inputs.map({ "'\($0.key)'" }))
        if inputDescriptions.isEmpty {
            message = "Unknown build input cannot be found."
        } else {
            let inputsString = inputDescriptions.joined(separator: ", ")
            let allInputsAreFiles = inputs.map { ($0.kind == .customTask, $0.key) }.filter { $0 == false && $1.hasPrefix("<") }.isEmpty
            let adviceString = inputDescriptions.count > 1
            ? "Did you forget to declare these \(allInputsAreFiles ? "file" : "node")s as outputs of any script phases or custom build rules which produce them?"
            : "Did you forget to declare this \(allInputsAreFiles ? "file" : "node") as an output of a script phase or custom build rule which produces it?"
            message = "Build input\(allInputsAreFiles ? " file" : "")\(inputDescriptions.count > 1 ? "s" : "") cannot be found: \(inputsString). \(adviceString)"
        }
        // This error happens before the command has started, so we do this here in order to have a command output delegate.
        commandStarted(command)
        commandHadError(command, message: message)
        commandFinished(command, result: .failed, failedTaskSetup: true)
    }

    func chooseCommandFromMultipleProducers(output: BuildKey, commands: [Command]) -> Command? {
        let buildRequest = self.operation.request
        guard buildRequest.enableIndexBuildArena else { return nil }

        // The following only applies for an index build operation.
        //
        // There's two (known) common cases where multiple producers can occur:
        //   1. When the output path of a script is platform independent. Since
        //      the index build description configures a target for all the
        //      platforms it supports within the same description, an output
        //      path that is platform-independent will end up the same for each
        //      configured platform. Given that the regular build is permissive
        //      with such script outputs, we should be permissive during an
        //      index prepare operation as well.
        //   2. A framework target has its product renamed to the same as
        //      another framework target's product. This duplicate tasks for
        //      the layout of the framework structure (mkdir and symlink),
        //      which all have the same inputs and outputs. For a project with
        //      modules enabled, the modulemap copy will also have a duplicate
        //      output (but separate input).
        //
        // For (1) we can recover by picking a producer an appropriate
        // configured target for the selected run destination. This will have
        // the same effect as if the user did a regular build of that target
        // for a particular platform.
        //
        // For (2) there's no "best" target to pick from.
        //
        // And more generally, there's likely cases we don't know about, as
        // well as the possibility of bugs that cause this type of error. In
        // the latter case we should obviously fix it, but it would be nice if
        // semantic functionality wasn't severely degraded in the meantime -
        // an error here stops index preparation, which is catastrophic for
        // semantic functionality in the editor.
        //
        // Instead of erroring here, do a best effort - recover by picking the
        // "best" configured target the way we normally do when choosing a
        // configured target for index settings (except that in this case it's
        // actually across targets).

        struct CommandInfo {
            let command: Command
            let task: any ExecutableTask
            let target: ConfiguredTarget
        }

        let cmdInfos: [CommandInfo] = commands.compactMap { command in
            guard let task = lookupTask(TaskIdentifier(command: command)),
                  let target = task.forTarget else { return nil }
            return CommandInfo(command: command, task: task, target: target)
        }

        guard cmdInfos.count == commands.count else {
            // We did not get expected info from all the producers, in order to do the condition check.
            return nil
        }

        // Make sure we're stable between runs and then pick the "best" target
        guard let selectedTarget = cmdInfos.map(\.target).sorted().one(by: {
            self.operation.requestContext.selectConfiguredTargetForIndex($0, $1, hasEnabledIndexBuildArena: true, runDestination: buildRequest.parameters.activeRunDestination)
        }) else {
            // This shouldn't actually be possible - `one` returns `nil` only
            // the initial array is empty, which it isn't.
            return nil
        }

        let childDiagnostics = cmdInfos.map({ info -> RuleInfoFormattable in
            return .task(info.task)
        }).richFormattedRuleInfo(workspace: workspace)

        self.buildOutputDelegate.emit(
            Diagnostic(behavior: .warning,
                       location: .unknown,
                       data: DiagnosticData("Multiple commands produce '\(output.key)', picked with target '\(selectedTarget.guid)'"),
                       childDiagnostics: childDiagnostics)
        )

        return cmdInfos.first(where: { $0.target === selectedTarget })?.command
    }

    func cannotBuildNodeDueToMultipleProducers(output: BuildKey, commands: [Command]) {
        let childDiagnostics = commands.map({ command -> RuleInfoFormattable in
            if let task = lookupTask(TaskIdentifier(command: command)) {
                return .task(task)
            } else {
                return .string(command.name)
            }
        }).richFormattedRuleInfo(workspace: workspace)
        self.buildOutputDelegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Multiple commands produce '\(output.key)'"), childDiagnostics: childDiagnostics))
    }

    func commandProcessStarted(_ command: Command, process: ProcessHandle) {
        // Intentionally left empty
    }

    func commandProcessHadError(_ command: Command, process: ProcessHandle, message: String) {
        queue.async {
            // FIXME: This shouldn't be optional, but it is until we always have an assigned delegate available.
            self.commandOutputDelegates[command]?.emitError(message)
        }
    }

    func commandProcessHadOutput(_ command: Command, process: ProcessHandle, data: [UInt8]) {
        queue.async {
            // FIXME: This shouldn't be optional, but it is until we always have an assigned delegate available.
            self.commandOutputDelegates[command]?.emitOutput(ByteString(data))
        }
    }

    func commandProcessFinished(_ command: Command, process: ProcessHandle, result: CommandExtendedResult) {
        if let task = lookupTask(TaskIdentifier(command: command)), result.result == .succeeded, result.exitStatus == 0 {
            if let spec = task.type as? CommandLineToolSpec, let files = task.dependencyData {
                do {
                    try spec.adjust(dependencyFiles: files, for: task, fs: operation.fs)
                } catch {
                    commandHadWarning(command, message: "Unable to perform dependency info modifications: \(error)")
                }
            }

            missingoutputs: do {
                // NOTE: We shouldn't enable this by default because some critical tasks declare outputs which they don't always produce (specifically CompileAssetCatalog and Assets.car, and CodeSign and _CodeSignature).
                if !SWBFeatureFlag.enableValidateDependenciesOutputs.value {
                    break missingoutputs
                }

                let level = operation.buildDescription.levelForDiagnosticMessagesForTaskInputsWithoutProducer(task: task)
                if level == .no || operation.buildDescription.bypassActualTasks {
                    break missingoutputs
                }

                for output in task.outputPaths where !operation.fs.exists(output) {
                    let message = "Declared but did not produce output: \(output.str)"
                    switch level {
                    case .yesError:
                        commandHadError(command, message: message, failedTaskSetup: true)
                    case .yes:
                        commandHadWarning(command, message: message)
                    case .no:
                        break
                    }
                }
            }
        }

        queue.async {
            // This may be updated by commandStarted in the case of certain failures,
            // so only update the exit status in output delegate if it is nil.
            if let delegate = self.commandOutputDelegates[command], delegate.result == nil {
                delegate.updateResult(.init(result))
            }
        }
    }

    private func backtraceFrameIdentifierForBuildKey(_ buildKey: BuildKey) -> BuildOperationBacktraceFrameEmitted.Identifier? {
        switch buildKey {
        case let buildKey as BuildKey.Command:
            return .task(BuildOperationTaskSignature.taskIdentifier(ByteString(encodingAsUTF8: buildKey.name)))
        case let buildKey as BuildKey.CustomTask:
            return .task(BuildOperationTaskSignature.taskIdentifier(ByteString(encodingAsUTF8: buildKey.name)))
        case is BuildKey.DirectoryContents,
             is BuildKey.FilteredDirectoryContents,
             is BuildKey.DirectoryTreeSignature,
             is BuildKey.DirectoryTreeStructureSignature,
             is BuildKey.Node,
             is BuildKey.Target,
             is BuildKey.Stat:
            return .genericBuildKey(buildKey.description)
        default:
            return nil
        }
    }

    private func descriptionForBuildKey(_ buildKey: BuildKey) -> String {
        switch buildKey {
        case let buildKey as BuildKey.Command:
            guard let task = lookupTask(TaskIdentifier(rawValue: buildKey.name)), let execDescription = task.execDescription else {
                return "<unknown command>"
            }
            return "'\(execDescription)'"
        case let buildKey as BuildKey.CustomTask:
            guard let task = lookupTask(TaskIdentifier(rawValue: buildKey.name)), let execDescription = task.execDescription else {
                return "<unknown custom task>"
            }
            return "'\(execDescription)'"
        case let directoryContents as BuildKey.DirectoryContents:
            return "contents of '\(directoryContents.path)'"
        case let filteredDirectoryContents as BuildKey.FilteredDirectoryContents:
            if filteredDirectoryContents.filters.isEmpty {
                return "contents of '\(filteredDirectoryContents.path)'"
            } else {
                return "contents of '\(filteredDirectoryContents.path)' filtered using '\(filteredDirectoryContents.filters)'"
            }
        case let directoryTreeSignature as BuildKey.DirectoryTreeSignature:
            if directoryTreeSignature.filters.isEmpty {
                return "signature of directory tree at '\(directoryTreeSignature.path)'"
            } else {
                return "signature of directory tree at '\(directoryTreeSignature.path)' filtered using '\(directoryTreeSignature.filters)'"
            }
        case let directoryTreeStructureSignature as BuildKey.DirectoryTreeStructureSignature:
            if directoryTreeStructureSignature.filters.isEmpty {
                return "signature of directory tree structure at '\(directoryTreeStructureSignature.path)'"
            } else {
                return "signature of directory tree structure at '\(directoryTreeStructureSignature.path)' filtered using '\(directoryTreeStructureSignature.filters)'"
            }
        case let node as BuildKey.Node:
            if isTriggerNode(buildKey) {
                return "<mutating task trigger>"
            } else {
                return "file '\(node.path)'"
            }
        case is BuildKey.Target:
            // A target key should never appear in a build backtrace
            return "<unexpected build key>"
        case is BuildKey.Stat:
            // SwiftBuild will never create stat keys
            return "<unexpected build key>"
        default:
            return "<unexpected build key>"
        }
    }

    private func isTriggerNode(_ buildKey: BuildKey) -> Bool {
        guard let node = buildKey as? BuildKey.Node, node.path.wholeMatch(of: #/<TRIGGER:.*>/#) != nil else {
            return false
        }
        return true
    }

    private func descriptionOfInputMutatedByBuildKey(_ buildKey: BuildKey) -> String? {
        guard let command = buildKey as? BuildKey.Command, let task = lookupTask(TaskIdentifier(rawValue: command.name)) else {
            return nil
        }
        let mutatedInputs = Set(task.inputPaths).intersection(Set(task.outputPaths))
        guard !mutatedInputs.isEmpty else {
            return nil
        }
        let sortedMutatedInputDescriptions = mutatedInputs.sorted().map { "'\($0.str)'" }
        switch sortedMutatedInputDescriptions.count {
        case 1:
            return sortedMutatedInputDescriptions.first
        case 2:
            return sortedMutatedInputDescriptions.joined(separator: " and ")
        default:
            return sortedMutatedInputDescriptions.dropLast().joined(separator: ", ") + ", and \(sortedMutatedInputDescriptions.last!)"
        }
    }

    private func inputNounPhraseForBuildKey(_ inputKey: BuildKey) -> String {
        switch inputKey {
        case is BuildKey.Command, is BuildKey.CustomTask:
            return "the producer"
        case is BuildKey.DirectoryContents, is BuildKey.FilteredDirectoryContents, is BuildKey.DirectoryTreeSignature, is BuildKey.Node:
            return "an input"
        case is BuildKey.Target, is BuildKey.Stat:
            return "<unexpected build key>"
        default:
            return "<unexpected build key>"
        }
    }

    private func rebuiltVerbPhraseForBuildKey(_ inputKey: BuildKey) -> String {
        switch inputKey {
        case is BuildKey.Command, is BuildKey.CustomTask:
            return "ran"
        case is BuildKey.DirectoryContents, is BuildKey.FilteredDirectoryContents, is BuildKey.DirectoryTreeSignature, is BuildKey.Node:
            return "changed"
        case is BuildKey.Target, is BuildKey.Stat:
            return "<unexpected build key>"
        default:
            return "<unexpected build key>"
        }
    }

    func determinedRuleNeedsToRun(_ rule: BuildKey, reason: RuleRunReason, inputRule: BuildKey?) {
        if operation.request.recordBuildBacktraces {
            guard let frameID = backtraceFrameIdentifierForBuildKey(rule) else {
                buildOutputDelegate.warning("failed to determine build backtrace frame ID for build key: \(rule.description)")
                return
            }
            let previousFrameID: BuildOperationBacktraceFrameEmitted.Identifier?
            let category: BuildOperationBacktraceFrameEmitted.Category
            var description: String
            switch reason {
            case .neverBuilt:
                category = .ruleNeverBuilt
                description = "\(descriptionForBuildKey(rule)) had never run"
                previousFrameID = nil
            case .signatureChanged:
                category = .ruleSignatureChanged
                description = "signature of \(descriptionForBuildKey(rule)) changed"
                previousFrameID = nil
            case .invalidValue:
                category = .ruleHadInvalidValue
                previousFrameID = nil
                if let command = rule as? BuildKey.Command, let task = lookupTask(TaskIdentifier(rawValue: command.name)), task.alwaysExecuteTask {
                    description = "\(descriptionForBuildKey(rule)) is configured to run in every incremental build"
                } else if rule is BuildKey.Command || rule is BuildKey.CustomTask {
                    description = "\(descriptionForBuildKey(rule)) did not have up-to-date outputs"
                } else {
                    description = "\(descriptionForBuildKey(rule)) changed"
                }
            case .inputRebuilt:
                category = .ruleInputRebuilt
                if let inputRule = inputRule, let previousFrameIdentifier = backtraceFrameIdentifierForBuildKey(inputRule) {
                    if isTriggerNode(rule), let mutatedNodeDescription = descriptionOfInputMutatedByBuildKey(inputRule) {
                        description = "\(descriptionForBuildKey(inputRule)) mutated \(mutatedNodeDescription)"
                    } else {
                        description = "\(inputNounPhraseForBuildKey(inputRule)) of \(descriptionForBuildKey(rule)) \(rebuiltVerbPhraseForBuildKey(inputRule))"
                    }
                    previousFrameID = previousFrameIdentifier
                } else {
                    description = "an unknown input of \(descriptionForBuildKey(rule)) changed"
                    previousFrameID = nil
                }
            case .forced:
                category = .ruleForced
                description = "\(descriptionForBuildKey(rule)) was forced to run"
                previousFrameID = nil
            @unknown default:
                category = .none
                description = "\(descriptionForBuildKey(rule)) ran for an unknown reason"
                previousFrameID = nil
            }
            let kind: BuildOperationBacktraceFrameEmitted.Kind
            switch rule {
            case is BuildKey.Command, is BuildKey.CustomTask:
                kind = .genericTask
            case is BuildKey.DirectoryContents, is BuildKey.FilteredDirectoryContents, is BuildKey.DirectoryTreeSignature, is BuildKey.DirectoryTreeStructureSignature:
                kind = .directory
            case is BuildKey.Node:
                kind = .file
            default:
                kind = .unknown
            }

            self.operation.delegate.recordBuildBacktraceFrame(identifier: frameID, previousFrameIdentifier: previousFrameID, category: category, kind: kind, description: description)
        }
    }

    func cycleDetected(rules: [BuildKey]) {
        let formatter = DependencyCycleFormatter(buildDescription: description, buildRequest: operation.request, rules: rules, workspace: workspace, dynamicTaskContext: dynamicOperationContext)
        let message = formatter.formattedMessage() + "\n\n\n" + formatter.llbuildFormattedCycle()

        queue.async {
            self.buildOutputDelegate.error(message)
        }
    }

    func shouldResolveCycle(rules: [BuildKey], candidate: BuildKey, action: CycleAction) -> Bool {
        if SWBUtil.UserDefaults.attemptDependencyCycleResolution {
            let message = DependencyCycleFormatter(buildDescription: description, buildRequest: operation.request, rules: rules, workspace: workspace, dynamicTaskContext: dynamicOperationContext).formattedCycleResolutionMessage(candidateRule: candidate, action: action)

            queue.async {
                self.buildOutputDelegate.warning(message)
            }
            return true
        }
        return false
    }
}

extension OperationSystemAdaptor: SubtaskProgressReporter {

    func subtasksScanning(count: Int, forTargetName targetName: String?) {
        self.queue.async {
            // This callback can be scheduled *after* the adaptor has been
            // completed, we must take care not to do anything in that case.
            guard !self.isCompleted else { return }

            self._progressStatistics.numCommandsScanned += count
            self._progressStatistics.numCommandsActivelyScanning += count
            self.operation.delegate.totalCommandProgressChanged(self.operation, forTargetName: targetName, statistics: self._progressStatistics)
        }
    }

    func subtasksSkipped(count: Int, forTargetName targetName: String?) {
        self.queue.async {
            // This callback can be scheduled *after* the adaptor has been
            // completed, we must take care not to do anything in that case.
            guard !self.isCompleted else { return }

            self._progressStatistics.numCommandsUpToDate += count
            self._progressStatistics.numCommandsActivelyScanning -= count
            self._progressStatistics.numCommandsCompleted += count
            self.operation.delegate.totalCommandProgressChanged(self.operation, forTargetName: targetName, statistics: self._progressStatistics)
        }
    }

    func subtasksStarted(count: Int, forTargetName targetName: String?) {
        self.queue.async {
            // This callback can be scheduled *after* the adaptor has been
            // completed, we must take care not to do anything in that case.
            guard !self.isCompleted else { return }

            self._progressStatistics.numCommandsStarted += count
            self.operation.delegate.totalCommandProgressChanged(self.operation, forTargetName: targetName, statistics: self._progressStatistics)
        }
    }

    func subtasksFinished(count: Int, forTargetName targetName: String?) {
        self.queue.async {
            // This callback can be scheduled *after* the adaptor has been
            // completed, we must take care not to do anything in that case.
            guard !self.isCompleted else { return }

            self._progressStatistics.numCommandsActivelyScanning -= count
            self._progressStatistics.numCommandsCompleted += count
            self.operation.delegate.totalCommandProgressChanged(self.operation, forTargetName: targetName, statistics: self._progressStatistics)
        }
    }
}

private func ==<K, V>(lhs: [K: V]?, rhs: [K: V]?) -> Bool {
    switch (lhs, rhs) {
    case (let lhs?, let rhs?):
        return lhs == rhs
    case (nil, nil):
        return true
    default:
        return false
    }
}

extension TaskIdentifier {
    init(command: Command) {
        self.init(rawValue: command.name)
    }
}
