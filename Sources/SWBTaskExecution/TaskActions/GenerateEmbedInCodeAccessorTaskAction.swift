//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBCore
import SWBLibc
public import SWBUtil
import ArgumentParser
import Foundation

/// Generates the `embedded_resources.swift` accessor for resources marked `embedInCode`.
public final class GenerateEmbedInCodeAccessorTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "generate-embed-in-code-accessor"
    }

    private struct Options: ParsableArguments {
        @Option var output: Path
        @Option(name: .customLong("module-name")) var moduleName: String
        @Option(name: .customLong("object-format")) var objectFormat: String?
        @Option(name: .customLong("byte-array")) var byteArrayInputs: [Path] = []
        @Option(name: .customLong("object")) var objectInputs: [Path] = []
        @Option(name: .customLong("object-seed")) var objectSeedOutputs: [Path] = []
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
        let options: Options
        do {
            options = try Options.parse(Array(task.commandLineAsStrings.dropFirst()))
        } catch {
            outputDelegate.emitError("\(error)")
            return .failed
        }

        let fs = executionDelegate.fs
        do {
            guard options.objectInputs.count == options.objectSeedOutputs.count else {
                throw StubError.error("every object resource must have a seed output")
            }
            let objectFormat = try options.objectFormat.map { value in
                guard let format = EmbeddedResourceObjectFormat(rawValue: value) else {
                    throw StubError.error("unsupported embedded resource object format '\(value)'")
                }
                return format
            }
            if !options.objectInputs.isEmpty && objectFormat == nil {
                throw StubError.error("object resources require an object format")
            }

            var content = "struct PackageResources {\n"
            for inputPath in options.byteArrayInputs {
                let variableName = inputPath.basename.mangledToC99ExtendedIdentifier()
                let bytes = try fs.read(inputPath).bytes
                let fileContent = bytes.map { String($0) }.joined(separator: ",")
                content += "static let \(variableName): [UInt8] = [\(fileContent)]\n"
            }

            var declarations = ""
            for (inputPath, seedOutput) in zip(options.objectInputs, options.objectSeedOutputs) {
                guard let objectFormat else {
                    throw StubError.error("missing object format")
                }
                let info = EmbeddedResourceObjectInfo(
                    moduleName: options.moduleName,
                    path: inputPath,
                    objectFormat: objectFormat
                )
                let byteCount = try fs.getFileInfo(inputPath).size
                guard byteCount >= 0 else {
                    throw StubError.error("invalid size for embedded resource '\(inputPath.str)'")
                }

                // Target Clang turns this seed into an object with the correct
                // architecture and format, which llvm-objcopy can then modify.
                let seedSource: String
                switch objectFormat {
                case .macho:
                    seedSource =
                        """
                        .section __TEXT,\(info.sectionName)
                        .globl _\(info.dataSymbol)
                        .private_extern _\(info.dataSymbol)
                        _\(info.dataSymbol):
                        .space \(max(byteCount, 1))
                        """
                case .elf:
                    seedSource = ".text"
                }
                _ = try fs.writeIfChanged(seedOutput, contents: ByteString(encodingAsUTF8: seedSource + "\n"))

                let swiftDataName = "_\(info.dataSymbol)"
                declarations +=
                    """
                    @_silgen_name("\(info.dataSymbol)")
                    private let \(swiftDataName): UInt8

                    """
                content +=
                    """
                    static var \(info.variableName): Span<UInt8> {
                        @_lifetime(immortal)
                        get {
                            let start = withUnsafePointer(to: \(swiftDataName)) { $0 }
                            let span = unsafe Span(_unsafeStart: start, count: \(byteCount))
                            return unsafe _overrideLifetime(span, copying: ())
                        }
                    }
                    """
                content += "\n"
            }
            content += "}"
            content = declarations + content
            _ = try fs.writeIfChanged(options.output, contents: ByteString(encodingAsUTF8: content))
        } catch {
            outputDelegate.emitError("unable to write file '\(options.output.str)': \(error.localizedDescription)")
            return .failed
        }

        return .succeeded
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        super.serialize(to: serializer)
    }

    public required init(from deserializer: any Deserializer) throws {
        try super.init(from: deserializer)
    }
}
