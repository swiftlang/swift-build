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
public import SWBUtil
import Foundation

public final class CreateBuildDirectoryTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "create-build-directory"
    }

    public static func createBuildDirectory(at directoryPath: Path, fs: any FSProxy, outputDelegate: (any TaskOutputDelegate)? = nil) -> CommandResult {
        // Build directory already exists, nothing to do here.
        if fs.exists(directoryPath) {
            return .succeeded
        }

        do {
            try fs.createDirectory(directoryPath, recursive: true)
            try fs.setCreatedByBuildSystemAttribute(directoryPath)
            return .succeeded
        } catch {
            outputDelegate?.emitError(error.localizedDescription)
            return .failed
        }
    }

    public override func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        let generator = task.commandLineAsStrings.makeIterator()
        _ = generator.next() // consume program name

        guard let directory = generator.next() else {
            outputDelegate.emitError("wrong number of arguments")
            return .failed
        }

        return CreateBuildDirectoryTaskAction.createBuildDirectory(at: Path(directory), fs: executionDelegate.fs, outputDelegate: outputDelegate)
    }
}
