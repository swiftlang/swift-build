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
import SWBMacro
import Foundation

/// Concrete implementation of task for copying a property list file.
public final class CopyPlistTaskAction: TaskAction {

    /// The parsed command line options.
    private struct Options {
        enum ConversionKind: String {
            /// Perform no conversion.
            case sameAsInput = "same-as-input"
            /// Convert to binary.
            case binary = "binary1"
            /// Convert to the XML1 format.
            case xml1 = "xml1"

            // Note that Foundation no longer supports writing the OpenStep plist format.

            init?(name: String) {
                switch name {
                case "same-as-input", "SameAsInput":
                    self = .sameAsInput
                    return
                case "binary1":
                    self = .binary
                    return
                case "xml1":
                    self = .xml1
                    return
                default:
                    return nil
                }
            }
        }

        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate) {
            outputDelegate.emitOutput { stream in
                stream <<< "usage: \(name) [--validate] [--convert <name>] --outdir <path> -- {input-file}*\n"
                stream <<< "  --validate\n"
                stream <<< "      Validate the property list contents when copied.\n"
                stream <<< "  --convert {same-as-input|binary|xml1}\n"
                stream <<< "      Convert the property list to the named format when copied.\n"
                stream <<< "  --outdir <path>\n"
                stream <<< "      Specify the output directory to copy to.\n"
                stream <<< "  --outfilename\n"
                stream <<< "      Specify the output file name.\n"
                stream <<< "  --macro-expansion key value\n"
                stream <<< "      A macro name and value used to expand macros in the plist. If this is specified at least once, macro expansion will be performed.\n"
                stream <<< "  --copy-value key path\n"
                stream <<< "      Set the value of the specified top-level key to the value of the top-level key of the same from the plist at the specified path.\n"
            }
        }

        /// Whether or not to validate the input.
        let validate: Bool

        /// The type of conversion to perform.
        let convert: ConversionKind

        /// The list of input paths.
        let inputs: [Path]

        /// The output name for the file.
        let outfilename: String?

        /// The output directory.
        let outputDirectory: Path

        /// Macro expression names and corresponding replacement values.
        let macroExpansions: [String: String]

        /// Top level key names and paths from which to source the values.
        let copiedValues: [String: Path]

        init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate) {
            var validate = false
            var convert = ConversionKind.sameAsInput
            var foundOutdirOption = false
            var outputDirectory: Path? = nil
            var macroExpansions = [String: String]()
            var copiedValues = [String: Path]()
            var hadErrors = false
            var outfilename: String? = nil
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

                case "--validate":
                    validate = true

                case "--convert":
                    guard let name = generator.next() else {
                        error("missing argument for option: '\(arg)'")
                        continue
                    }
                    guard let kind = ConversionKind(name: name) else {
                        error("unrecognized argument to '\(arg)': '\(name)'")
                        continue
                    }
                    convert = kind

                case "--outdir":
                    foundOutdirOption = true
                    guard let value = generator.next() else {
                        error("missing argument for option: '\(arg)'")
                        continue
                    }
                    outputDirectory = Path(value)

                case "--outfilename":
                    guard let value = generator.next() else {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    outfilename = value

                case "--macro-expansion":
                    guard let key = generator.next(), let value = generator.next() else {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    if macroExpansions.contains(key) {
                        error("duplicate macro expansion value for '\(key)'")
                        continue
                    }
                    macroExpansions[key] = value

                case "--copy-value":
                    guard let key = generator.next(), let value = generator.next() else {
                        error("missing argument for option: \(arg)")
                        continue
                    }
                    if copiedValues.contains(key) {
                        error("duplicate path reference for '\(key)'")
                        continue
                    }
                    copiedValues[key] = Path(value)

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
            self.validate = validate
            self.convert = convert
            self.inputs = inputs
            self.outputDirectory = outputDirectory!
            self.outfilename = outfilename
            self.macroExpansions = macroExpansions
            self.copiedValues = copiedValues
        }
    }

    public override class var toolIdentifier: String {
        return "copy-plist"
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

        if !options.macroExpansions.isEmpty && (!options.validate || options.convert == .sameAsInput) {
            outputDelegate.emitError("cannot perform macro expansion unless validation is being performed and a conversion format is being specified")
            return .failed
        }

        // Copy each input.
        for input in options.inputs {
            // Make absolute.
            let input = task.workingDirectory.join(input)
            let output = task.workingDirectory.join(options.outputDirectory).join(options.outfilename ?? input.basename)

            // Read the input file.
            let contents: ByteString
            do {
                contents = try executionDelegate.fs.read(input)
            }
            catch {
                outputDelegate.emitError("unable to read input file '\(input.str)': \(error.localizedDescription)")
                return .failed
            }

            // Copy the file.
            if !options.validate && options.convert == .sameAsInput {
                // If we're not validating the input, and we're using the same format as the input file, then we just emit the contents to the output path.
                // Note that this is the only way to end up with an OpenStep-format output file, since Foundation no longer supports writing that format.
                // FIXME: The native build system would remove the old file if it existed, perform the copy, then update the mod time on the new file.
                do {
                    try executionDelegate.fs.write(output, contents: contents)
                }
                catch {
                    outputDelegate.emitError("unable to write file '\(output.str)': \(error.localizedDescription)")
                    return .failed
                }
            } else {
                // Convert the input to a property list, since we need to either validate it (which we do by trying to read it as a plist) or convert it to another format (which means we need to make it a plist along the way).
                var plist: PropertyListItem
                do {
                    // Rev-lock hack
                    var contents = try ByteString(PropertyList.fromBytes(contents.bytes).asBytes(.xml))
                    contents = ByteString(Array(contents.unsafeStringValue
                        .replacingOccurrences(of: ">WRAPPEDPRODUCTNAME<", with: ">$(WRAPPEDPRODUCTNAME)<")
                        .replacingOccurrences(of: ">WRAPPEDPRODUCTBUNDLEIDENTIFIER<", with: ">$(WRAPPEDPRODUCTBUNDLEIDENTIFIER)<")
                        .replacingOccurrences(of: ">TESTPRODUCTNAME<", with: ">$(TESTPRODUCTNAME)<")
                        .replacingOccurrences(of: ">TESTPRODUCTBUNDLEIDENTIFIER<", with: ">$(TESTPRODUCTBUNDLEIDENTIFIER)<").utf8))

                    let p = try PropertyList.fromBytes(contents.bytes)
                    if !options.macroExpansions.isEmpty {
                        let namespace = MacroNamespace()
                        var table = MacroValueAssignmentTable(namespace: namespace)
                        for (key, value) in options.macroExpansions {
                            table.push(namespace.lookupOrDeclareMacro(StringMacroDeclaration.self, key), namespace.parseLiteralString(value))
                        }
                        let scope = MacroEvaluationScope(table: table)
                        plist = p.byEvaluatingMacros(withScope: scope)
                    } else {
                        plist = p
                    }

                    for (key, path) in options.copiedValues {
                        if case var .plDict(value) = plist {
                            value[key] = try PropertyList.fromPath(path, fs: executionDelegate.fs).dictValue?[key]
                            plist = .plDict(value)
                        }
                    }
                } catch {
                    outputDelegate.emitError("unable to read input file as a property list: \(error.localizedDescription)")
                    return .failed
                }

                // Convert to the output data.
                let outputData: [UInt8]
                switch options.convert {
                case .sameAsInput:
                    outputData = contents.bytes

                case .xml1, .binary:
                    do {
                        outputData = try plist.asBytes(options.convert == .binary ? .binary : .xml)
                    } catch {
                        outputDelegate.emitError("unable to create \(options.convert.rawValue) property list data: \(error.localizedDescription)")
                        return .failed
                    }
                }

                // Finally we can write the output file.
                // FIXME: The native build system would remove the old file if it existed, then perform the copy.
                do {
                    try executionDelegate.fs.write(output, contents: ByteString(outputData))
                }
                catch {
                    outputDelegate.emitError("unable to write file '\(output.str)': \(error.localizedDescription)")
                    return .failed
                }
            }
        }

        // If copies of all inputs succeeded, then victory!
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
