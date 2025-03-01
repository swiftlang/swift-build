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

import struct Foundation.Date
import class Foundation.NSError

public import SWBCore
import SWBLibc
public import SWBUtil
public import SWBMacro

/// Concrete implementation of task for processing product entitlements.
public final class ProcessProductEntitlementsTaskAction: TaskAction
{
    /// The scope the task should use to evaluate build settings.
    let scope: MacroEvaluationScope

    /// The merged entitlements.
    let entitlements: PropertyListItem

    /// When performing a simulator build, we will have both signed and simulated entitlements; this enum indicates which variant of entitlements this task action is processing.
    /// macOS and device builds will normally have only signed entitlements.
    let entitlementsVariant: EntitlementsVariant

    /// The platform we're building for.
    let destinationPlatformName: String

    // FIXME: This is not presently used, but may be needed for <rdar://problem/29115067> [Swift Build] Implement workaround for entitlements files generated during a build
    //
    /// The input file path of the entitlements.  This is only used if we detect that the build has modified this file.
    let entitlementsFilePath: Path?

    /// The timestamp of the latest modification of the entitlements on `init`
    let entitlementsModificationTimestamp: Result<Date, StubError>?

    public init(scope: MacroEvaluationScope, fs: any FSProxy, entitlements: PropertyListItem, entitlementsVariant: EntitlementsVariant, destinationPlatformName: String, entitlementsFilePath: Path?)
    {
        self.scope = scope

        self.entitlements = entitlements
        self.entitlementsVariant = entitlementsVariant
        self.destinationPlatformName = destinationPlatformName
        self.entitlementsFilePath = entitlementsFilePath
        if let entitlementsFilePath, fs.exists(entitlementsFilePath) {
            do {
                self.entitlementsModificationTimestamp = .success(try fs.getFileInfo(entitlementsFilePath).modificationDate)
            } catch {
                self.entitlementsModificationTimestamp = .failure(StubError.error(String(describing: error)))
            }
        } else {
            self.entitlementsModificationTimestamp = nil
        }

        // The entitlements parameters must be PropertyListItem.plDict elements.
        guard case .plDict(_) = self.entitlements else { fatalError("entitlements must be a PropertyListItem.plDict") }
        guard !destinationPlatformName.isEmpty else { fatalError("destinationPlatformName must be non-empty") }
        guard entitlementsFilePath == nil || entitlementsFilePath!.isAbsolute else { fatalError("entitlementsFilePath, if set, must be an absolute path") }

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
                stream <<< "usage: \(name) -entitlements [-format <name>] <input-file> -o <output-path>\n"
                stream <<< "  -entitlements\n"
                stream <<< "      Handle entitlements in the input file.  This option is required.\n"
                stream <<< "  --format {none|binary|xml}\n"
                stream <<< "      The output format of the entitlements.\n"
                stream <<< "  -o <path>\n"
                stream <<< "      Specify the output path to which to write the entitlements.\n"
            }
        }

        /// The type of conversion to perform.
        let format: FormatKind

        /// Whether to process the entitlements.
        let processEntitlements: Bool

        /// The path to the input file.
        let inputPath: Path?

        /// The path to the output file.
        let outputPath: Path

        init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate)
        {
            var format = FormatKind.sameAsInput
            var processEntitlements = false
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
                case "-entitlements":
                    // The '-entitlements' option takes no arguments.
                    processEntitlements = true

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

            // Diagnose missing -entitlements option.
            if !processEntitlements
            {
                error("missing required option: -entitlements")
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
            self.processEntitlements = processEntitlements
            self.inputPath = inputPath
            self.outputPath = outputPath!
        }
    }

    public override class var toolIdentifier: String
    {
        return "process-product-entitlements"
    }

    public override func getSignature(_ task: any ExecutableTask, executionDelegate: any TaskExecutionDelegate) -> ByteString
    {
        // If the scheme command changes then our signature changes so we have to re-run.
        return super.getSignature(task, executionDelegate: executionDelegate) + ByteString(encodingAsUTF8: executionDelegate.schemeCommand?.description ?? "<nil>")
    }

    override public func performTaskAction(
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

        // Make paths absolute.
//        let input = task.workingDirectory.join(options.inputPath)     // Not presently used
        let output = task.workingDirectory.join(options.outputPath)

        // Updating entitlements is not something that is actively encouraged or supported, however, this is a compatibility pain point for certain projects that we need to maintain some ability to do this. A better approach is to plumb this through the system so that we can track this as a proper dependency mechanism, potentially through our virtual task producers... however, until then, we enable this functionality for those existing clients.

        // Also, we never modify the signed entitlements when building for simulators and ENTITLEMENTS_DESTINATION is __entitlements, since those are only expected to contain get-task-allow; see rdar://55324156.
        let entitlementsVariantToModify: EntitlementsVariant = scope.evaluate(BuiltinMacros.ENTITLEMENTS_DESTINATION) == .entitlementsSection ? .simulated : .signed
        let allowEntitlementsModification = entitlementsVariantToModify == entitlementsVariant

        var userModifiedEntitlements: PropertyListItem?
        if let entitlementsFilePath {
            let currentModificationTimestamp: Date
            do {
                currentModificationTimestamp = try executionDelegate.fs.getFileInfo(entitlementsFilePath).modificationDate
            } catch {
                outputDelegate.emitError("could not read timestamp of entitlements file '\(entitlementsFilePath.str)': \(error.localizedDescription)")
                return .failed
            }

            let originalModificationTimestamp: Date?
            do {
                originalModificationTimestamp = try entitlementsModificationTimestamp?.get()
            } catch {
                outputDelegate.emitError("could not read original timestamp of entitlements file '\(entitlementsFilePath.str)': \(error.localizedDescription)")
                return .failed
            }

            if originalModificationTimestamp != currentModificationTimestamp {
                if scope.evaluate(BuiltinMacros.CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION) == false {
                    outputDelegate.emitError("Entitlements file \"\(entitlementsFilePath.basename)\" was modified during the build, which is not supported. You can disable this error by setting 'CODE_SIGN_ALLOW_ENTITLEMENTS_MODIFICATION' to 'YES', however this may cause the built product's code signature or provisioning profile to contain incorrect entitlements.")
                    return .failed
                }
                else {
                    let plist: PropertyListItem
                    do {
                        plist = try PropertyList.fromBytes(executionDelegate.fs.read(entitlementsFilePath).bytes)
                    } catch {
                        outputDelegate.emitError("could not read entitlements file '\(entitlementsFilePath.str)': \(error.localizedDescription)")
                        return .failed
                    }

                    if !allowEntitlementsModification {
                        outputDelegate.emitNote("Entitlements file \"\(entitlementsFilePath.basename)\" was modified during the build. Ignoring user-modified entitlements because simulator binaries must only have get-task-allow in their signed entitlements.")
                    } else if plist != entitlements {
                        outputDelegate.emitNote("Entitlements file \"\(entitlementsFilePath.basename)\" was modified during the build. Using user-modified entitlements:\n\n\(plist.unsafePropertyList)\n\nOriginal entitlements:\n\n\(entitlements.unsafePropertyList)")
                        userModifiedEntitlements = plist
                    }
                }
            }
        }

        let effectiveEntitlements = applyTestingEntitlementsIfNeeded(to: userModifiedEntitlements ?? entitlements, executionDelegate, outputDelegate)

        do {
            try executionDelegate.fs.write(output, contents: ByteString(effectiveEntitlements.asBytes(.xml)))
        }
        catch let error as NSError {
            outputDelegate.emitError("could not write entitlements file '\(output.str)': \(error.localizedDescription)")
            return .failed
        }

        return .succeeded
    }

    private enum TestingEntitlement: CaseIterable {
        // This entitlement ensures that the test runner can read its .xctestconfiguration file and load support frameworks from inside Xcode.app.
        case fileSystem

        // This entitlement allows the test process to open XPC connections to relevant daemons.
        case machLookup

        var key: String {
            switch self {
            case .fileSystem:
                return "com.apple.security.temporary-exception.files.absolute-path.read-only"
            case .machLookup:
                return "com.apple.security.temporary-exception.mach-lookup.global-name"
            }
        }

        var value: PropertyListItem {
            switch self {
            case .fileSystem:
                return ["/"].propertyListItem
            case .machLookup:
                return ["com.apple.testmanagerd", "com.apple.dt.testmanagerd.runner", "com.apple.coresymbolicationd"].propertyListItem
            }
        }

        static var allEntitlements: [String: PropertyListItem] {
            return Dictionary(uniqueKeysWithValues: allCases.map { entitlement in
                return (entitlement.key, entitlement.value)
            })
        }
    }

    private func applyTestingEntitlementsIfNeeded(to entitlements: PropertyListItem, _ executionDelegate: any TaskExecutionDelegate, _ outputDelegate: any TaskOutputDelegate) -> PropertyListItem {
        // Unit testing and profiling with sandboxed Mac applications require additional entitlements.
        guard (executionDelegate.schemeCommand == .test || executionDelegate.schemeCommand == .profile) else {
            return entitlements
        }
        guard destinationPlatformName == "macosx" else {
            return entitlements
        }

        guard case .plDict(let entitlementsDict) = entitlements else {
            outputDelegate.emitWarning("Unable to apply test host sandboxing entitlements due to unexpected input data")
            return entitlements
        }

        let testingEntitlements = TestingEntitlement.allEntitlements

        // Add the entitlements above to the dictionary, augmenting rather than replacing existing values if there are any.
        let augmentedDict = entitlementsDict.merging(testingEntitlements) { (current, new) in
            let currentValuesArray: [PropertyListItem]
            if case .plArray(let array) = current {
                currentValuesArray = array
            } else {
                currentValuesArray = [current]
            }

            let newValuesArray: [PropertyListItem]
            if case .plArray(let array) = new {
                newValuesArray = array
            } else {
                newValuesArray = [new]
            }

            return .plArray(currentValuesArray + newValuesArray)
        }

        return .plDict(augmentedDict)
    }


    // Serialization


    public override func serialize<T: Serializer>(to serializer: T)
    {
        serializer.serializeAggregate(7)
        {
            serializer.serialize(scope)
            // FIXME: <rdar://problem/40036582> We have no way to handle any errors in PropertyListItem.asBytes() here.
            serializer.serialize(try? entitlements.asBytes(.binary))
            serializer.serialize(entitlementsVariant)
            serializer.serialize(destinationPlatformName)
            serializer.serialize(entitlementsFilePath)
            serializer.serialize(entitlementsModificationTimestamp)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws
    {
        try deserializer.beginAggregate(7)
        self.scope = try deserializer.deserialize()
        self.entitlements = try PropertyList.fromBytes(try deserializer.deserialize())
        self.entitlementsVariant = try deserializer.deserialize()
        self.destinationPlatformName = try deserializer.deserialize()
        self.entitlementsFilePath = try deserializer.deserialize()
        self.entitlementsModificationTimestamp = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}
