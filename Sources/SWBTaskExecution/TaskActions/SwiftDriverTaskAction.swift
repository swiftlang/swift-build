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
import SWBCAS
import SWBLibc
import SWBProtocol
import SWBUtil
import Foundation

final public class SwiftDriverTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        "swift-driver-invocation"
    }

    var setupError: (any Error)? = nil
    var planSignatureID: ToolchainDataID? = nil

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        // A dynamically requested planning job should always execute
        return false
    }

    public override func taskSetup(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate) {
        // The execution inputs will be provided to `taskDependencyReady`, they don't need to be requested.

        guard let payload = task.payload as? SwiftTaskPayload, let driverPayload = payload.driverPayload else {
            setupError = StubError.error("Invalid payload for Swift integrated driver support")
            return
        }

        var taskID: UInt = UInt(task.executionInputs?.count ?? 0)
        do {
            self.planSignatureID = try Self.maybeRequestCachingKeyMaterialization(
                driverPayload: driverPayload,
                dynamicExecutionDelegate: dynamicExecutionDelegate,
                executionDelegate: executionDelegate,
                workingDirectory: task.workingDirectory,
                casOptions: driverPayload.casOptions,
                taskID: &taskID
            )
        } catch {
            setupError = error
            return
        }
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        if let setupError = self.setupError {
            outputDelegate.emitError(setupError.localizedDescription)
            return .failed
        }

        guard let payload = task.payload as? SwiftTaskPayload, let driverPayload = payload.driverPayload else {
            outputDelegate.emitError("Invalid payload for Swift integrated driver support")
            return .failed
        }

        let dependencyGraph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph

        guard let target = task.forTarget else {
            outputDelegate.emitError("Can't plan Swift driver invocation without a target.")
            return .failed
        }

        guard task.commandLine.starts(with: ["builtin-SwiftDriver", "--"]) else {
            outputDelegate.emitError("Unexpected command line prefix")
            return .failed
        }

        func planBuild() async throws -> Bool {
            let environment: [String: String]
            if let executionEnvironment = executionDelegate.environment {
                environment = executionEnvironment.merging(task.environment.bindingsDictionary, uniquingKeysWith: { a, b in b })
            } else {
                environment = task.environment.bindingsDictionary
            }

            let commandLine = task.commandLineAsStrings.split(separator: "--", maxSplits: 1, omittingEmptySubsequences: false)[1]

            if let casOpts = driverPayload.casOptions, driverPayload.enablePrescanCaching {
                guard let planSignatureID else {
                    throw StubError.error("expected to have computed the signature already")
                }
                let cas = try dynamicExecutionDelegate.operationContext.getOrCreateCAS(options: casOpts.creationOpts)
                if try await Self.replayCachedPlannedBuild(
                    planSignatureID,
                    driverPayload: driverPayload,
                    dependencyGraph: dependencyGraph,
                    target: target,
                    workingDirectory: task.workingDirectory,
                    commandLine: Array(commandLine),
                    environment: environment,
                    cas: cas,
                    outputDelegate: outputDelegate,
                    enableDiagnosticRemarks: casOpts.enableDiagnosticRemarks
                ) {
                    return true
                }
            }

            let (success, planBuildDiagnostics) = dependencyGraph.planBuild(key: driverPayload.uniqueID,
                                                                            compilerLocation: driverPayload.compilerLocation,
                                                                            target: target,
                                                                            args: Array(commandLine),
                                                                            workingDirectory: task.workingDirectory,
                                                                            tempDirPath: driverPayload.tempDirPath,
                                                                            explicitModulesTempDirPath: driverPayload.explicitModulesTempDirPath,
                                                                            environment: environment,
                                                                            eagerCompilationEnabled: driverPayload.eagerCompilationEnabled,
                                                                            casOptions: driverPayload.casOptions)

            // Read and emit any serialized diagnostics reported by the scanner. Then report any diagnostics from planBuild
            // which were not present in the serialized diagnostics. We match on the message and location only, because
            // the diagnostics returned by the API are lower-fidelity compared to those in the serialized diagnostics file.
            let serializedDiagnostics: [Diagnostic]
            if let scannerDiagnosticsPath = driverPayload.scannerDiagnosticsOutputPath {
                serializedDiagnostics = dynamicExecutionDelegate.operationContext.readSerializedDiagnostics(
                    at: scannerDiagnosticsPath,
                    workingDirectory: task.workingDirectory,
                    appendToOutputStream: true,
                    attachmentInfo: driverPayload.diagnosticAttachmentInfo,
                    fs: executionDelegate.fs
                )
            } else {
                serializedDiagnostics = []
            }
            struct SeenDiagnostic: Hashable {
                var message: String
                var location: Diagnostic.Location
            }
            var seenDiagnostics: Set<SeenDiagnostic> = []
            for serializedDiagnostic in serializedDiagnostics {
                outputDelegate.emit(serializedDiagnostic)
                seenDiagnostics.insert(.init(message: serializedDiagnostic.data.description, location: serializedDiagnostic.location))
            }
            for diagnostic in planBuildDiagnostics {
                // Diagnostics returned by planBuild may have rendered fix-its as part of the message, so only compare the first line.
                if seenDiagnostics.contains(.init(message: diagnostic.data.description.split("\n").0, location: diagnostic.location)) {
                    continue
                } else {
                    outputDelegate.emit(diagnostic)
                }
            }

            return success
        }

        do {
            let success = try await planBuild()
            guard success else { return .failed }
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }

        // The dependency scan has now resolved the explicit module map, so this is the point at which the
        // handoff to background indexing can be recorded.
        writeIndexExplicitModuleInfo(target: target, driverPayload: driverPayload, dependencyGraph: dependencyGraph, executionDelegate: executionDelegate, outputDelegate: outputDelegate)

        do {
            if executionDelegate.userPreferences.enableDebugActivityLogs {
                let plannedBuild = try dependencyGraph.queryPlannedBuild(for: driverPayload.uniqueID)

                let jobsDebugDescription: (ArraySlice<LibSwiftDriver.PlannedBuild.PlannedSwiftDriverJob>) -> String = {
                    $0.map({ "\t\t\($0.debugDescription)" }).joined(separator: "\n")
                }

                let cohortArchsSuffix = driverPayload.cohortArchitectures.isEmpty ? "" : ", " + driverPayload.cohortArchitectures.joined(separator: ", ")
                var message = "Swift Driver planned jobs for target \(task.forTarget?.target.name ?? "<unknown>") (\(driverPayload.slice)-\(driverPayload.variant)\(cohortArchsSuffix)):"
                if driverPayload.explicitModulesEnabled {
                    message += "\n\tExplicit Modules:\n" + jobsDebugDescription(plannedBuild.explicitModulesPlannedDriverJobs()[...])
                }
                message += "\n\tCompilation Requirements:\n" + jobsDebugDescription(plannedBuild.compilationRequirementsPlannedDriverJobs())
                message += "\n\tCompilation:\n" + jobsDebugDescription(plannedBuild.compilationPlannedDriverJobs())
                message += "\n\tAfter Compilation:\n" + jobsDebugDescription(plannedBuild.afterCompilationPlannedDriverJobs())
                message += "\n\tVerification:\n" + jobsDebugDescription(plannedBuild.verificationPlannedDriverJobs())

                outputDelegate.emitNote(message)
            }

            if driverPayload.reportRequiredTargetDependencies != .no && driverPayload.explicitModulesEnabled, let target = task.forTarget {
                let dependencyModuleNames = try await dependencyGraph.queryTransitiveDependencyModuleNames(for: driverPayload.uniqueID)
                for dependencyModuleName in dependencyModuleNames {
                    if let targetDependencies = dynamicExecutionDelegate.operationContext.definingTargetsByModuleName[dependencyModuleName] {
                        for targetDependency in targetDependencies {
                            guard targetDependency.guid != target.guid else {
                                continue
                            }
                            executionDelegate.taskDiscoveredRequiredTargetDependency(target: target, antecedent: targetDependency, reason: .swiftModuleDependency(dependentModuleName: driverPayload.moduleName, dependencyModuleName: dependencyModuleName), warningLevel: driverPayload.reportRequiredTargetDependencies)
                        }
                    }
                }
            }

            if let linkerResponseFilePath = driverPayload.linkerResponseFilePath {
                var responseFileCommandLine: [String] = []
                if driverPayload.explicitModulesEnabled {
                    for swiftmodulePath in try dependencyGraph.querySwiftmodulesNeedingRegistrationForDebugging(for: driverPayload.uniqueID) {
                        responseFileCommandLine.append(contentsOf: ["-Xlinker", "-add_ast_path", "-Xlinker", "\(swiftmodulePath)"])
                    }
                }
                let contents = ByteString(encodingAsUTF8: ResponseFiles.responseFileContents(args: responseFileCommandLine, format: driverPayload.linkerResponseFileFormat))
                try executionDelegate.fs.createDirectory(linkerResponseFilePath.dirname, recursive: true)
                try executionDelegate.fs.write(linkerResponseFilePath, contents: contents, atomically: true)
            }

            return .succeeded
        } catch {
            outputDelegate.error("Unexpected error in querying jobs from dependency graph: \(error)")
            return .failed
        }
    }

    /// During index-build-arena preparation, persist the explicit-module inputs the scan just resolved so that
    /// background indexing can reuse the modules prep built instead of re-scanning and rebuilding them.
    ///
    /// Best effort: any failure leaves no sidecar, and indexing simply falls back to today's behavior.
    private func writeIndexExplicitModuleInfo(target: ConfiguredTarget, driverPayload: SwiftDriverPayload, dependencyGraph: SwiftModuleDependencyGraph, executionDelegate: any TaskExecutionDelegate, outputDelegate: any TaskOutputDelegate) {
        guard case .prepareForIndexing(_, let enableIndexBuildArena) = executionDelegate.buildCommand, enableIndexBuildArena else { return }
        guard let path = driverPayload.indexExplicitModuleInfoPath else { return }

        do {
            let plannedBuild = try dependencyGraph.queryPlannedBuild(for: driverPayload.uniqueID)
            guard let job = plannedBuild.compilationRequirementsPlannedDriverJobs().first else { return }
            let commandLine = job.driverJob.commandLine.map { $0.asString }
            let info = IndexExplicitModuleInfo(resolvedArguments: commandLine)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let contents = try ByteString(encoder.encode(info))
            try executionDelegate.fs.createDirectory(path.dirname, recursive: true)
            if try executionDelegate.fs.writeIfChanged(path, contents: contents) {
                // Index compiler arguments are derived from this file, so clients caching them need to know.
                executionDelegate.indexOptionsChanged(for: target)
            }
        } catch {
            outputDelegate.warning("Unable to write explicit modules index info: \(error)")
        }
    }

    /// Intended to be called during task dependency setup.
    /// If remote caching is enabled it will request a `CASCachingMaterializeKeyTaskAction` as task dependency.
    static func maybeRequestCachingKeyMaterialization(
        driverPayload: SwiftDriverPayload,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        workingDirectory: Path,
        casOptions: CASOptions?,
        taskID: inout UInt
    ) throws -> ToolchainDataID? {
        guard let casOptions, driverPayload.enablePrescanCaching else {
            return nil
        }

        let cas = try dynamicExecutionDelegate.operationContext.getOrCreateCAS(options: casOptions.creationOpts)
        let globalSignature = try driverPayload.computeGlobalSignature(fs: executionDelegate.fs, workingDirectory: workingDirectory)
        let signatureID = try cas.store(object: ToolchainCASObject(data: globalSignature, refs: []))

        guard casOptions.hasRemoteCache else {
            return signatureID
        }

        let cacheQueryKey = CASCachingTaskCacheKey(
            cacheKey: cas.printID(signatureID),
            casOptions: casOptions,
        )
        let dependencyID = taskID
        taskID += 1
        // Avoid passing any task-specific info, so that the query can be shared across targets.
        dynamicExecutionDelegate.requestDynamicTask(
            toolIdentifier: CASCachingMaterializeKeyTaskAction.toolIdentifier,
            taskKey: .casCachingMaterializeKey(cacheQueryKey),
            taskID: dependencyID,
            singleUse: true,
            workingDirectory: Path(""),
            environment: .init(),
            forTarget: nil,
            priority: .network,
            showEnvironment: false,
            reason: .wasCompilationCachingQuery
        )
        return signatureID
    }

    static func replayCachedPlannedBuild(
        _ planSignatureID: ToolchainDataID,
        driverPayload: SwiftDriverPayload,
        dependencyGraph: SwiftModuleDependencyGraph,
        target: ConfiguredTarget,
        workingDirectory: Path,
        commandLine: [String],
        environment: [String: String],
        cas: ToolchainCAS,
        outputDelegate: any TaskOutputDelegate,
        enableDiagnosticRemarks: Bool,
    ) async throws -> Bool {
        func replayImpl() async throws -> Bool {
            guard let planID = try await cas.lookupCachedObject(for: planSignatureID) else {
                return false
            }
            guard let object = try await cas.load(id: planID) else {
                if enableDiagnosticRemarks {
                    outputDelegate.note("missing CAS object \(cas.printID(planID))")
                }
                return false
            }
            if enableDiagnosticRemarks {
                outputDelegate.note("replayed from CAS object \(cas.printID(planID))")
            }

            let deserializer = MsgPackDeserializer(object.data)
            let plannedBuild = try LibSwiftDriver.PlannedBuild(
                from: deserializer,
                globalExplicitDependencyJobGraph: dependencyGraph,
                tempDirPath: driverPayload.tempDirPath,
                explicitModulesTempDirPath: driverPayload.explicitModulesTempDirPath,
                casPath: driverPayload.casOptions?.casPath,
            )
            try dependencyGraph.registerPrecachedPlannedBuild(
                plannedBuild,
                for: driverPayload.uniqueID,
                compilerLocation: driverPayload.compilerLocation,
                target: target,
                workingDirectory: workingDirectory,
                tempDirPath: driverPayload.tempDirPath,
                explicitModulesTempDirPath: driverPayload.explicitModulesTempDirPath,
                commandLine: commandLine,
                environment: environment,
                eagerCompilationEnabled: driverPayload.eagerCompilationEnabled,
                casOptions: driverPayload.casOptions,
            )
            // FIXME: replay scan diagnostics.
            return true
        }

        let wasHit = try await replayImpl()
        if enableDiagnosticRemarks {
            outputDelegate.note("cache \(wasHit ? "hit" : "miss"): \(cas.printID(planSignatureID))")
        }
        outputDelegate.incrementCounter(wasHit ? .swiftCacheHits : .swiftCacheMisses)
        outputDelegate.incrementTaskCounter(wasHit ? .cacheHits : .cacheMisses)
        outputDelegate.emitOutput(ByteString(encodingAsUTF8: "Cache \(wasHit ? "hit" : "miss")\n"))
        return wasHit
    }
}
