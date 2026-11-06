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

/// Concrete implementation of the in-process file-copying task.
public final class FileCopyTaskAction: TaskAction
{
    public override class var toolIdentifier: String
    {
        return "file-copy"
    }

    // Temporary workaround for the App Store
    private let context: FileCopyTaskActionContext
    public init(_ context: FileCopyTaskActionContext) {
        self.context = context
        super.init()
    }

    // Temporary workaround for the App Store
    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(13)
        serializer.serialize(context.skipAppStoreDeployment)
        serializer.serialize(context.stubPartialCompilerCommandLine)
        serializer.serialize(context.stubPartialLinkerCommandLine)
        serializer.serialize(context.stubPartialLipoCommandLine)
        serializer.serialize(context.stubPartialCodesignCommandLine)
        serializer.serialize(context.codesignEnvironment)
        serializer.serialize(context.partialTargetValues)
        serializer.serialize(context.llvmTargetTripleOSVersion)
        serializer.serialize(context.llvmTargetTripleSuffix)
        serializer.serialize(context.platformName)
        serializer.serialize(context.swiftPlatformTargetPrefix)
        serializer.serialize(context.isMacCatalyst)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    // Temporary workaround for the App Store
    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(13)
        self.context = try .init(
            skipAppStoreDeployment: deserializer.deserialize(),
            stubPartialCompilerCommandLine: deserializer.deserialize(),
            stubPartialLinkerCommandLine: deserializer.deserialize(),
            stubPartialLipoCommandLine: deserializer.deserialize(),
            stubPartialCodesignCommandLine: deserializer.deserialize(),
            codesignEnvironment: deserializer.deserialize(),
            partialTargetValues: deserializer.deserialize(),
            llvmTargetTripleOSVersion: deserializer.deserialize(),
            llvmTargetTripleSuffix: deserializer.deserialize(),
            platformName: deserializer.deserialize(),
            swiftPlatformTargetPrefix: deserializer.deserialize(),
            isMacCatalyst: deserializer.deserialize()
        )
        try super.init(from: deserializer)
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        // Call pbxcp to do the work.
        // FIXME: Don't pass stderr here; get real diagnostics which we can pass to our outputDelegate.
        if task.commandLine.contains("-resolve-src-symlinks") {
            for inputPath in task.inputPaths.map({ $0.normalize() }) {
                if var symlinkDestinationPath = try? executionDelegate.fs.readlink(inputPath) {
                    if !symlinkDestinationPath.isAbsolute {
                        symlinkDestinationPath = inputPath.dirname.join(symlinkDestinationPath)
                    }
                    symlinkDestinationPath = symlinkDestinationPath.normalize()
                    dynamicExecutionDelegate.discoveredDependencyDirectoryTree(symlinkDestinationPath)
                }
            }
        }
        let result = await pbxcp(Array(task.commandLineAsStrings), cwd: task.workingDirectory)

        // Get the data as a String so we can pass it to the output delegate.
        result.output.enumerateLines { (line, stop) -> Void in
            switch line
            {
            case _ where line.hasPrefix("error: "):
                outputDelegate.emitError(line.withoutPrefix("error: "))

            case _ where line.hasPrefix("warning: "):
                outputDelegate.emitWarning(line.withoutPrefix("warning: "))

            case _ where line.hasPrefix("note: "):
                outputDelegate.emitNote(line.withoutPrefix("note: "))

            default:
                // If the line is not any of the message types above, then we emit it as text.
                outputDelegate.emitOutput(ByteString(encodingAsUTF8: line))
            }
        }

        if !result.success {
            return .failed
        }

        do {
            let commandLine = Array(task.commandLineAsStrings)
            let frameworkBasePath = commandLine.dropLast().last.map(Path.init)?.frameworkPath?.basename
            let destinationPath = commandLine.last.map(Path.init)

            // Reinject a binary into codeless frameworks, as required by the App store.
            // Note: piggybacking on ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT since that really should just become a general purpose "skip App Store deployment things" setting.
            if !context.skipAppStoreDeployment, let frameworkBasePath, let frameworkPath = destinationPath?.join(frameworkBasePath), let bundle = Bundle(path: frameworkPath.str), bundle.executableIsMissingOrStatic(fs: executionDelegate.fs) == .codeless {
                let isDeepBundle = executionDelegate.fs.isDirectory(frameworkPath.join("Versions"))
                // Deep bundles are not required to use "A" as their framework version, so resolve the actual version directory from the "Current" symlink where possible. Only the basename is used so that absolute or multi-component symlink targets cannot produce a path outside the bundle.
                let versionedSubdirectory: String? = isDeepBundle ? "Versions/\((try? executionDelegate.fs.readlink(frameworkPath.join("Versions/Current")))?.basename ?? "A")" : nil
                let stubResult = try await withTemporaryDirectory { tempDir -> CommandResult in
                    let stubCommands = try context.stubCommandLine(frameworkPath: frameworkPath, versionedSubdirectory: versionedSubdirectory, platformRegistry: executionDelegate.platformRegistry, sdkRegistry: executionDelegate.sdkRegistry, tempDir: tempDir)
                    let stubCommandLines = stubCommands.compileAndLink.flatMap { [$0.compile, $0.link] } + [stubCommands.lipo] + (stubCommands.codesign.map { [$0] } ?? [])

                    outputDelegate.emit(Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("Injecting stub binary into codeless framework"), childDiagnostics: stubCommandLines.map { commandLine in
                        Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData(defaultCommandSequenceEncoder(hostOS: executionDelegate.hostOperatingSystem, unixEncodingStrategy: .singleQuotes).encode(commandLine)))
                    }))

                    var exists: Bool = false
                    if isDeepBundle && !executionDelegate.fs.isSymlink(frameworkPath.join(frameworkPath.basenameWithoutSuffix), &exists) {
                        try executionDelegate.fs.symlink(frameworkPath.join(frameworkPath.basenameWithoutSuffix), target: Path("Versions/Current/\(frameworkPath.basenameWithoutSuffix)"))
                    }

                    let environment = task.environment.bindingsDictionary
                    // The signing environment only concerns codesign itself. The CODESIGN_ALLOCATE resolution computed at task construction takes precedence, matching the codesign tool spec, where the computed environment wins.
                    let codesignEnvironment = environment.merging(context.codesignEnvironment) { _, computedValue in computedValue }
                    for stubCommandLine in stubCommandLines {
                        // Use a fresh delegate per command: a declined (cancelled) spawn invokes no delegate callbacks, so reusing one would surface the previous command's state.
                        let processDelegate = TaskProcessDelegate(outputDelegate: outputDelegate)
                        try await spawn(commandLine: stubCommandLine, environment: stubCommandLine == stubCommands.codesign ? codesignEnvironment : environment, workingDirectory: task.workingDirectory, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: processDelegate)
                        if let error = processDelegate.executionError {
                            outputDelegate.error(error)
                            return .failed
                        }
                        let commandResult = processDelegate.commandResult ?? .failed
                        if commandResult != .succeeded {
                            if commandResult != .cancelled {
                                outputDelegate.emitError("Failed to inject stub binary into codeless framework \(frameworkPath.basename)")
                                // An earlier stub command may have already pinned a successful exit status on the output delegate; override it so the task is reported as failed.
                                outputDelegate.updateResult(.exit(exitStatus: .exit(1), metrics: nil))
                            }
                            return commandResult
                        }
                    }
                    return .succeeded
                }
                if stubResult != .succeeded {
                    return stubResult
                }
            }
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }

        return .succeeded
    }
}
