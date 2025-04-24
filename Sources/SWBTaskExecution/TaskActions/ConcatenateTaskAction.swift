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
import SWBUtil
import Foundation

public final class ConcatenateTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "concatenate"
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        let inputPaths = task.inputPaths
        let outputPaths = task.outputPaths
        guard (inputPaths.count >= 2) && (outputPaths.count == 1) else {
            outputDelegate.emitError("Internal Concatenate command had invalid inputs/outputs. Please file a bug report and include the project if possible.")
            return .failed
        }
        let outputPath = outputPaths[0]

        let fs = executionDelegate.fs
        do {
            try fs.write(outputPath, contents: fs.read(inputPaths[0]))
            for inputPath in inputPaths[1...] {
                try fs.append(outputPath, contents: fs.read(inputPath))
            }
        } catch {
            outputDelegate.emitError("unable to write file '\(outputPath.str)': \(error.localizedDescription)")
            return .failed
        }
        return .succeeded
    }
}
