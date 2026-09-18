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

            // Track the names already claimed by earlier inputs, so that disambiguated names can't collide either.
            var usedDestinationNames: Set<String> = []
            var inputsWithDestinations: [(source: Path, destination: String)] = []

            // Process each input to determine its destination name
            for input in options.inputs {
                // Always use lowercase basenames to avoid collisions on case-insensitive filesystems
                let basename = Path(input.basename.lowercased())
                var destinationName = basename.str
                if usedDestinationNames.contains(destinationName) {
                    // Duplicate detected, add a suffix before the extension. Keep incrementing until we land on a name
                    // no other input has claimed, since an input may already be named like a disambiguated one.
                    let nameWithoutSuffix = basename.basenameWithoutSuffix
                    let suffix = basename.fileSuffix  // Includes the dot
                    var count = 1
                    repeat {
                        destinationName = "\(nameWithoutSuffix)-\(count)\(suffix)"
                        count += 1
                    } while usedDestinationNames.contains(destinationName)
                }

                usedDestinationNames.insert(destinationName)
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
