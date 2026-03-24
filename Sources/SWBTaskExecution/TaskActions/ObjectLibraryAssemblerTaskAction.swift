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
            try executionDelegate.fs.createDirectory(options.output, recursive: true)

            // Track basename usage for duplicate detection and build destination mappings
            var basenameCount: [String: Int] = [:]
            var inputsWithDestinations: [(source: Path, destination: String)] = []

            // Process each input to determine its destination name
            for input in options.inputs {
                let basename = input.basename
                let count = basenameCount[basename, default: 0]
                basenameCount[basename] = count + 1

                let destinationName: String
                if count == 0 {
                    // First occurrence, use original name
                    destinationName = basename
                } else {
                    // Duplicate detected, add suffix before extension
                    let nameWithoutSuffix = input.withoutSuffix
                    let suffix = input.fileSuffix  // Includes the dot
                    destinationName = "\(Path(nameWithoutSuffix).basename)-\(count)\(suffix)"
                }

                inputsWithDestinations.append((source: input, destination: destinationName))
            }

            // Copy files with their resolved destination names
            for item in inputsWithDestinations {
                let destinationPath = options.output.join(item.destination)
                try executionDelegate.fs.copy(item.source, to: destinationPath)
            }

            // Build args array with flattened paths
            let args = inputsWithDestinations.map { item in
                options.output.join(item.destination).strWithPosixSlashes
            }

            try executionDelegate.fs.write(options.output.join("args.resp"), contents: ByteString(encodingAsUTF8: ResponseFiles.responseFileContents(args: args, format: options.linkerResponseFileFormat)))
            return .succeeded
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }
    }
}
