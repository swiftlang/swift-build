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
        @Option(name: .customLong("byte-array")) var byteArrayInputs: [Path] = []
        @Option(name: .customLong("object")) var objectInputs: [Path] = []
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
            var content = "struct PackageResources {\n"
            for inputPath in options.byteArrayInputs {
                let variableName = inputPath.basename.mangledToC99ExtendedIdentifier()
                let bytes = try fs.read(inputPath).bytes
                let fileContent = bytes.map { String($0) }.joined(separator: ",")
                content += "static let \(variableName): [UInt8] = [\(fileContent)]\n"
            }

            var declarations = ""
            for inputPath in options.objectInputs {
                let info = EmbeddedResourceObjectInfo(
                    moduleName: options.moduleName,
                    path: inputPath,
                    outputDirectory: options.output.dirname
                )
                let byteCount = try fs.getFileInfo(inputPath).size
                guard byteCount >= 0 else {
                    throw StubError.error("invalid size for embedded resource '\(inputPath.str)'")
                }

                // #embed uses header-name syntax, not C string escaping. Use a
                // generated basename so quotes and newlines in resource paths
                // cannot change the directive. Copy bytes without parsing them.
                let payloadOutput = info.payloadPath
                if fs.exists(payloadOutput) {
                    try fs.remove(payloadOutput)
                }
                try fs.copy(inputPath, to: payloadOutput)
                let cSource =
                    """
                    #if defined(__clang__)
                    #pragma clang diagnostic ignored "-Wc23-extensions"
                    #endif
                    #if !defined(__has_embed)
                    #error "Object-file resource embedding requires a C compiler with #embed support"
                    #endif
                    static const unsigned char resource_bytes[] = {
                    #embed "\(payloadOutput.basename)" if_empty(0)
                    };
                    __attribute__((visibility("hidden")))
                    const unsigned char *const \(info.dataSymbol) = resource_bytes;
                    """
                _ = try fs.writeIfChanged(info.sourcePath, contents: ByteString(encodingAsUTF8: cSource + "\n"))

                let swiftDataName = "_\(info.dataSymbol)"
                declarations +=
                    """
                    // Both the pointer and its statically embedded bytes are immutable.
                    @_silgen_name("\(info.dataSymbol)")
                    nonisolated(unsafe) private let \(swiftDataName): UnsafeRawPointer

                    """
                content +=
                    """
                    static var \(info.variableName): RawSpan {
                        @_lifetime(immortal)
                        get {
                            let span = unsafe RawSpan(_unsafeStart: \(swiftDataName), byteCount: \(byteCount))
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
