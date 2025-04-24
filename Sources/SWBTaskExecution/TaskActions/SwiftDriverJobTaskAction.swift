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

import Foundation

public import SWBCore
public import SWBUtil
public import SWBLLBuild
import SWBProtocol

public final class SwiftDriverJobTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        "swift-driver-job-execution"
    }

    private struct Options {
        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate) {
            outputDelegate.emitOutput { stream in
                stream <<< "usage: \(name) -- <swift_frontend_args>\n"
            }
        }

        let commandLine: [String]

        init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate) {
            var parsedCommandLine = [String]()

            var hadErrors = false

            func error(_ message: String) {
                outputDelegate.emitError(message)
                hadErrors = true
            }

            // Parse the arguments.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"

            var foundCommandLine = false

            while let arg = generator.next() {
                if foundCommandLine {
                    parsedCommandLine.append(arg)
                    continue
                }

                switch arg {
                case "--":
                    foundCommandLine = true
                    continue
                default:
                    error("unexpected argument: \(arg)")
                    break
                }
            }

            if parsedCommandLine.isEmpty {
                error("No commandline for Swift driver job given.")
            }

            if !hadErrors {
                self.commandLine = parsedCommandLine
            } else {
                // If there were errors, emit the usage and return an error.
                outputDelegate.emitOutput("\n")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }
        }
    }

    public enum SwiftDriverJobIdentifier: Serializable {
        case explicitDependency
        case targetCompile(_ identifier: String)

        public func serialize<T>(to serializer: T) where T : Serializer {
            serializer.beginAggregate(2)
            switch self {
                case .explicitDependency:
                    serializer.serialize(0)
                    serializer.serializeNil()
                case .targetCompile(let identifier):
                    serializer.serialize(1)
                    serializer.serialize(identifier)
            }
            serializer.endAggregate()
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            let code: Int = try deserializer.deserialize()
            switch code {
                case 0:
                    guard deserializer.deserializeNil() else { throw DeserializerError.deserializationFailed("Unexpected associated value for SwiftDriverJobIdentifier.") }
                    self = .explicitDependency
                case 1:
                    let string: String = try deserializer.deserialize()
                    self = .targetCompile(string)
                default:
                    throw DeserializerError.incorrectType("Unexpected type code for SwiftDriverJobIdentifier: \(code)")
            }
        }
    }

    let identifier: SwiftDriverJobIdentifier
    let variant: String?
    let arch: String
    let driverJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob
    let isUsingWholeModuleOptimization: Bool

    init(_ driverJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob, variant: String?, arch: String, identifier: SwiftDriverJobIdentifier, isUsingWholeModuleOptimization: Bool) {
        self.driverJob = driverJob
        self.variant = variant
        self.arch = arch
        self.identifier = identifier
        self.isUsingWholeModuleOptimization = isUsingWholeModuleOptimization
        super.init()
    }

    public override func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(6) {
            serializer.serialize(driverJob)
            serializer.serialize(variant)
            serializer.serialize(arch)
            serializer.serialize(identifier)
            serializer.serialize(isUsingWholeModuleOptimization)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(6)
        self.driverJob = try deserializer.deserialize()
        self.variant = try deserializer.deserialize()
        self.arch = try deserializer.deserialize()
        self.identifier = try deserializer.deserialize()
        self.isUsingWholeModuleOptimization = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    private struct State {
        var openDependencies: Set<UInt> = []
        var inputNodesRequested = false
        var cacheJobRequested = false
        var jobTaskIDBase: UInt = 0

        var executionError: String? = nil
        var jobDependencyFailed = false

        mutating func reset() {
            self = State()
        }
    }

    private var state = State()

    public override func getSignature(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate) -> ByteString {
        let md5 = InsecureHashContext()
        // We intentionally do not integrate the superclass signature here, because the driver job's signature captures the same information without requiring expensive serialization.
        md5.add(bytes: driverJob.driverJob.signature)
        task.environment.computeSignature(into: md5)
        return md5.signature
    }

    private func requestCacheJobIfNecessary(_ task: any ExecutableTask, _ dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) throws {
        guard state.cacheJobRequested == false else { return }
        guard let payload = task.payload as? SwiftDriverJobDynamicTaskPayload else {
            fatalError("Unexpected payload type: \(type(of: task.payload)).")
        }
        let taskID = state.jobTaskIDBase
        if try Self.maybeRequestCachingKeyMaterialization(plannedJob: driverJob,
                                                          dynamicExecutionDelegate: dynamicExecutionDelegate,
                                                          casOptions: payload.casOptions,
                                                          compilerLocation: payload.compilerLocation,
                                                          taskID: taskID) {
            state.openDependencies.insert(taskID)
        }
        state.cacheJobRequested = true
    }

    private func requestInputNodesIfNecessary(_ task: any ExecutableTask, _ dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        guard state.inputNodesRequested == false else { return }
        if state.openDependencies.isEmpty {
            for (index, input) in (task.executionInputs ?? []).enumerated() {
                // rdar://82078120 pch input has wrong name, will fail build with missingInput
                if Path(input.identifier).fileExtension == "pch" { continue }
                dynamicExecutionDelegate.requestInputNode(node: input, nodeID: state.jobTaskIDBase + 1 + UInt(index))
            }
            state.inputNodesRequested = true
        }
    }

    internal func constructDriverJobTaskKey(variant: String?,
                                            arch: String,
                                            plannedJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob,
                                            identifier: String?,
                                            compilerLocation: LibSwiftDriver.CompilerLocation,
                                            casOptions: CASOptions?) -> DynamicTaskKey {
        let key: DynamicTaskKey
        if plannedJob.driverJob.categorizer.isExplicitDependencyBuild {
            key = .swiftDriverExplicitDependencyJob(SwiftDriverExplicitDependencyJobTaskKey(
                arch: arch,
                driverJobKey: plannedJob.key,
                driverJobSignature: plannedJob.driverJob.signature,
                compilerLocation: compilerLocation,
                casOptions: casOptions))
        } else {
            guard let variant else {
                fatalError("Expected variant for non-explicit-module job: \(plannedJob.driverJob.descriptionForLifecycle)")
            }
            guard let jobID = identifier else {
                fatalError("Expected job identifier for target compile: \(plannedJob.driverJob.descriptionForLifecycle)")
            }
            key = .swiftDriverJob(SwiftDriverJobTaskKey(
                identifier: jobID,
                variant: variant,
                arch: arch,
                driverJobKey: plannedJob.key,
                driverJobSignature: plannedJob.driverJob.signature,
                isUsingWholeModuleOptimization: isUsingWholeModuleOptimization,
                compilerLocation: compilerLocation,
                casOptions: casOptions))
        }
        return key
    }

    public override func taskSetup(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        state.reset()

        guard let payload = task.payload as? SwiftDriverJobDynamicTaskPayload else {
            fatalError("Unexpected payload type: \(type(of: task.payload)).")
        }

        do {
            let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
            let jobDependencies: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob]
            var jobID: String? = nil
            switch self.identifier {
                case .targetCompile(let identifierStr):
                    let plannedBuild = try graph.queryPlannedBuild(for: identifierStr)
                    jobDependencies = plannedBuild.dependencies(for: driverJob)
                    jobID = identifierStr
                case .explicitDependency:
                    guard let explicitBuildJob = graph.plannedExplicitDependencyBuildJob(for: self.driverJob.key) else {
                        state.executionError = "Could not query build containing explicit dependency build job: \(self.driverJob.driverJob.descriptionForLifecycle)"
                        return
                    }
                    jobDependencies = graph.explicitDependencies(for: explicitBuildJob)
            }

            let jobTaskIDBase = UInt((task.executionInputs ?? []).count)
            // For each depended-upon job, request a dynamic task.
            for (index, dependency) in jobDependencies.enumerated() {
                let isExplicitDependencyBuildJob = dependency.driverJob.categorizer.isExplicitDependencyBuild
                let taskKey = constructDriverJobTaskKey(variant: variant,
                                                        arch: arch,
                                                        plannedJob: dependency,
                                                        identifier: jobID,
                                                        compilerLocation: payload.compilerLocation,
                                                        casOptions: payload.casOptions)
                let taskID = jobTaskIDBase + UInt(index)
                state.openDependencies.insert(taskID)
                dynamicExecutionDelegate.requestDynamicTask(
                    toolIdentifier: SwiftDriverJobTaskAction.toolIdentifier,
                    taskKey: taskKey,
                    taskID: taskID,
                    singleUse: true,
                    workingDirectory: dependency.workingDirectory,
                    environment: task.environment,
                    forTarget: isExplicitDependencyBuildJob ? nil : task.forTarget,
                    priority: dependency.driverJob.categorizer.priority,
                    showEnvironment: task.showEnvironment,
                    reason: .wasScheduledBySwiftDriver
                )
            }
            state.jobTaskIDBase = jobTaskIDBase + UInt(jobDependencies.count)
            try requestCacheJobIfNecessary(task, dynamicExecutionDelegate)
            requestInputNodesIfNecessary(task, dynamicExecutionDelegate)
        } catch {
            state.executionError = error.localizedDescription
        }
    }

    private func isError(_ dependencyID: UInt, buildValueKind: BuildValueKind?, task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) -> Bool {
        guard let buildValueKind else {
            return true
        }

        guard buildValueKind.isFailed else {
            return false
        }

        do {
            let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
            let jobDependencies: [LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob]
            switch self.identifier {
                case .targetCompile(let identifier):
                    let plannedBuild = try graph.queryPlannedBuild(for: identifier)
                    jobDependencies = plannedBuild.dependencies(for: driverJob)
                case .explicitDependency:
                    jobDependencies = graph.explicitDependencies(for: driverJob)
            }

            let dependencyIdentifier = Int(dependencyID)
            if jobDependencies.indices.contains(dependencyIdentifier) {
                state.jobDependencyFailed = true
            } else {
                state.executionError = "Input \(driverJob.driverJob.inputs[safe: dependencyIdentifier - jobDependencies.count]?.str ?? "<unknown>") missing."
            }
        } catch {
            state.executionError = error.localizedDescription
        }
        return true
    }

    public override func taskDependencyReady(_ task: any ExecutableTask, _ dependencyID: UInt, _ buildValueKind: BuildValueKind?, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate) {
        state.openDependencies.remove(dependencyID)

        if isError(dependencyID, buildValueKind: buildValueKind, task: task, dynamicExecutionDelegate: dynamicExecutionDelegate) && !dynamicExecutionDelegate.continueBuildingAfterErrors {
            // Unless we want to continue building after errors, clear open dependencies to minimize cascading failures.
            state.openDependencies.removeAll()
            return
        }

        requestInputNodesIfNecessary(task, dynamicExecutionDelegate)
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        // A dynamically planned driver job should always execute
        return false
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {

        var plannedBuild: LibSwiftDriver.PlannedBuild?
        // Explicit dependency build jobs do not update the delegate's (driver's)
        // state (incl. incremental), so we do not require access to their planned build.
        switch self.identifier {
            case .targetCompile(let identifier):
                do {
                    let graph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
                    plannedBuild = try graph.queryPlannedBuild(for: identifier)
                } catch {
                    state.executionError = "Unable to get planned build for identifier \(identifier): \(error.localizedDescription)"
                }
            case .explicitDependency:
                break
        }

        defer {
            state.reset()
        }

        if let error = state.executionError {
            outputDelegate.emitError(error)
            return .failed
        }

        if state.jobDependencyFailed {
            return .cancelled
        }

        guard let options = Options(task.commandLineAsStrings, outputDelegate) else {
            return .failed
        }

        func emitCommandLine() {
            let commandString = UNIXShellCommandCodec(
                encodingStrategy: .backslashes,
                encodingBehavior: .fullCommandLine
            ).encode(options.commandLine)

            // <rdar://59354519> We need to find a way to use the generic infrastructure for displaying the command line in
            // the build log.
            outputDelegate.emitOutput(ByteString(encodingAsUTF8: commandString) + "\n")
        }

        if executionDelegate.userPreferences.enableDebugActivityLogs || executionDelegate.emitFrontendCommandLines {
            emitCommandLine()
        }

        var environment: [String: String]
        // FIXME: clean up environment for caching build.
        if let executionEnvironment = executionDelegate.environment {
            environment = executionEnvironment.merging(task.environment.bindingsDictionary, uniquingKeysWith: { a, b in b })

            // FIXME: rdar://134664046 (Add an EnvironmentBlock type to represent environment variables)
            #if os(Windows)
            if let value = environment.removeValue(forKey: "PATH") {
                environment["Path"] = value
            }
            #endif
        } else {
            environment = task.environment.bindingsDictionary
        }

        guard let payload = task.payload as? SwiftDriverJobDynamicTaskPayload else {
            fatalError("Unexpected payload type: \(type(of: task.payload)).")
        }

        do {
            class OutputCapturingDelegate: ProcessDelegate {
                let plannedBuild: LibSwiftDriver.PlannedBuild?
                let driverJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob
                let arguments: [String]
                let environment: [String : String]
                let outputDelegate: any TaskOutputDelegate

                private(set) var output: ByteString = ""
                private var pid = llbuild_pid_t.invalid

                var executionError: String?
                private var processStarted = false
                private var _commandResult: CommandResult?
                var commandResult: CommandResult? {
                    guard processStarted else {
                        return .cancelled
                    }
                    return _commandResult
                }

                init(plannedBuild: LibSwiftDriver.PlannedBuild?, driverJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob, arguments: [String], environment: [String : String], outputDelegate: any TaskOutputDelegate) {
                    self.plannedBuild = plannedBuild
                    self.driverJob = driverJob
                    self.arguments = arguments
                    self.environment = environment
                    self.outputDelegate = outputDelegate
                }

                func processStarted(pid: llbuild_pid_t?) {
                    processStarted = true
                    do {
                        guard let pid else {
                            // `pid` is only optional because the Windows implementation of llbuild's pid_t type is optional. This should never be nil on other platforms
                            throw StubError.error("Got no process identifier from spawning subprocess for \(self.driverJob.description).")
                        }
                        self.pid = pid
                        try plannedBuild?.jobStarted(job: driverJob, arguments: arguments, pid: pid.pid)
                    } catch {
                        executionError = error.localizedDescription
                    }
                }

                func processHadError(error: String) {
                    executionError = error
                }

                func processHadOutput(output: [UInt8]) {
                    let bytes = ByteString(output)
                    self.output += bytes
                    outputDelegate.emitOutput(bytes)
                }

                // Kept for compatibility with older versions of llbuild. Remove once rdar://97019909 is widely available.
                func processHadOutput(output: String) {
                    let bytes = ByteString(encodingAsUTF8: output)
                    self.output += bytes
                    outputDelegate.emitOutput(bytes)
                }

                func processFinished(result: CommandExtendedResult) {
                    // This may be updated by commandStarted in the case of certain failures,
                    // so only update the exit status in output delegate if it is nil.
                    if outputDelegate.result == nil {
                        outputDelegate.updateResult(TaskResult(result))
                    }
                    self._commandResult = result.result
                    do {
                        try plannedBuild?.jobFinished(job: driverJob, arguments: arguments, pid: pid.pid, environment: environment, exitStatus: .exit(result.exitStatus), output: output)
                    } catch {
                        executionError = error.localizedDescription
                    }
                }
            }

            // rdar://70881411 track dynamic jobs' outputs in llbuild
            for output in self.driverJob.driverJob.outputs {
                try? executionDelegate.fs.createDirectory(output.dirname, recursive: true)
            }

            let delegate = OutputCapturingDelegate(plannedBuild: plannedBuild, driverJob: driverJob, arguments: options.commandLine, environment: environment, outputDelegate: outputDelegate)

            let cas: SwiftCASDatabases?
            if let casOpts = payload.casOptions, casOpts.enableIntegratedCacheQueries {
                let swiftModuleDependencyGraph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
                cas = try swiftModuleDependencyGraph.getCASDatabases(casOptions: casOpts, compilerLocation: payload.compilerLocation)

                let casKey = ClangCachingPruneDataTaskKey(
                    path: payload.compilerLocation.compilerOrLibraryPath,
                    casOptions: casOpts
                )
                dynamicExecutionDelegate.operationContext.compilationCachingDataPruner.pruneCAS(
                    cas!,
                    key: casKey,
                    activityReporter: dynamicExecutionDelegate,
                    fileSystem: executionDelegate.fs
                )
            } else {
                cas = nil
            }

            if let db = cas,
               let casOpts = payload.casOptions,
               try await Self.replayCachedCommand(cas: db,
                                                  plannedJob: driverJob,
                                                  commandLine: options.commandLine,
                                                  dynamicExecutionDelegate: dynamicExecutionDelegate,
                                                  outputDelegate: outputDelegate,
                                                  enableDiagnosticRemarks: casOpts.enableDiagnosticRemarks) {
                    return .succeeded
            }

            try await spawn(commandLine: options.commandLine, environment: environment, workingDirectory: task.workingDirectory.str, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: delegate)

            if let error = delegate.executionError {
                outputDelegate.error(error)
                return .failed
            }
            // If has remote cache, start uploading task.
            if let db = cas, let casOpts = payload.casOptions, casOpts.hasRemoteCache, delegate.commandResult == .succeeded {
                // upload only if succeed
                try Self.upload(cas: db,
                                plannedJob: driverJob,
                                dynamicExecutionDelegate: dynamicExecutionDelegate,
                                outputDelegate: outputDelegate,
                                enableDiagnosticRemarks: casOpts.enableDiagnosticRemarks,
                                enableStrictCASErrors: casOpts.enableStrictCASErrors)
            }

            if delegate.commandResult == .failed && !executionDelegate.userPreferences.enableDebugActivityLogs && !executionDelegate.emitFrontendCommandLines {
                outputDelegate.emitOutput("Failed frontend command:\n")
                emitCommandLine()
            }

            return delegate.commandResult ?? .failed
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }
    }

    /// Intended to be called during task dependency setup.
    /// If remote caching is enabled along with integrated cache queries, it will request
    /// a `SwiftCachingMaterializeKeyTaskAction` as task dependency.
    static func maybeRequestCachingKeyMaterialization(
        plannedJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        casOptions: CASOptions?,
        compilerLocation: LibSwiftDriver.CompilerLocation,
        taskID: UInt
    ) throws -> Bool {
        guard let casOptions,
              casOptions.enableIntegratedCacheQueries,
              casOptions.hasRemoteCache else {
            return false
        }
        let cacheQueryKey = SwiftCachingKeyQueryTaskKey(casOptions: casOptions, cacheKeys: plannedJob.driverJob.cacheKeys, compilerLocation: compilerLocation)
        dynamicExecutionDelegate.requestDynamicTask(
            toolIdentifier: SwiftCachingMaterializeKeyTaskAction.toolIdentifier,
            taskKey: .swiftCachingMaterializeKey(cacheQueryKey),
            taskID: taskID,
            singleUse: true,
            workingDirectory: Path(""),
            environment: .init(),
            forTarget: nil,
            priority: .network,
            showEnvironment: false,
            reason: .wasCompilationCachingQuery)
        return true
    }

    /// Attempts to replay a previously cached compilation, using data from the local CAS.
    ///
    /// - Returns: `true` if the the cached compilation outputs were found and replayed, `false` otherwise.
    static func replayCachedCommand(cas: SwiftCASDatabases,
                                    plannedJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob,
                                    commandLine: [String],
                                    dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
                                    outputDelegate: any TaskOutputDelegate,
                                    enableDiagnosticRemarks: Bool
    ) async throws -> Bool {
        let cacheKeys = plannedJob.driverJob.cacheKeys
        guard !cacheKeys.isEmpty else { return false }

        func replayCachedCommandImpl() async throws -> Bool {
            // Query cache key.
            var comps: [SwiftCachedCompilation] = []
            for cacheKey in cacheKeys {
                // If any of the key misses, return cache miss.
                guard let comp = try cas.queryLocalCacheKey(cacheKey) else {
                    if enableDiagnosticRemarks {
                        outputDelegate.note("local cache miss for key: \(cacheKey)")
                    }
                    return false
                }
                if enableDiagnosticRemarks {
                    outputDelegate.note("local cache found for key: \(cacheKey)")
                }
                // Check all outputs are materialized.
                // Doing the check immediately after the key allows associating the output remarks with the right key.
                for output in try comp.getOutputs() {
                    if !output.isMaterialized {
                        if enableDiagnosticRemarks {
                            outputDelegate.note("cached output \(output.kindName) not available locally: \(output.casID)")
                        }
                        return false
                    }
                    if enableDiagnosticRemarks {
                        outputDelegate.note("using CAS output \(output.kindName): \(output.casID)")
                    }
                }
                comps.append(comp)
            }

            // Replay after all checks are done.
            let instance = try cas.createReplayInstance(cmd: Array(commandLine.dropFirst(1))) // drop executable name
            let replayResults: [Result<SwiftCacheReplayResult, any Error>] = await comps.concurrentMap(maximumParallelism: 10) { comp in
                do {
                    return .success(try cas.replayCompilation(instance: instance, compilation: comp))
                } catch {
                    return .failure(error)
                }
            }
            for replayResult in replayResults {
                let result = try replayResult.get()
                // emit stdout/stderr
                outputDelegate.emitOutput(ByteString(encodingAsUTF8: try result.getStdOut()))
                outputDelegate.emitOutput(ByteString(encodingAsUTF8: try result.getStdErr()))
            }
            return true
        }

        let result = try await replayCachedCommandImpl()
        if enableDiagnosticRemarks {
            outputDelegate.note("replay cache \(result ? "hit" : "miss")")
        }
        if result {
            outputDelegate.incrementSwiftCacheHit()
            outputDelegate.incrementTaskCounter(.cacheHits)
            outputDelegate.emitOutput("Cache hit\n")
        } else {
            outputDelegate.incrementSwiftCacheMiss()
            outputDelegate.incrementTaskCounter(.cacheMisses)
            outputDelegate.emitOutput("Cache miss\n")
        }
        return result
    }

    static func upload(cas: SwiftCASDatabases,
                       plannedJob: LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob,
                       dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
                       outputDelegate: any TaskOutputDelegate,
                       enableDiagnosticRemarks: Bool,
                       enableStrictCASErrors: Bool
    ) throws {
        let cacheKeys = plannedJob.driverJob.cacheKeys
        guard !cacheKeys.isEmpty else { return }

        let comps = try cacheKeys.compactMap { cacheKey -> (String, SwiftCachedCompilation)? in
            guard let cachedComp = try cas.queryLocalCacheKey(cacheKey) else {
                // This should not happen for swiftlang. Issue an warning.
                outputDelegate.warning("compilation was not cached for key: \(cacheKey)")
                return nil
            }
            return (cacheKey, cachedComp)
        }
        for (cacheKey, cachedComp) in comps {
            dynamicExecutionDelegate.operationContext.compilationCachingUploader.upload(
                swiftCompilation: cachedComp,
                cacheKey: cacheKey,
                enableDiagnosticRemarks: enableDiagnosticRemarks,
                enableStrictCASErrors: enableStrictCASErrors,
                activityReporter: dynamicExecutionDelegate)
        }
    }
}
