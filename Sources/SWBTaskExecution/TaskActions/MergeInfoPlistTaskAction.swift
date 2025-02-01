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

public final class MergeInfoPlistTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        "builtin-mergeInfoPlist"
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        var commandLine = task.commandLine
        commandLine = Array(commandLine.dropFirst())
        guard let output = commandLine.first.map({ Path($0.asByteString) }) else {
            outputDelegate.emitError("malformed command line")
            return .failed
        }

        let inputs = commandLine.dropFirst().map({ Path($0.asByteString) })
        if inputs.isEmpty {
            // most likely due to misconfigured ARCHS settings
            outputDelegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Info.plist preprocessing did not produce content for any architecture and build variant combination.")))
            return .failed
        }

        do {
            guard let byteString = try Set(inputs.map { try executionDelegate.fs.read($0) }).only else {
                outputDelegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("Info.plist preprocessing produced variable content across multiple architectures and/or build variants, which is not allowed for bundle targets."), childDiagnostics: inputs.map { input in
                    Diagnostic(behavior: .note, location: .path(input), data: DiagnosticData("Using preprocessed file: \(input.str)"))
                }))
                return .failed
            }

            try executionDelegate.fs.write(output, contents: byteString)

            return .succeeded
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
    }
}
