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
import SWBLibc
public import SWBUtil
import SWBProtocol

/// Concrete implementation of task for copying a strings file.
public final class CopyStringsFileTaskAction: TaskAction {
    /// The parsed command line options.
    fileprivate struct Options {
        enum EncodingKind: Equatable {
            /// An string encoding.
            case stringEncoding(encoding: FileTextEncoding)
            /// Binary property list.
            case binaryPlist

            init(encoding: String) {
                switch encoding {
                case "binary":
                    self = .binaryPlist
                default:
                    self = .stringEncoding(encoding: FileTextEncoding(encoding))
                }
            }
        }

        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate) {
            outputDelegate.emitOutput { stream in
                stream <<< "usage: \(name) [--validate] [--convert <name>] --outdir <path> -- {input-file}*\n"
                stream <<< "  --validate\n"
                stream <<< "      Validate the property list contents when copied.\n"
                stream <<< "  --inputencoding {encoding}\n"
                stream <<< "      The input file is in the given encoding\n"
                stream <<< "  --outputencoding {binary|{encoding}}\n"
                stream <<< "      The output file should be written as either a binary property list, or in the given encoding\n"
                stream <<< "  --outdir <path>\n"
                stream <<< "      Specify the output directory to copy to.\n"
                stream <<< "  --outfilename\n"
                stream <<< "      Specify the output file name.\n"
            }
        }

        /// Whether or not to validate the input.
        let validate: Bool

        /// The encoding of the input file specified on the command line.
        let specifiedInputEncoding: FileTextEncoding?

        /// The encoding to use when emitting the output file.  Defaults to UTF-16.
        let outputEncoding: EncodingKind

        /// The list of input paths.
        let inputs: [Path]

        /// The output name for the file.
        let outfilename: String?

        /// The output directory.
        let outputDirectory: Path

        init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate) {
            var validate = false
            var specifiedInputEncoding: FileTextEncoding?
            var outputEncoding: EncodingKind = .stringEncoding(encoding: .utf16)
            var outputDirectory: Path? = nil
            var foundOutdirOption = false
            var hadErrors = false
            var outfilename: String? = nil

            func error(_ message: String) {
                outputDelegate.error(message)
                hadErrors = true
            }
            func warning(_ message: String) {
                outputDelegate.warning(message)
            }

            // Parse the arguments until we reach a '--'.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"
            argumentParsing: while let arg = generator.next() {
                switch arg {
                case "--":
                    break argumentParsing

                case "--validate":
                    validate = true

                case "--inputencoding":
                    guard let encoding = generator.next() else {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    specifiedInputEncoding = FileTextEncoding(encoding)

                case "--outputencoding":
                    guard let encoding = generator.next() else {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    outputEncoding = EncodingKind(encoding: encoding)

                case "--outdir":
                    foundOutdirOption = true
                    guard let value = generator.next() else {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    outputDirectory = Path(value)

                case "--outfilename":
                    guard let value = generator.next() else {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    outfilename = value
                default:
                    error("unrecognized argument: \(arg)")
                }
            }

            // All remaining arguments are input paths.
            let inputs = generator.map { Path($0) }

            // Diagnose missing inputs.
            if inputs.isEmpty {
                error("no input files specified")
            }

            // Diagnose missing output directory.
            if outputDirectory == nil && !foundOutdirOption {
                error("missing required option: --outdir")
                outputDirectory = Path("<<error>>")
            }

            // If there were errors, emit the usage and return an error.
            if hadErrors {
                outputDelegate.emitOutput("\n")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }

            // Initialize contents.
            self.validate = validate
            self.specifiedInputEncoding = specifiedInputEncoding
            self.outputEncoding = outputEncoding
            self.inputs = inputs
            self.outputDirectory = outputDirectory!
            self.outfilename = outfilename
        }
    }

    public override init() {
        super.init()
    }

    public override class var toolIdentifier: String {
        return "copy-strings-file"
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
            let output = task.workingDirectory.join(options.outputDirectory).join(options.outfilename ?? input.basename)

            // Copy the file.
            //
            // FIXME: We need to factor this to common code, we need error handling support, and we need to preserve permissions probably.
            let contents: ByteString
            do {
                contents = try executionDelegate.fs.read(input)
            } catch {
                outputDelegate.error(input, "unable to read input file: \(error.localizedDescription)")
                return .failed
            }

            // Read the input string from the bytes
            guard let (rawString, detectedEncoding) = FileTextEncoding.string(from: contents.bytes, encoding: options.specifiedInputEncoding) else {
                if let specifiedInputEncoding = options.specifiedInputEncoding {
                    var message = "could not decode input file using specified encoding: \(specifiedInputEncoding.localizedName ?? specifiedInputEncoding.rawValue)"
                    if let (_, guessedEncoding) = FileTextEncoding.string(from: contents.bytes, encoding: nil) {
                        message += ", and the file contents appear to be encoded in \(guessedEncoding.localizedName ?? guessedEncoding.rawValue)"
                    }
                    outputDelegate.error(input, message)
                } else {
                    outputDelegate.error(input, "no --inputencoding specified and could not detect encoding from input file")
                }
                return .failed
            }

            if !rawString.isEmpty && options.specifiedInputEncoding == nil {
                outputDelegate.note(input, "detected encoding of input file as \(detectedEncoding.localizedName ?? detectedEncoding.rawValue)")
            }

            let string = { () -> String in
                var rawString = rawString
                if rawString.starts(with: "\u{FEFF}") {
                    outputDelegate.note(input, line: 1, column: 1, "ignoring byte-order mark in input file")
                    rawString.removeFirst()
                }

                return rawString
            }()

            // If we're either emitting it as a binary plist, or we were instructed to validate it, then we convert it to a plist.
            var plist: PropertyListItem? = nil
            if options.outputEncoding == Options.EncodingKind.binaryPlist || options.validate {
                // Remove any trailing whitespace or `PropertyList.fromString()` will fail to parse. We don't actually want to modify the file contents.
                if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Try to convert the contents to a property list.
                    do {
                        try plist = PropertyList.fromString(string)
                    } catch {
                        // If we failed, then we emit a message.
                        outputDelegate.error(input, "validation failed: \(error)")
                        return .failed
                    }
                } else {
                    // If the file was empty, then we default the property list to an empty dictionary
                    plist = PropertyListItem.plDict([:])
                }
            }

            // Convert the data to the desired output format.
            let outContents: ByteString
            switch options.outputEncoding {
            case .binaryPlist:
                // Convert the property list we created earlier to binary format.
                do {
                    let outBytes = try plist!.asBytes(.binary)
                    outContents = ByteString(outBytes)
                } catch {
                    // Conversion to binary format failed.
                    let errorDescription = (error as NSError).localizedDescription
                    outputDelegate.error("creating binary plist data failed: \(errorDescription)")
                    return .failed
                }

            case .stringEncoding(encoding: let outputEncoding):
                // Convert the input contents into the specified output format.
                if string.isEmpty {
                    outContents = ByteString()
                } else if let encoding = outputEncoding.stringEncoding, let outData = string.data(using: encoding) {
                    outContents = ByteString(outData)
                } else {
                    // Failed to generate the output data.
                    outputDelegate.error("failed to encode .strings file as \(outputEncoding.localizedName ?? outputEncoding.rawValue)")
                    return .failed
                }
            }

            // Finally, write the output data.
            do {
                try executionDelegate.fs.write(output, contents: outContents)
            } catch {
                outputDelegate.error("unable to write file '\(output.str)': \(error.localizedDescription)")
                return .failed
            }
        }

        // If copies of all inputs succeeded, success
        return .succeeded
    }

    // MARK: - Serialization

    public override func serialize<T: Serializer>(to serializer: T) {
        super.serialize(to: serializer)
    }

    public required init(from deserializer: any Deserializer) throws {
        try super.init(from: deserializer)
    }
}
