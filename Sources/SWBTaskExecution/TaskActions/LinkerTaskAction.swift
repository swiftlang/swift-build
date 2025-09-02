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
    
    public init(expandResponseFiles: Bool) {
        self.expandResponseFiles = expandResponseFiles
        super.init()
    }
    
    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(expandResponseFiles)
        super.serialize(to: serializer)
        serializer.endAggregate()
    }
    
    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.expandResponseFiles = try deserializer.deserialize()
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
                    relativeTo: task.workingDirectory
                )
            } catch {
                outputDelegate.emitError("Failed to expand response files: \(error.localizedDescription)")
                return .failed
            }
        }
        
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
