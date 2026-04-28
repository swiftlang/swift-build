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
        @Argument var inputs: [Path] = []
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
            for inputPath in options.inputs {
                let variableName = inputPath.basename.mangledToC99ExtendedIdentifier()
                let bytes = try fs.read(inputPath).bytes
                let fileContent = bytes.map { String($0) }.joined(separator: ",")
                content += "static let \(variableName): [UInt8] = [\(fileContent)]\n"
            }
            content += "}"
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
