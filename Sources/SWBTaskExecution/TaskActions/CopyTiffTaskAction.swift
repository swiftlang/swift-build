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

public import SWBUtil
import SWBLibc
public import SWBCore
import Foundation

/// Concrete implementation of task for copying a property list file.
public final class CopyTiffTaskAction: TaskAction {

    /// The parsed command line options.
    private struct Options {
        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate) {
            outputDelegate.emitOutput { stream in
                stream <<< "usage: \(name) [--compression none|<method>] --outdir <path> {input-file}*\n"
                stream <<< "  --compression {none|<tiffutil method>\n"
                stream <<< "      The name of a compression method for use with tiffutil(1).\n"
                stream <<< "  --outdir <path>\n"
                stream <<< "      Specify the output directory to copy to.\n"
            }
        }

        /// The name of the compression method, if provided.
        let compression: String?

        /// The list of input paths.
        let inputs: [Path]

        /// The output directory.
        //
        // FIXME: This tool needs to change to allow destination file options. Currently, the build system is unable to effect a copy that also renames.
        let outputDirectory: Path

        init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate) {
            var compression: String? = nil
            var foundOutdirOption = false
            var outputDirectory: Path? = nil
            var hadErrors = false
            func error(_ message: String) {
                outputDelegate.emitError(message)
                hadErrors = true
            }

            // Parse the arguments.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"
        argumentParsing:
            while let arg = generator.next() {
                switch arg {
                case "--":
                    break argumentParsing

                case "--compression":
                    guard let name = generator.next() else {
                        error("missing argument for option: '\(arg)'")
                        continue
                    }
                    if name == "none" {
                        compression = nil
                    } else {
                        compression = name
                    }

                case "--outdir":
                    foundOutdirOption = true
                    guard let value = generator.next() else {
                        error("missing argument for option: '\(arg)'")
                        continue
                    }
                    outputDirectory = Path(value)

                default:
                    error("unrecognized argument: '\(arg)'")
                }
            }

            // All remaining arguments are input paths.
            let inputs = generator.map { Path($0 )}

            // Diagnose missing inputs.
            if inputs.isEmpty {
                error("no input files specified")
            }

            // Diagnose missing output directory option.
            if outputDirectory == nil && !foundOutdirOption {
                error("missing required '--outdir' argument")
                outputDirectory = Path("<<error>>")
            }

            // If there were errors, emit the usage and return an error.
            if hadErrors {
                outputDelegate.emitOutput("\n")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }

            // Initialize contents.
            self.compression = compression
            self.inputs = inputs
            self.outputDirectory = outputDirectory!
        }
    }

    public override class var toolIdentifier: String {
        return "copy-tiff"
    }

    public override init() {
        super.init()
    }

    public override func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        // Parse the arguments.
        guard let options = Options(task.commandLineAsStrings, outputDelegate) else {
            return .failed
        }

        // Copy each input.
        for input in options.inputs {
            // Make absolute.
            let input = task.workingDirectory.join(input)
            let output = task.workingDirectory.join(options.outputDirectory).join(input.basename)

            // If we have a compression argument, pass through tiffutil.
            if let compression = options.compression {
                let tiffutilCommand = ["/usr/bin/tiffutil", "-\(compression)", input.str, "-out", output.str]

                let processDelegate = TaskProcessDelegate(outputDelegate: outputDelegate)
                do {
                    try await spawn(commandLine: tiffutilCommand, environment: task.environment.bindingsDictionary, workingDirectory: task.workingDirectory.str, dynamicExecutionDelegate: dynamicExecutionDelegate, clientDelegate: clientDelegate, processDelegate: processDelegate)
                } catch {
                    outputDelegate.error(error.localizedDescription)
                    return .failed
                }
                if let error = processDelegate.executionError {
                    outputDelegate.error(error)
                    return .failed
                }
                if let commandResult = processDelegate.commandResult, commandResult != .succeeded {
                    outputDelegate.emitError("tiffutil failed")
                    return commandResult
                }
            } else {
                // Otherwise, just copy the file.
                //
                // FIXME: We need to factor this to common code, we need error handling support, and we need to preserve permissions probably.

                // Read the input file.
                let contents: ByteString
                do {
                    contents = try executionDelegate.fs.read(input)
                }
                catch {
                    outputDelegate.emitError("unable to read input file '\(input.str)': \(error.localizedDescription)")
                    return .failed
                }

                // FIXME: The native build system would remove the old file if it existed, perform the copy, then update the mod time on the new file.
                do {
                    try executionDelegate.fs.write(output, contents: contents)
                }
                catch {
                    outputDelegate.emitError("unable to write file '\(output.str)': \(error.localizedDescription)")
                    return .failed
                }
            }
        }

        return .succeeded
    }


    // Serialization


    public override func serialize<T: Serializer>(to serializer: T)
    {
        super.serialize(to: serializer)
    }

    public required init(from deserializer: any Deserializer) throws
    {
        try super.init(from: deserializer)
    }
}
