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

import SWBUtil
public import SWBCore
import Foundation

public final class XCStringsCompilerSpec: GenericCompilerSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier = "com.apple.compilers.xcstrings"

    public override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        // We expect a single input file of type xcstrings.
        // However, we use a custom grouping strategy that will group the xcstrings file with any .strings, .stringsdict, or other .xcstrings with the same basename.
        // Right now we don't support that case because it indicates table overlap, so error and early return.
        guard cbc.inputs.count == 1 else {
            assert(!cbc.inputs.isEmpty, "XCStrings task construction was passed context with no input files.")

            let xcstringsFileType = cbc.producer.lookupFileType(identifier: "text.json.xcstrings")!
            guard let xcstringsPath = cbc.inputs.first(where: { $0.fileType.conformsTo(xcstringsFileType) })?.absolutePath else {
                assertionFailure("XCStrings task construction was passed context without an xcstrings file.")
                return
            }

            if cbc.inputs.allSatisfy({ $0.fileType.conformsTo(xcstringsFileType) }) {
                delegate.error("Cannot have multiple \(xcstringsPath.basename) files in same target.", location: .path(xcstringsPath), component: .targetIntegrity)
            } else {
                delegate.error("\(xcstringsPath.basename) cannot co-exist with other .strings or .stringsdict tables with the same name.", location: .path(xcstringsPath), component: .targetIntegrity)
            }

            return
        }

        // String Catalogs do not belong inside lproj directories.
        // The exception is mul.lproj where "mul" stands for Multi-Lingual.
        // mul.lproj is used when an xcstrings file is paired with an Interface Builder file.
        if let regionVariant = cbc.input.absolutePath.regionVariantName, regionVariant != "mul" {
            delegate.error("\(cbc.input.absolutePath.basename) should not be inside an lproj directory.", location: .path(cbc.input.absolutePath), component: .targetIntegrity)
            return
        }

        let commandLine = await commandLineFromTemplate(cbc, delegate, optionContext: discoveredCommandLineToolSpecInfo(cbc.producer, cbc.scope, delegate)).map(\.asString)

        // We can't know our precise outputs statically because we don't know what languages are in the xcstrings file,
        // nor do we know if any strings have variations (which would require one or more .stringsdict outputs).
        let outputs: [Path]
        do {
            // Tell the build system that we're accessing the input xcstrings file during build planning.
            // This will invalidate the build plan when this xcstrings file changes.
            delegate.access(path: cbc.input.absolutePath)

            // We will use the command line from the xcspec, but insert --dry-run to tell xcstringstool to just tell us what files will be generated.
            var dryRunCommandLine = commandLine
            // xcstringstool compile --dry-run
            dryRunCommandLine.insert("--dry-run", at: 2)

            outputs = try await generatedFilePaths(cbc, delegate, commandLine: dryRunCommandLine, workingDirectory: cbc.producer.defaultWorkingDirectory.str, environment: environmentFromSpec(cbc, delegate).bindingsDictionary, executionDescription: "Compute XCStrings \(cbc.input.absolutePath.basename) output paths") { output in
                return output.unsafeStringValue.split(separator: "\n").map(Path.init)
            }
        } catch {
            emitErrorsFromDryRunFailure(error, path: cbc.input.absolutePath, delegate: delegate)
            return
        }

        for output in outputs {
            delegate.declareOutput(FileToBuild(absolutePath: output, inferringTypeUsing: cbc.producer))
        }

        if !outputs.isEmpty {
            delegate.createTask(type: self, ruleInfo: defaultRuleInfo(cbc, delegate), commandLine: commandLine, environment: environmentFromSpec(cbc, delegate), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [cbc.input.absolutePath], outputs: outputs, execDescription: resolveExecutionDescription(cbc, delegate), enableSandboxing: enableSandboxing)
        } else {
            // If there won't be any outputs, there's no reason to run the compiler.
            // However, we still need to leave some indication in the build graph that there was a compilable xcstrings file here so that generateLocalizationInfo can discover it.
            // So we'll use a gate task for that.
            // It will effectively be a no-op at build time.
            let inputNode = delegate.createNode(cbc.input.absolutePath)
            let outputNode = delegate.createVirtualNode("UncompiledXCStrings \(cbc.input.absolutePath.str) \(cbc.producer.configuredTarget?.guid.stringValue ?? "NoTarget")")
            delegate.createGateTask(inputs: [inputNode], output: outputNode)
        }
    }

    /// Emits errors by parsing the errors output by `xcstringstool compile --dry-run`.
    private func emitErrorsFromDryRunFailure(_ error: any Error, path: Path, delegate: any TaskGenerationDelegate) {
        // An error here almost certainly means the file couldn't be read, probably because the file is invalid.
        // We will attempt to get any actual error message output by xcstringstool.

        // But otherwise we'll fallback to a less readable representation.
        func emitFallbackError() {
            delegate.error("Could not read xcstrings file: \(error)", location: .path(path, fileLocation: nil))
        }

        let xcstringsToolOutput: ByteString?
        if let dryRunFailure = error as? RunProcessNonZeroExitError {
            switch dryRunFailure.output {
            case .separate(stdout: _, let stderr):
                xcstringsToolOutput = stderr
            case .merged(let byteString):
                xcstringsToolOutput = byteString
            case .none:
                xcstringsToolOutput = nil
            }
        } else {
            emitFallbackError()
            return
        }

        // - First comes the filename, which is an optional prefix followed by a colon.
        // - Not going to capture the filename because we already have it.
        // - Capturing errors only.
        let pattern = RegEx(patternLiteral: "^(?:[^:]+: )?error: (.*)$", options: .anchorsMatchLines)
        if let outputString = xcstringsToolOutput?.stringValue {
            let errorMessages = pattern.matchGroups(in: outputString).flatMap({ $0 })
            for message in errorMessages {
                delegate.error(message, location: .path(path, fileLocation: nil))
            }
        } else {
            emitFallbackError()
        }
    }

    public override func customOutputParserType(for task: any ExecutableTask) -> (any TaskOutputParser.Type)? {
        return StringCatalogCompilerOutputParser.self
    }

    public override func generateLocalizationInfo(for task: any ExecutableTask, input: TaskGenerateLocalizationInfoInput) -> [TaskGenerateLocalizationInfoOutput] {
        // Tell the build system about the xcstrings file we took as input.
        // No need to use a TaskPayload for this because the only data we need is input path, which is already stored on the Task.

        // These asserts just check to make sure the broader implementation hasn't changed since we wrote this method,
        // in case something here would need to change.
        // They only run in DEBUG mode.
        assert(task.inputPaths.count == 1, "If you changed the implementation of this spec to produce tasks with multiple inputs, please ensure this logic is still correct.")
        assert(task.inputPaths.allSatisfy({ $0.fileExtension == "xcstrings" }), "If you changed the implementation of this spec to take something other than xcstrings as input, please ensure this logic is still correct.")

        // Our input paths are .xcstrings (only expecting 1).
        // NOTE: We also take same-named .strings/dict files as input, but those are only used to diagnose errors and when they exist we fail before we ever generate the task.
        return [TaskGenerateLocalizationInfoOutput(compilableXCStringsPaths: task.inputPaths)]
    }

}
