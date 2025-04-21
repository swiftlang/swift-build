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

import SWBUtil
import SWBLibc
public import SWBCore
public import SWBLLBuild
import Foundation
import SWBProtocol

public final class ClangCompileTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        return "ccompile"
    }

    private struct State {
        var executionError: (any Error)? = nil

        var failedDependencies = false

        /// Unfinished execution inputs; `nil` means all finished
        var openExecutionInputIDs: Set<UInt>? = nil
        var dynamicTaskBaseID: UInt = 0

        mutating func reset() {
            self = State()
        }
    }

    private var state = State()

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        fatalError("Unexpectedly called the old version of isResultValid")
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue, fallback: (BuildValue) -> Bool) -> Bool {
        // Artifacts of some compile tasks refer to CAS objects. Let's check those too to be exhaustive.
        fallback(buildValue) && areCASResultsValid(task, operationContext)
    }

    private func areCASResultsValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext) -> Bool {
        guard let clangPayload = task.payload as? ClangTaskPayload, let explicitModulesPayload = clangPayload.explicitModulesPayload else {
            return true
        }

        guard let casOptions = explicitModulesPayload.casOptions else {
            return true
        }

        guard let casDBs = try? operationContext.clangModuleDependencyGraph.getCASDatabases(libclangPath: explicitModulesPayload.libclangPath, casOptions: casOptions) else {
            return false
        }

        // Precompiled header takes the CAS outputs of PrecompileClangModuleTaskAction tasks and refers to them, essentially adopting them as its own outputs. Let's check if they are still materialized.
        // Moreover, if the CAS outputs of some PrecompileClangModuleTaskAction task disappear, that task won't be able to report its results as invalid unless this task does so first.
        if !(task.ruleInfo[safe: 0] == "ProcessPCH" || task.ruleInfo[safe: 0] == "ProcessPCH++") {
            return true
        }

        guard let dependencyInfo = try? operationContext.clangModuleDependencyGraph.queryDependencies(at: explicitModulesPayload.scanningOutputPath, fileSystem: localFS) else {
            return false
        }

        for cacheKey in dependencyInfo.transitiveCompileCommandCacheKeys {
            // FIXME: Deduplicate the loop body amongst all ClangCompileTaskAction.

            guard let compilation = try? casDBs.getLocalCachedCompilation(cacheKey: cacheKey) else {
                return false
            }

            for output in compilation.getOutputs() {
                if !compilation.isOutputMaterialized(output) {
                    return false
                }
            }
        }

        return true
    }

    public override func taskSetup(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        state.reset()

        if let executionInputs = task.executionInputs {
            state.openExecutionInputIDs = Set(executionInputs.indices.map(UInt.init))
            state.dynamicTaskBaseID = UInt(executionInputs.count)
            // The execution inputs will be provided to `taskDependencyReady`, they don't need to be requested.
        }

    }

    public override func taskDependencyReady(_ task: any ExecutableTask, _ dependencyID: UInt, _ buildValueKind: BuildValueKind?, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate) {

        guard let payload = task.payload as? ClangTaskPayload, let explicitModulesPayload = payload.explicitModulesPayload else {
            state.executionError = StubError.error("invalid payload for explicit module support")
            return
        }

        guard let buildValueKind, !buildValueKind.isFailed else {
            state.failedDependencies = true
            return
        }

        guard state.openExecutionInputIDs != nil else {
            return
        }
        state.openExecutionInputIDs?.remove(dependencyID)
        guard state.openExecutionInputIDs?.isEmpty == true else {
            return
        }
        state.openExecutionInputIDs = nil

        // Scan modules task is complete, ClangModuleDependencyGraph should have the dependencies for the source
        // being compiled by this task.
        let clangModuleDependencyGraph = dynamicExecutionDelegate.operationContext.clangModuleDependencyGraph

        let dependencyInfo: ClangModuleDependencyGraph.DependencyInfo
        do {
            dependencyInfo = try clangModuleDependencyGraph.queryDependencies(at: explicitModulesPayload.scanningOutputPath, fileSystem: executionDelegate.fs)
        } catch {
            state.executionError = error
            return
        }

        for module in dependencyInfo.modules {
            let precompileModuleTaskKey = PrecompileClangModuleTaskKey(
                dependencyInfoPath: Path(module.withoutSuffix + ".scan"),
                usesSerializedDiagnostics: dependencyInfo.usesSerializedDiagnostics,
                libclangPath: explicitModulesPayload.libclangPath,
                casOptions: explicitModulesPayload.casOptions,
                verifyingModule: explicitModulesPayload.verifyingModule,
                fileNameMapPath: payload.fileNameMapPath
            )

            dynamicExecutionDelegate.requestDynamicTask(
                toolIdentifier: PrecompileClangModuleTaskAction.toolIdentifier,
                taskKey: .precompileClangModule(precompileModuleTaskKey),
                taskID: state.dynamicTaskBaseID,
                singleUse: true,
                workingDirectory: Path.root,
                environment: task.environment,
                forTarget: nil,
                priority: .preferred,
                showEnvironment: task.showEnvironment,
                reason: .wasScannedClangModuleDependency(of: explicitModulesPayload.sourcePath.str)
            )
            state.dynamicTaskBaseID += 1
        }

        do {
            try Self.maybeRequestCachingKeyMaterialization(
                dependencyInfo: dependencyInfo,
                dynamicExecutionDelegate: dynamicExecutionDelegate,
                libclangPath: explicitModulesPayload.libclangPath,
                casOptions: explicitModulesPayload.casOptions,
                taskID: &state.dynamicTaskBaseID
            )
        } catch {
            state.executionError = error
            return
        }
    }

   override public func performTaskAction(
    _ task: any ExecutableTask,
    dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
    clientDelegate: any TaskExecutionClientDelegate,
    outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        defer {
            if let error = state.executionError {
                outputDelegate.error(error.localizedDescription)
            }
            state.reset()
        }

        guard let explicitModulesPayload = (task.payload as? ClangTaskPayload)?.explicitModulesPayload else {
            state.executionError = StubError.error("invalid payload for explicit module support")
            return .failed
        }

        if state.executionError != nil {
            return .failed
        }

        if state.failedDependencies {
            return .cancelled
        }

        if executionDelegate.userPreferences.enableDebugActivityLogs {
            outputDelegate.emitNote("Using in-process compilation task.")
        }

        let clangModuleDependencyGraph = dynamicExecutionDelegate.operationContext.clangModuleDependencyGraph
        let dependencyInfo: ClangModuleDependencyGraph.DependencyInfo
        do {
            dependencyInfo = try clangModuleDependencyGraph.queryDependencies(at: explicitModulesPayload.scanningOutputPath, fileSystem: executionDelegate.fs)
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }

        let commandLines = dependencyInfo.commands.map{$0.arguments}

        // By default, don't print the frontend command lines, to avoid introducing too much noise in the log.
        if executionDelegate.userPreferences.enableDebugActivityLogs || executionDelegate.emitFrontendCommandLines {
            for commandLine in commandLines {
                let commandString = UNIXShellCommandCodec(
                    encodingStrategy: .backslashes,
                    encodingBehavior: .fullCommandLine
                ).encode(commandLine)

                // <rdar://59354519> We need to find a way to use the generic infrastructure for displaying the command line in
                // the build log.
                outputDelegate.emitOutput(ByteString(encodingAsUTF8: commandString) + "\n")
            }
        }

        do {
            let casDBs: ClangCASDatabases?
            if let casOptions = explicitModulesPayload.casOptions, casOptions.enableIntegratedCacheQueries {
                casDBs = try clangModuleDependencyGraph.getCASDatabases(
                    libclangPath: explicitModulesPayload.libclangPath,
                    casOptions: casOptions
                )

                let casKey = ClangCachingPruneDataTaskKey(
                    path: explicitModulesPayload.libclangPath,
                    casOptions: casOptions
                )
                dynamicExecutionDelegate.operationContext.compilationCachingDataPruner.pruneCAS(
                    casDBs!,
                    key: casKey,
                    activityReporter: dynamicExecutionDelegate,
                    fileSystem: executionDelegate.fs
                )
            } else {
                casDBs = nil
            }

            var lastResult: CommandResult? = nil
            for command in dependencyInfo.commands {
                if let casDBs {
                    if try Self.replayCachedCommand(
                        command,
                        casDBs: casDBs,
                        workingDirectory: task.workingDirectory,
                        outputDelegate: outputDelegate,
                        enableDiagnosticRemarks: explicitModulesPayload.casOptions!.enableDiagnosticRemarks
                    ) {
                        lastResult = .succeeded
                        continue
                    }
                }

                let commandLine = command.arguments
                let delegate = TaskProcessDelegate(outputDelegate: outputDelegate)
                // The frontend invocations should be unaffected by the environment, pass an empty one.
                try await spawn(commandLine: commandLine, environment: [:], workingDirectory: task.workingDirectory.str, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: delegate)
                lastResult = delegate.commandResult

                if lastResult == .succeeded {
                    if let casDBs, explicitModulesPayload.casOptions!.hasRemoteCache {
                        guard let cacheKey = command.cacheKey else {
                            throw StubError.error("missing cache key")
                        }
                        try await Self.upload(
                            cacheKey: cacheKey,
                            casDBs: casDBs,
                            dynamicExecutionDelegate: dynamicExecutionDelegate,
                            outputDelegate: outputDelegate,
                            enableDiagnosticRemarks: explicitModulesPayload.casOptions!.enableDiagnosticRemarks,
                            enableStrictCASErrors: explicitModulesPayload.casOptions!.enableStrictCASErrors
                        )
                    }
                }

                switch lastResult {
                case .some(.succeeded), .some(.skipped):
                    continue
                default:
                    // Emit the frontend command which failed, unless we have debugging enabled and printed it already
                    if !executionDelegate.userPreferences.enableDebugActivityLogs && !executionDelegate.emitFrontendCommandLines {
                        let commandString = UNIXShellCommandCodec(
                            encodingStrategy: .backslashes,
                            encodingBehavior: .fullCommandLine
                        ).encode(commandLine)

                        // <rdar://59354519> We need to find a way to use the generic infrastructure for displaying the command line in
                        // the build log.
                        outputDelegate.emitOutput("Failed frontend command:\n")
                        outputDelegate.emitOutput(ByteString(encodingAsUTF8: commandString) + "\n")
                    }
                    return lastResult ?? .failed
                }
            }
            return lastResult ?? .failed
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
    }

    /// Intended to be called during task dependency setup.
    /// If remote caching is enabled along with integrated cache queries, it will request
    /// a `ClangCachingMaterializeKeyTaskAction` as task dependency.
    static func maybeRequestCachingKeyMaterialization(
        dependencyInfo: ClangModuleDependencyGraph.DependencyInfo,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        libclangPath: Path,
        casOptions: CASOptions?,
        taskID: inout UInt
    ) throws {
        guard let casOptions,
              casOptions.enableIntegratedCacheQueries,
              casOptions.hasRemoteCache else {
            return
        }

        for command in dependencyInfo.commands {
            guard let cacheKey = command.cacheKey else {
                throw StubError.error("missing cache key")
            }
            let cacheQueryKey = ClangCachingTaskCacheKey(
                libclangPath: libclangPath,
                casOptions: casOptions,
                cacheKey: cacheKey
            )
            let dependencyID = taskID
            taskID += 1
            // Avoid passing any task-specific info, so that the query can be shared across targets.
            dynamicExecutionDelegate.requestDynamicTask(
                toolIdentifier: ClangCachingMaterializeKeyTaskAction.toolIdentifier,
                taskKey: .clangCachingMaterializeKey(cacheQueryKey),
                taskID: dependencyID,
                singleUse: true,
                workingDirectory: Path(""),
                environment: .init(),
                forTarget: nil,
                priority: .network,
                showEnvironment: false,
                reason: .wasCompilationCachingQuery
            )
        }
    }

    /// Attempts to replay a previously cached compilation, using data from the local CAS.
    ///
    /// - Returns: `true` if the the cached compilation outputs were found and replayed, `false` otherwise.
    static func replayCachedCommand(
        _ command: ClangModuleDependencyGraph.DependencyInfo.CompileCommand,
        casDBs: ClangCASDatabases,
        workingDirectory: Path,
        outputDelegate: any TaskOutputDelegate,
        enableDiagnosticRemarks: Bool
    ) throws -> Bool {
        guard let cacheKey = command.cacheKey else {
            throw StubError.error("missing cache key")
        }
        guard let cachedComp = try casDBs.getLocalCachedCompilation(cacheKey: cacheKey) else {
            if enableDiagnosticRemarks {
                outputDelegate.note("cache miss: \(cacheKey)")
            }
            outputDelegate.incrementClangCacheMiss()
            outputDelegate.incrementTaskCounter(.cacheMisses)
            outputDelegate.emitOutput("Cache miss\n")
            return false
        }

        let outputs = cachedComp.getOutputs()
        for output in outputs {
            guard cachedComp.isOutputMaterialized(output) else {
                if enableDiagnosticRemarks {
                    outputDelegate.note("missing CAS output \(output.name): \(output.casID)")
                    outputDelegate.note("cache miss: \(cacheKey)")
                }
                outputDelegate.incrementClangCacheMiss()
                outputDelegate.incrementTaskCounter(.cacheMisses)
                outputDelegate.emitOutput("Cache miss\n")
                return false
            }
        }
        let diagnosticText = try cachedComp.replay(commandLine: command.arguments, workingDirectory: workingDirectory.str)
        if enableDiagnosticRemarks {
            outputDelegate.note("replayed cache hit: \(cacheKey)")
            for output in outputs {
                outputDelegate.note("using CAS output \(output.name): \(output.casID)")
            }
        }
        outputDelegate.incrementClangCacheHit()
        outputDelegate.incrementTaskCounter(.cacheHits)
        outputDelegate.emitOutput("Cache hit\n")
        outputDelegate.emitOutput(ByteString(encodingAsUTF8: diagnosticText))
        return true
    }

    /// Uploads the data for the compilation outputs and the association of cache key -> outputs
    /// to the remote cache.
    static func upload(
        cacheKey: String,
        casDBs: ClangCASDatabases,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        outputDelegate: any TaskOutputDelegate,
        enableDiagnosticRemarks: Bool,
        enableStrictCASErrors: Bool
    ) async throws {
        // FIXME: Make cache key uploading a background task that doesn't block compilation tasks.
        guard let cachedComp = try casDBs.getLocalCachedCompilation(cacheKey: cacheKey) else {
            // This can happen if caching an invocation is skipped due to using date/time macros which makes the output non-deterministic.
            if enableDiagnosticRemarks {
                outputDelegate.note("compilation was not cached for key: \(cacheKey)")
            }
            return
        }
        dynamicExecutionDelegate.operationContext.compilationCachingUploader.upload(
            clangCompilation: cachedComp,
            cacheKey: cacheKey,
            enableDiagnosticRemarks: enableDiagnosticRemarks,
            enableStrictCASErrors: enableStrictCASErrors,
            activityReporter: dynamicExecutionDelegate
        )
    }
}
