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

public final class LinkerTaskAction: TaskAction {

    public override class var toolIdentifier: String {
        return "linker"
    }

    /// Whether response files should be expanded before invoking the linker.
    private let expandResponseFiles: Bool
    private let responseFileFormat: ResponseFileFormat

    /// Whether static archive inputs should be extracted to their constituent
    /// object files before invoking the archiver. Apple's libtool is capable of
    /// directly merging static archives, but other tools like ar/llvm-ar/GNU libtool
    /// are not.
    private let extractArchiveInputs: Bool

    public init(expandResponseFiles: Bool, responseFileFormat: ResponseFileFormat, extractArchiveInputs: Bool) {
        self.expandResponseFiles = expandResponseFiles
        self.responseFileFormat = responseFileFormat
        self.extractArchiveInputs = extractArchiveInputs
        super.init()
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(4)
        serializer.serialize(expandResponseFiles)
        serializer.serialize(responseFileFormat)
        serializer.serialize(extractArchiveInputs)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.expandResponseFiles = try deserializer.deserialize()
        self.responseFileFormat = try deserializer.deserialize()
        self.extractArchiveInputs = try deserializer.deserialize()
        try super.init(from: deserializer)
    }

    public override func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        var commandLine = Array(task.commandLineAsStrings)

        if expandResponseFiles {
            do {
                commandLine = try ResponseFiles.expandResponseFiles(
                    commandLine,
                    fileSystem: executionDelegate.fs,
                    relativeTo: task.workingDirectory,
                    format: responseFileFormat
                )
            } catch {
                outputDelegate.emitError("Failed to expand response files: \(error.localizedDescription)")
                return .failed
            }
        }

        if extractArchiveInputs {
            do {
                return try await withTemporaryDirectory(fs: executionDelegate.fs) { tempDir in
                    do {
                        commandLine = try await extractStaticArchiveInputs(
                            commandLine,
                            tempDir: tempDir,
                            task: task,
                            dynamicExecutionDelegate: dynamicExecutionDelegate,
                            executionDelegate: executionDelegate,
                            outputDelegate: outputDelegate
                        )
                    }
                    return await runArchiver(
                        commandLine,
                        task: task,
                        dynamicExecutionDelegate: dynamicExecutionDelegate,
                        executionDelegate: executionDelegate,
                        outputDelegate: outputDelegate
                    )
                }
            } catch {
                outputDelegate.emitError("Failed to extract archive inputs: \(error.localizedDescription)")
                return .failed
            }
        } else {
            return await runArchiver(
                commandLine,
                task: task,
                dynamicExecutionDelegate: dynamicExecutionDelegate,
                executionDelegate: executionDelegate,
                outputDelegate: outputDelegate
            )
        }
    }

    private func extractStaticArchiveInputs(
        _ commandLine: [String],
        tempDir: Path,
        task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async throws -> [String] {
        guard !commandLine.isEmpty else { return commandLine }

        let arPath = commandLine[0]
        let outputPaths = Set(task.outputPaths.map(\.str))

        var result = commandLine
        var insertionOffset = 0
        var archiveIndex = 0

        for (originalIndex, arg) in commandLine.enumerated() {
            // Extract objects from any static archive on the command line which isn't
            // a task output.
            guard arg.hasSuffix(".a"), !outputPaths.contains(arg) else { continue }

            // Create a separate subdirectory of the temp dir for each archive we're
            // extracting objects from.
            let extractDir = tempDir.join(String(archiveIndex))
            archiveIndex += 1
            try executionDelegate.fs.createDirectory(extractDir)

            let processDelegate = TaskProcessDelegate(outputDelegate: outputDelegate)
            let success = try await dynamicExecutionDelegate.spawn(
                commandLine: [arPath, "x", arg],
                environment: task.environment.bindingsDictionary,
                workingDirectory: extractDir,
                processDelegate: processDelegate
            )

            if let error = processDelegate.executionError {
                throw StubError.error(error)
            }
            guard success else {
                throw StubError.error("Failed to extract static archive: \(arg)")
            }

            let extractedObjects = try executionDelegate.fs.listdir(extractDir)
                .sorted()
                .map { extractDir.join($0).str }

            // Update the command line to replace each static archive with the objects we extracted from it.
            let adjustedIndex = originalIndex + insertionOffset
            result.remove(at: adjustedIndex)
            result.insert(contentsOf: extractedObjects, at: adjustedIndex)
            insertionOffset += extractedObjects.count - 1
        }

        return result
    }

    private func runArchiver(
        _ commandLine: [String],
        task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        let processDelegate = TaskProcessDelegate(outputDelegate: outputDelegate)
        do {
            let success = try await dynamicExecutionDelegate.spawn(
                commandLine: commandLine,
                environment: task.environment.bindingsDictionary,
                workingDirectory: task.workingDirectory,
                processDelegate: processDelegate
            )

            if let error = processDelegate.executionError {
                outputDelegate.emitError(error)
                return .failed
            }

            if success {
                if let spec = task.type as? CommandLineToolSpec, let files = task.dependencyData {
                    do {
                        try spec.adjust(dependencyFiles: files, for: task, fs: executionDelegate.fs)
                    } catch {
                        outputDelegate.emitWarning("Unable to perform dependency info modifications: \(error)")
                    }
                }
            }

            return success ? .succeeded : .failed
        } catch {
            outputDelegate.emitError("Process execution failed: \(error.localizedDescription)")
            return .failed
        }
    }
}
