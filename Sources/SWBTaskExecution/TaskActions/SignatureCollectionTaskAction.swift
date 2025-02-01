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

import struct Foundation.Data
import struct Foundation.URL
import class Foundation.PropertyListEncoder

public import SWBCore
import SWBLibc
public import SWBUtil

/// Pulls out the relevant signature information from a library and stores it in an external metadata file that can be collected later.
public final class SignatureCollectionTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "signature-collection"
    }

    fileprivate struct Options {
        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate) {
            outputDelegate.emitOutput { stream in
                stream <<< "usage: \(name) --input <path> --output <path> --outdir <path> -- {input-file}*\n"
                stream <<< "  --input <path>\n"
                stream <<< "      Specify the library to gather signature metadata for.\n"
                stream <<< "  --output <path>\n"
                stream <<< "      The output file for the signature metadata file.\n"
                stream <<< "  --info <key> <value>\n"
                stream <<< "      Additional data that should be added to the signature metadata file.\n"
            }
        }

        let input: Path
        let output: Path
        let additionalInfo: [String:String]
        let skipValidation: Bool

        init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate) {
            var inputArg: String? = nil
            var outputArg: String? = nil
            var additionalInfo: [String:String] = [:]
            var skipSignatureValidation: Bool = false

            var hadErrors: Bool = false
            func error(_ message: String) {
                outputDelegate.emitError(message)
                hadErrors = true
            }

            // Parse the arguments until we reach a '--'.
            let generator = commandLine.makeIterator()

            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"
            argumentParsing: while let arg = generator.next() {
                switch arg {
                case "--":
                    break argumentParsing

                case "--input":
                    guard let value = generator.next() else {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    inputArg = value

                case "--output":
                    guard let value = generator.next() else {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    outputArg = value

                // --info baseName foo.framework
                case "--info":
                    guard let key = generator.next() else {
                        error("missing key argument for option: \(arg)")
                        continue
                    }
                    guard let value = generator.next() else {
                        error("missing value argument for option: \(arg)")
                        continue
                    }
                    additionalInfo[key] = value

                // This is primarily used as an internal mechanism to disable verification for testing purposes.
                case "--skip-signature-validation":
                    skipSignatureValidation = true

                default:
                    error("unrecognized argument: \(arg)")
                }
            }

            if !hadErrors && inputArg == nil {
                error("missing required argument: --input")
            }

            if !hadErrors && outputArg == nil {
                error("missing required argument: --output")
            }

            if hadErrors {
                outputDelegate.emitOutput("\n")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }

            self.input = Path(inputArg!)
            self.output = Path(outputArg!)
            self.additionalInfo = additionalInfo
            self.skipValidation = skipSignatureValidation
        }
    }

    public override init() {
        super.init()
    }

    override public func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {

        guard let options = Options(task.commandLineAsStrings, outputDelegate) else {
            return .failed
        }

        do {
            let info = try await CodeSignatureInfo.load(from: options.input, additionalInfo: options.additionalInfo.isEmpty ? nil : options.additionalInfo, skipValidation: options.skipValidation)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode(info)

            let base = options.output.dirname
            try executionDelegate.fs.createDirectory(base, recursive: true)
            try executionDelegate.fs.write(options.output, contents: ByteString(data))
        }
        catch {
            outputDelegate.emitError("signature-collection failed: \(error.localizedDescription)")
            return .failed
        }

        return .succeeded
    }

    // Serialization

    public override func serialize<T: Serializer>(to serializer: T) {
        super.serialize(to: serializer)
    }

    public required init(from deserializer: any Deserializer) throws {
        try super.init(from: deserializer)
    }
}
