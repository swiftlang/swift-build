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
public import SWBUtil
import SWBLibc
public import SWBCore
public import SWBLLBuild

final public class PrecompileClangModuleTaskAction: TaskAction, BuildValueValidatingTaskAction {
    public override class var toolIdentifier: String {
        return "precompile-module"
    }

    private let key: PrecompileClangModuleTaskKey

    // Reference for potential errors during task action callbacks that need to be propagated until performTaskAction,
    // since that's when the TaskAction is considered to be executed.
    private var executionError: (any Error)?

    package init(key: PrecompileClangModuleTaskKey) {
        self.key = key
        super.init()
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue) -> Bool {
        fatalError("Unexpectedly called the old version of isResultValid")
    }

    public func isResultValid(_ task: any ExecutableTask, _ operationContext: DynamicTaskOperationContext, buildValue: BuildValue, fallback: (BuildValue) -> Bool) -> Bool {
        fallback(buildValue) && areCASResultsValid(operationContext)
    }

    private func areCASResultsValid(_ operationContext: DynamicTaskOperationContext) -> Bool {
        guard let casOptions = key.casOptions else {
            return true
        }

        guard let dependencyInfo = try? operationContext.clangModuleDependencyGraph.queryDependencies(at: key.dependencyInfoPath, fileSystem: localFS) else {
            return false
        }

        guard let casDBs = try? operationContext.clangModuleDependencyGraph.getCASDatabases(libclangPath: key.libclangPath, casOptions: casOptions) else {
            return false
        }

        for command in dependencyInfo.commands {
            guard let cacheKey = command.cacheKey else {
                return false
            }

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
        let clangModuleDependencyGraph = dynamicExecutionDelegate.operationContext.clangModuleDependencyGraph

        // If a precompile task action is executing, it is expected that the scanning action already happened, so the
        // dependencies for this module should already be present in the ModuleDependencyGraph.
        let dependencyInfo: ClangModuleDependencyGraph.DependencyInfo
        do {
            dependencyInfo = try clangModuleDependencyGraph.queryDependencies(at: key.dependencyInfoPath, fileSystem: executionDelegate.fs)
        } catch {
            executionError = error
            return
        }

        var taskID = UInt(0)
        for module in dependencyInfo.modules {
            let taskKey = PrecompileClangModuleTaskKey(
                dependencyInfoPath: Path(module.withoutSuffix + ".scan"),
                usesSerializedDiagnostics: dependencyInfo.usesSerializedDiagnostics,
                libclangPath: key.libclangPath,
                casOptions: key.casOptions,
                verifyingModule: key.verifyingModule,
                fileNameMapPath: key.fileNameMapPath
            )

            dynamicExecutionDelegate.requestDynamicTask(
                toolIdentifier: PrecompileClangModuleTaskAction.toolIdentifier,
                taskKey: .precompileClangModule(taskKey),
                taskID: taskID,
                singleUse: false,
                workingDirectory: Path.root,
                environment: task.environment,
                forTarget: task.forTarget,
                priority: .preferred,
                showEnvironment: task.showEnvironment,
                reason: .wasScannedClangModuleDependency(of: key.dependencyInfoPath.str)
            )
            taskID += 1
        }

        do {
            try ClangCompileTaskAction.maybeRequestCachingKeyMaterialization(
                dependencyInfo: dependencyInfo,
                dynamicExecutionDelegate: dynamicExecutionDelegate,
                libclangPath: key.libclangPath,
                casOptions: key.casOptions,
                taskID: &taskID
            )
        } catch {
            executionError = error
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
        if let error = executionError {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }

        let clangModuleDependencyGraph = dynamicExecutionDelegate.operationContext.clangModuleDependencyGraph
        let dependencyInfo: ClangModuleDependencyGraph.DependencyInfo
        do {
            dependencyInfo = try clangModuleDependencyGraph.queryDependencies(at: key.dependencyInfoPath, fileSystem: executionDelegate.fs)
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }

        for node in (dependencyInfo.files.map {
            ExecutionNode(identifier: $0.str)
        }) {
            dynamicExecutionDelegate.discoveredDependencyNode(node)
        }

        guard let command = dependencyInfo.commands.only else {
            outputDelegate.emitError("Module dependency \(key.dependencyInfoPath) should have a single command-line")
            return .failed
        }
        let commandLine = command.arguments

        if executionDelegate.userPreferences.enableDebugActivityLogs || executionDelegate.emitFrontendCommandLines {
            let commandString = UNIXShellCommandCodec(
                encodingStrategy: .backslashes,
                encodingBehavior: .fullCommandLine
            ).encode(commandLine)

            // <rdar://59354519> We need to find a way to use the generic infrastructure for displaying the command line in
            // the build log.
            outputDelegate.emitOutput(ByteString(encodingAsUTF8: commandString) + "\n")
        }

        if executionDelegate.userPreferences.enableDebugActivityLogs {
            outputDelegate.emitOutput(ByteString(encodingAsUTF8: dependencyInfo.files.map(\.str).joined(separator: "\n") + "\n"))
        }

        do {
            let casDBs: ClangCASDatabases?
            if let casOptions = key.casOptions, casOptions.enableIntegratedCacheQueries {
                casDBs = try clangModuleDependencyGraph.getCASDatabases(
                    libclangPath: key.libclangPath,
                    casOptions: casOptions
                )
            } else {
                casDBs = nil
            }

            if let casDBs {
                if try ClangCompileTaskAction.replayCachedCommand(
                    command,
                    casDBs: casDBs,
                    workingDirectory: dependencyInfo.workingDirectory,
                    outputDelegate: outputDelegate,
                    enableDiagnosticRemarks: key.casOptions!.enableDiagnosticRemarks
                ) {
                    return .succeeded
                }
            }

            let delegate = TaskProcessDelegate(outputDelegate: outputDelegate)
            // The frontend invocations should be unaffected by the environment, pass an empty one.
            try await spawn(commandLine: commandLine, environment: [:], workingDirectory: dependencyInfo.workingDirectory.str, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: delegate)

            let result = delegate.commandResult ?? .failed
            if result == .succeeded {
                if let casDBs, key.casOptions!.hasRemoteCache {
                    guard let cacheKey = command.cacheKey else {
                        throw StubError.error("missing cache key")
                    }
                    try await ClangCompileTaskAction.upload(
                        cacheKey: cacheKey,
                        casDBs: casDBs,
                        dynamicExecutionDelegate: dynamicExecutionDelegate,
                        outputDelegate: outputDelegate,
                        enableDiagnosticRemarks: key.casOptions!.enableDiagnosticRemarks,
                        enableStrictCASErrors: key.casOptions!.enableStrictCASErrors
                    )
                }
            } else if result == .failed && !executionDelegate.userPreferences.enableDebugActivityLogs && !executionDelegate.emitFrontendCommandLines {
                let commandString = UNIXShellCommandCodec(
                    encodingStrategy: .backslashes,
                    encodingBehavior: .fullCommandLine
                ).encode(commandLine)

                // <rdar://59354519> We need to find a way to use the generic infrastructure for displaying the command line in
                // the build log.
                outputDelegate.emitOutput("Failed frontend command:\n")
                outputDelegate.emitOutput(ByteString(encodingAsUTF8: commandString) + "\n")
            }
            return result
        } catch {
            outputDelegate.emitError("There was an error precompiling module \(key.dependencyInfoPath).\n\n\(error)")
            return .failed
        }
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
