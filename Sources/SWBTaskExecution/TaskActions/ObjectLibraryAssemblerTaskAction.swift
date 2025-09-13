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
import ArgumentParser

public final class ObjectLibraryAssemblerTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "assemble-object-library"
    }

    private struct Options: ParsableArguments {
        @Argument var inputs: [Path]
        @Option var output: Path
        @Option var linkerResponseFileFormat: ResponseFileFormat
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        do {
            let options = try Options.parse(Array(task.commandLineAsStrings.dropFirst()))
            try? executionDelegate.fs.remove(options.output)
            try executionDelegate.fs.createDirectory(options.output)
            _ = try await options.inputs.concurrentMap(maximumParallelism: 10) { input in
                try executionDelegate.fs.copy(input, to: options.output.join(input.basename))
            }
            let args = options.inputs.map { $0.strWithPosixSlashes }
            try executionDelegate.fs.write(options.output.join("args.resp"), contents: ByteString(encodingAsUTF8: ResponseFiles.responseFileContents(args: args, format: options.linkerResponseFileFormat)))
            return .succeeded
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
    }
}
