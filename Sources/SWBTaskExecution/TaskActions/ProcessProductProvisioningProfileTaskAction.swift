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

import class Foundation.PropertyListSerialization
import class Foundation.NSError

public import SWBCore
import SWBLibc
public import SWBUtil


/// Concrete implementation of task for processing the provisioning profile for a product.
public final class ProcessProductProvisioningProfileTaskAction: TaskAction
{
    public override init()
    {
        // Presently this class' initializer doesn't do anything extra - all parameters are passed in as command-line options.
        super.init()
    }

    /// The parsed command line options.
    private struct Options
    {
        /// The output format of the task.
        enum FormatKind: String
        {
            /// Preserve the format of the input file.
            case sameAsInput = "none"
            /// Convert to binary.
            case binary = "binary"
            /// Convert to XML format.
            case xml = "xml"

            // Note that Foundation no longer supports writing the OpenStep plist format.

            init?(name: String)
            {
                switch name
                {
                case "openstep":
                    // Foundation no longer supports writing OpenStep-format property lists, so we fall back to XML.
                    self = .xml

                default:
                    // Otherwise we initialize from the raw value, if possible.
                    if let value = FormatKind(rawValue: name)
                    {
                        self = value
                        return
                    }
                    else
                    {
                        return nil
                    }
                }
            }
        }

        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate)
        {
            outputDelegate.emitOutput
            { stream in
                stream <<< "usage: \(name) [-format <name>] <input-file> -o <output-path>\n"
                stream <<< "  --format {none|binary|xml}\n"
                stream <<< "      The output format of the entitlements.\n"
                stream <<< "  -o <path>\n"
                stream <<< "      Specify the output path to which to write the entitlements.\n"
            }
        }

        /// The type of conversion to perform.
        let format: FormatKind

        /// The path to the input file.
        let inputPath: Path

        /// The path to the output file.
        let outputPath: Path

        init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate)
        {
            var format = FormatKind.sameAsInput
            var inputPath: Path? = nil
            var foundOutputPathOption = false
            var outputPath: Path? = nil
            var hadErrors = false
            func error(_ message: String)
            {
                outputDelegate.emitError(message)
                hadErrors = true
            }

            // Parse the arguments.
            let generator = commandLine.makeIterator()
            // Skip the executable.
            let programName = generator.next() ?? "<<missing program name>>"
        argumentParsing:
            while let arg = generator.next()
            {
                switch arg
                {
                case "-format":
                    // The '-format' option takes a single argument: 'xml', 'binary', 'openstep' or 'none'.
                    guard let name = generator.next() else
                    {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    guard let kind = FormatKind(name: name) else
                    {
                        error("failed to parse option: \(arg) \(name)")
                        continue
                    }
                    format = kind

                case "-o":
                    // The '-o' argument take a single parameter: the output path.
                    foundOutputPathOption = true
                    guard let value = generator.next() else
                    {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    outputPath = Path(value)

                case _ where arg.hasPrefix("-"):
                    // Any other option starting with '-' is unrecognized.
                    error("unrecognized argument: \(arg)")
                    continue

                case _ where inputPath == nil:
                    // Any other option is considered to be an input path.
                    inputPath = Path(arg)

                default:
                    // But we can only have one input path.
                    error("multiple input paths specified")
                }
            }

            // Diagnose missing input path.
            if inputPath == nil
            {
                error("no input file specified")
                inputPath = Path("<<error>>")
            }

            // Diagnose missing output path option.
            if outputPath == nil && !foundOutputPathOption
            {
                error("missing required option: -o")
                outputPath = Path("<<error>>")
            }

            // If there were errors, emit the usage and return an error.
            if hadErrors
            {
                outputDelegate.emitOutput("\n")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }

            // Initialize contents.
            self.format = format
            self.inputPath = inputPath!
            self.outputPath = outputPath!
        }
    }

    public override class var toolIdentifier: String
    {
        return "process-product-provisioning-profile"
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        // Parse the arguments.
        guard let options = Options(task.commandLineAsStrings, outputDelegate) else
        {
            return .failed
        }

        // Make paths absolute.
        let input = task.workingDirectory.join(options.inputPath)     // Not presently used
        let output = task.workingDirectory.join(options.outputPath)

        // Read the input file.
        let contents: ByteString
        do
        {
            contents = try executionDelegate.fs.read(input)
        }
        catch let e
        {
            outputDelegate.emitError("unable to read input file '\(input.str)': \(e.localizedDescription)")
            return .failed
        }

        // Convert the input data to the desired output format.
        let outContents: ByteString
        var outputFormat: PropertyListSerialization.PropertyListFormat? = nil
        switch options.format
        {
        // If the output format is the same as the input format, then we just use the input contents.
        case .sameAsInput:
            outContents = contents

        // For any explicit format, we first determine the output format, then perform the conversion.
        case .binary:
            outputFormat = outputFormat ?? .binary
            fallthrough
        case .xml:
            outputFormat = outputFormat ?? .xml

            // Validate the contents of the input file as a property list.
            guard let (plist, _) = validateAsPropertyList(contents, outputDelegate) else { return .failed }

            let outBytes: [UInt8]
            do
            {
                try outBytes = plist.asBytes(outputFormat!)
            }
            catch
            {
                let errorDescription = (error as NSError).localizedDescription
                outputDelegate.emitError("unable to create \(options.format.rawValue) property list data: \(errorDescription)")
                return .failed
            }
            outContents = ByteString(outBytes)
        }

        // Finally we can write the output file.
        do
        {
            try executionDelegate.fs.write(output, contents: outContents)
        }
        catch let error as NSError
        {
            outputDelegate.emitError("could not write profile file: \(output.str): \(error.localizedDescription)")
            return .failed
        }

        return .succeeded
    }

    /// Validate that the given `contents` are a property list, with the root item being a dictionary, and return the parsed property list.
    ///
    /// If validation fails, then messages will be emitted to the `outputDelegate`, and nil will be returned.
    private func validateAsPropertyList(_ contents: ByteString, _ outputDelegate: any TaskOutputDelegate) -> (PropertyListItem, PropertyListSerialization.PropertyListFormat)?
    {
        // Validate it as a property list.  The top-level item must be a dictionary.
        let plist: PropertyListItem
        let format: PropertyListSerialization.PropertyListFormat
        do {
            try (plist, format) = PropertyList.fromBytesWithFormat(contents.bytes)
        } catch {
            let errorDescription = (error as NSError).localizedDescription
            outputDelegate.emitError("unable to read input file as a property list: \(errorDescription)")
            return nil
        }
        guard case .plDict = plist else
        {
            outputDelegate.emitError("input file is not a dictionary")
            return nil
        }

        return (plist, format)
    }


    // Serialization


    public override func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serializeAggregate(1)
        {
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(1)
        try super.init(from: deserializer)
    }
}
