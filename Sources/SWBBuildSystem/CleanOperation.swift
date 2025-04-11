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

package import SWBCore
import SWBTaskExecution
package import SWBProtocol
package import SWBUtil

package import class Foundation.FileManager
package import var Foundation.NSCocoaErrorDomain
package import var Foundation.NSFileNoSuchFileError
package import var Foundation.NSLocalizedDescriptionKey
package import class Foundation.NSError
package import struct Foundation.URL
package import struct Foundation.UUID
import SWBMacro

package final class CleanOperation: BuildSystemOperation, TargetDependencyResolverDelegate {
    package var diagnosticContext: DiagnosticContextData {
        return DiagnosticContextData(target: nil)
    }

    package func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return dependencyResolverDelegate?.diagnosticsEngine(for: target) ?? .init(_diagnosticsEngine)
    }

    package let cachedBuildSystems: any BuildSystemCache

    private let buildRequest: BuildRequest
    private let buildRequestContext: BuildRequestContext
    private let delegate: any BuildOperationDelegate
    private let dependencyResolverDelegate: (any TargetDependencyResolverDelegate)?
    private let _diagnosticsEngine = DiagnosticsEngine()
    private let style: BuildLocationStyle
    private let workspaceContext: WorkspaceContext
    private let ignoreCreatedByBuildSystemAttribute: Bool

    private var wasCancellationRequested = false
    package let uuid: UUID

    package init(buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, workspaceContext: WorkspaceContext, style: BuildLocationStyle, delegate: any BuildOperationDelegate, cachedBuildSystems: any BuildSystemCache, dependencyResolverDelegate: (any TargetDependencyResolverDelegate)? = nil) {
        self.buildRequest = buildRequest
        self.buildRequestContext = buildRequestContext
        self.delegate = delegate
        self.dependencyResolverDelegate = dependencyResolverDelegate
        self.style = style
        self.uuid = UUID()
        self.workspaceContext = workspaceContext
        self.ignoreCreatedByBuildSystemAttribute = buildRequestContext.getCachedSettings(buildRequest.parameters).globalScope.evaluate(BuiltinMacros.IGNORE_CREATED_BY_BUILD_SYSTEM_ATTRIBUTE_DURING_CLEAN)
        self.cachedBuildSystems = cachedBuildSystems
    }

    package func buildDataDirectory() throws -> Path {
        return try BuildDescriptionManager.cacheDirectory(buildRequest, buildRequestContext: buildRequestContext, workspaceContext: workspaceContext).join("XCBuildData")
    }

    package func build() async -> BuildOperationEnded.Status {
        let buildOutputDelegate = delegate.buildStarted(self)

        if workspaceContext.userPreferences.enableDebugActivityLogs {
            showConnectionModeMessage(workspaceContext.core.connectionMode, buildOutputDelegate)
        }

        let buildDataDirectory: Path
        do {
            buildDataDirectory = try self.buildDataDirectory()
        } catch {
            emit(.init(behavior: .error, location: .unknown, data: DiagnosticData("\(error)")))
            return delegate.buildComplete(self, status: .failed, delegate: buildOutputDelegate, metrics: nil)
        }

        // Make sure potentially cached build systems are cleared, so that their database is closed.
        cachedBuildSystems.clearCachedBuildSystem(for: buildDataDirectory)

        let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: self)

        // If there were any errors while constructing the build graph, we will stop cleaning.
        if hadErrors {
            return delegate.buildComplete(self, status: .failed, delegate: buildOutputDelegate, metrics: nil)
        }

        var buildFolders = await buildGraph.allTargets.asyncFlatMap { configuredTarget -> [Path] in
            let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
            if style == .legacy && configuredTarget.target.type == .external {
                await cleanExternalTarget(configuredTarget, settings: settings)
                return []
            } else {
                return workspaceContext.buildDirectories(settings: settings)
            }
        }

        if buildFolders.isEmpty {
            let settings = buildRequestContext.getCachedSettings(buildRequest.parameters)
            buildFolders = workspaceContext.buildDirectories(settings: settings)
        }

        cleanBuildFolders(buildFolders: Set(buildFolders), buildOutputDelegate: buildOutputDelegate)

        return delegate.buildComplete(self, status: nil, delegate: buildOutputDelegate, metrics: nil)
    }

    package func cancel() {
        wasCancellationRequested = true
    }

    package func abort() {
        // Not needed for clean operations because there is no concept of continuing to build after errors
    }

    private var hadErrors = false

    package func emit(_ diagnostic: Diagnostic) {
        if diagnostic.behavior == .error {
            hadErrors = true
        }
        dependencyResolverDelegate?.emit(diagnostic)
    }

    package func updateProgress(statusMessage: String, showInLog: Bool) {
        dependencyResolverDelegate?.updateProgress(statusMessage: statusMessage, showInLog: showInLog)
    }

    package var request: BuildRequest {
        return buildRequest
    }

    package var requestContext: BuildRequestContext {
        return buildRequestContext
    }

    package let subtaskProgressReporter: (any SubtaskProgressReporter)? = nil

    private func isBuildFolder(_ buildFolderPath: Path) -> Bool {
        do {
            if try workspaceContext.fs.hasCreatedByBuildSystemAttribute(buildFolderPath) {
                return true
            }
        } catch {
        }

        // If the attribute isn't set, consider the arena as an indicator for build-folderness.
        if let arena = buildRequest.parameters.arena {
            for path in [arena.derivedDataPath, arena.buildIntermediatesPath, arena.buildProductsPath] {
                if buildFolderPath == path || path.isAncestor(of: buildFolderPath) {
                    return true
                }
            }
        }

        return false
    }

    private final class CleanExecutableTask: ExecutableTask {
        init(commandLine: [String], workingDirectory: Path, environment: [String:String], configuredTarget: ConfiguredTarget, type: any TaskTypeDescription) {
            self.commandLine = commandLine.map { .literal(ByteString(encodingAsUTF8: $0)) }
            self.workingDirectory = workingDirectory
            self.environment = EnvironmentBindings(environment)
            self.forTarget = configuredTarget
            self.type = type
        }

        let commandLine: [CommandLineArgument]
        let environment: EnvironmentBindings
        let forTarget: ConfiguredTarget?
        let workingDirectory: Path
        let type: any TaskTypeDescription

        let additionalOutput: [String] = []
        let execDescription: String? = nil
        let dependencyData: DependencyDataStyle? = nil
        let payload: (any TaskPayload)? = nil
        let additionalSignatureData: String = ""

        var ruleInfo: [String] {
            return commandLine.map { $0.asString }
        }

        let inputPaths = [Path]()
        let outputPaths = [Path]()
        let targetDependencies = [ResolvedTargetDependency]()
        let executionInputs: [ExecutionNode]? = nil
        var priority: TaskPriority { .unspecified }
        var showInLog: Bool { !isGate }
        var showCommandLineInLog: Bool { true }
        let isDynamic = false
        let alwaysExecuteTask = false
        let isGate = false
        let showEnvironment = true
        let preparesForIndexing = false
        let llbuildControlDisabled = false
    }

    private func cleanExternalTarget(_ configuredTarget: ConfiguredTarget, settings: Settings) async {
        if self.wasCancellationRequested || _Concurrency.Task.isCancelled {
            return
        }

        delegate.targetPreparationStarted(self, configuredTarget: configuredTarget)
        delegate.targetStarted(self, configuredTarget: configuredTarget)

        let (executable, arguments, workingDirectory, environment) = constructCommandLine(for: configuredTarget.target as! SWBCore.ExternalTarget, action: "clean", settings: settings, workspaceContext: workspaceContext, scope: settings.globalScope)
        let commandLine = [executable] + arguments

        let specLookupContext = SpecLookupCtxt(specRegistry: workspaceContext.core.specRegistry, platform: settings.platform)
        let taskType = specLookupContext.getSpec("com.apple.commands.shell-script") as! ShellScriptToolSpec
        let task = CleanExecutableTask(commandLine: commandLine, workingDirectory: workingDirectory, environment: environment, configuredTarget: configuredTarget, type: taskType)
        let taskIdentifier = task.identifier
        let taskOutputDelegate = delegate.taskStarted(self, taskIdentifier: taskIdentifier, task: task, dependencyInfo: nil)

        let resolvedExecutable = StackedSearchPath(environment: .init(environment), fs: workspaceContext.fs).lookup(Path(executable)) ?? Path(executable)

        do {
            let result = try await Process.getMergedOutput(url: URL(fileURLWithPath: resolvedExecutable.str), arguments: arguments, currentDirectoryURL: URL(fileURLWithPath: workingDirectory.str), environment: .init(environment))

            if !result.exitStatus.isSuccess {
                taskOutputDelegate.emitError("Failed to clean target '\(configuredTarget.target.name)': \(String(decoding: result.output, as: UTF8.self))")
            } else {
                taskOutputDelegate.emitOutput(ByteString(result.output))
            }

            taskOutputDelegate.updateResult(.exit(exitStatus: result.exitStatus, metrics: nil))
        } catch {
            taskOutputDelegate.emitError("Failed to clean target '\(configuredTarget.target.name)': \(error.localizedDescription)")
            taskOutputDelegate.updateResult(.exit(exitStatus: .exit(1), metrics: nil))
        }

        delegate.taskComplete(self, taskIdentifier: taskIdentifier, task: task, delegate: taskOutputDelegate)
        delegate.targetComplete(self, configuredTarget: configuredTarget)
    }

    private func formatError(_ error: NSError, message: String = "Failed to clean build folder") -> NSError {
        var description = error.localizedDescription
        if let reason = error.localizedFailureReason {
            description += " (\(reason))"
        }
        return NSError(domain: "org.swift.swift-build", code: 0, userInfo: [ NSLocalizedDescriptionKey: "\(message): \(description)" ])
    }

    private func cleanBuildFolders(buildFolders: Set<Path>, buildOutputDelegate: any BuildOutputDelegate) {
        let fs = workspaceContext.fs
        for buildFolderPath in buildFolders {
            if self.wasCancellationRequested || _Concurrency.Task.isCancelled || !fs.exists(buildFolderPath) {
                continue
            }

            var foundProjectAncestorPaths = false
            for project in workspaceContext.workspace.projects {
                if buildFolderPath.isAncestor(of: project.xcodeprojPath) {
                    let message = "Refusing to delete `\(buildFolderPath.str)` because it contains one of the projects in this workspace: `\(project.xcodeprojPath.str)`."
                    buildOutputDelegate.warning(message)
                    foundProjectAncestorPaths = true
                }
            }

            if foundProjectAncestorPaths {
                continue
            }

            if isBuildFolder(buildFolderPath) || ignoreCreatedByBuildSystemAttribute {
                do {
                    try deleteBuildFolder(buildFolderPath)
                } catch let error as NSError {
                    if error.domain == "org.swift.swift-build" {
                        buildOutputDelegate.error(error.localizedDescription)
                    } else {
                        buildOutputDelegate.error("Failed to clean build folder: \(error.localizedDescription)")
                    }
                }
            } else {
                var message = "Could not delete `\(buildFolderPath.str)` because it was not created by the build system"
                // The derived data remark doesn't apply for legacy locations, so let's not mention it here.
                if style == .regular {
                    message += " and it is not a subfolder of derived data."
                } else {
                    message += "."
                }
                buildOutputDelegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData(message), childDiagnostics: [
                    Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("To mark this directory as deletable by the build system, run `\(UNIXShellCommandCodec(encodingStrategy: .singleQuotes, encodingBehavior: .fullCommandLine).encode(fs.commandLineArgumentsToApplyCreatedByBuildSystemAttribute(to: buildFolderPath)))` when it is created."))
                ]))
            }
        }
    }

    private func deleteBuildFolder(_ buildFolderPath: Path) throws {
        let buildFolderUrl = URL(fileURLWithPath: buildFolderPath.str)
        let tmpdir: URL
        do {
            tmpdir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: buildFolderUrl, create: true)
        } catch let error as NSError {
            throw formatError(error, message: "Error while cleaning build folder, could not create item replacement directory for '\(buildFolderUrl.path)'")
        }
        let pathToDelete = tmpdir.appendingPathComponent("CleanBuildFolderInProgress")

        // 1. Delete destination if it already exists
        do {
            try FileManager.default.removeItem(at: pathToDelete)
        } catch let error as NSError {
            // If we couldn't delete it because it didn’t exist, ignore & continue, otherwise rethrow.
            if error.domain != NSCocoaErrorDomain || error.code != NSFileNoSuchFileError {
                throw formatError(error, message: "Error while cleaning build folder, could not remove '\(pathToDelete.path)'")
            }
        }

        // 2. Move build folder to a temporary directory on the same volume
        //
        // <rdar://problem/9725975>
        // We move the folder aside because we cannot pause the Indexer and
        // the Indexer intermittently writes files to Build/Intermediates.noindex
        // and if this occurs *during* removeItemAtURL: the operation fails
        // with a (misleading) permissions error.
        do {
            try FileManager.default.moveItem(at: buildFolderUrl, to: pathToDelete)
        } catch let error as NSError {
            throw formatError(error, message: "Error while cleaning build folder, could not move '\(buildFolderUrl.path)' to '\(pathToDelete.path)'")
        }

        // 3. Delete temporary destination folder
        do {
            try FileManager.default.removeItem(at: tmpdir)
        } catch let error as NSError {
            // If we couldn't move it because it doesn't exist, that's not really an error, otherwise rethrow.
            if error.domain != NSCocoaErrorDomain || error.code != NSFileNoSuchFileError {
                throw formatError(error, message: "Error while cleaning build folder, could not remove '\(pathToDelete.path)'")
            }
        }

        if workspaceContext.userPreferences.enableDebugActivityLogs {
            delegate.updateBuildProgress(statusMessage: "Deleted build folder: \(buildFolderPath.str)", showInLog: true)
        }
    }
}

extension WorkspaceContext {
    func buildDirectories(settings: Settings) -> [Path] {
        buildDirectoryMacros.map { settings.globalScope.evaluate($0) }
    }
}
