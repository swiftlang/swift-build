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
import SWBUtil

public final class ClangModuleVerifierInputGeneratorTaskAction: TaskAction {

    public override class var toolIdentifier: String {
        return "modules-verifier-task"
    }

    private struct Options {
        var language: ModuleVerifierLanguage
        var inputFramework: Path
        var mainOutput: Path
        var headerOutput: Path
        var moduleMapOutput: Path

        init?(commandLine: some Sequence<String>, outputDelegate: any TaskOutputDelegate) {
            var iterator = commandLine.makeIterator()
            _ = iterator.next() // Skip argv[0]
            guard let inputFramework = iterator.next().map(Path.init) else {
                outputDelegate.emitError("no input framework specified")
                return nil
            }

            var language: ModuleVerifierLanguage? = nil
            var mainOutput: Path? = nil
            var headerOutput: Path? = nil
            var moduleMapOutput: Path? = nil

            while let arg = iterator.next() {
                switch arg {
                case "--language":
                    guard let languageName = iterator.next() else {
                        outputDelegate.emitError("missing argument to \(arg)")
                        return nil
                    }
                    language = ModuleVerifierLanguage(rawValue: languageName)
                    if language == nil {
                        outputDelegate.emitError("unrecognized language '\(languageName)'")
                        return nil
                    }
                case "--main-output":
                    guard let path = iterator.next() else {
                        outputDelegate.emitError("missing argument to \(arg)")
                        return nil
                    }
                    mainOutput = Path(path)
                case "--header-output":
                    guard let path = iterator.next() else {
                        outputDelegate.emitError("missing argument to \(arg)")
                        return nil
                    }
                    headerOutput = Path(path)
                case "--module-map-output":
                    guard let path = iterator.next() else {
                        outputDelegate.emitError("missing argument to \(arg)")
                        return nil
                    }
                    moduleMapOutput = Path(path)
                default:
                    outputDelegate.emitError("unknown argument '\(arg)'")
                    return nil
                }
            }

            if language == nil {
                outputDelegate.emitError("missing required argument --language")
                return nil
            }
            if mainOutput == nil {
                outputDelegate.emitError("missing required argument --main-output")
                return nil
            }
            if headerOutput == nil {
                outputDelegate.emitError("missing required argument --header-output")
                return nil
            }
            if moduleMapOutput == nil {
                outputDelegate.emitError("missing required argument --module-map-output")
                return nil
            }

            self.language = language!
            self.inputFramework = inputFramework
            self.mainOutput = mainOutput!
            self.headerOutput = headerOutput!
            self.moduleMapOutput = moduleMapOutput!
        }
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        guard let options = Options(commandLine: task.commandLineAsStrings, outputDelegate: outputDelegate) else {
            return .failed
        }

        let specLookup = SpecLookupCtxt(specRegistry: executionDelegate.specRegistry, platform: nil)
        let fs = executionDelegate.fs

        let framework: ModuleVerifierFramework
        do {
            framework = try ModuleVerifierFramework(directory: options.inputFramework, fs: fs, inSDK: false, specLookupContext: specLookup)
        } catch {
            outputDelegate.emitError("failed to read framework '\(options.inputFramework.str)': \(error)")
            return .failed
        }

        let (verifyPublic, verifyPrivate, diagnostics) = ModuleVerifierModuleMapFileVerifier.verify(framework: framework)
        var hadError = false
        for diagnostic in diagnostics {
            outputDelegate.emit(diagnostic)
            if diagnostic.behavior == .error {
                hadError = true
            }
        }
        if hadError {
            return .failed
        }

        do {
            try fs.createDirectory(options.mainOutput.dirname, recursive: true)
            try fs.createDirectory(options.headerOutput.dirname, recursive: true)
            try fs.createDirectory(options.moduleMapOutput.dirname, recursive: true)
        } catch {
            outputDelegate.emitError("failed to create directory structure: \(error)")
            return .failed
        }

        do {
            try fs.write(options.mainOutput, contents: ByteString(encodingAsUTF8: """
            \(options.language.includeStatement) <Test/Test.h>
            """))
        } catch {
            outputDelegate.emitError("failed to write \(options.mainOutput): \(error)")
            return .failed
        }
        do {
            var output: ByteString = ""
            if verifyPublic {
                output += ByteString(encodingAsUTF8: framework.allModularHeaderIncludes(language: options.language))
            }
            if verifyPrivate && framework.hasPrivateHeaders {
                if !output.isEmpty {
                    output += "\n";
                }
                output += ByteString(encodingAsUTF8: """
                // Private
                \(framework.allModularPrivateHeaderIncludes(language: options.language))
                """)
            }

            try fs.write(options.headerOutput, contents: output)
        } catch {
            outputDelegate.emitError("failed to write \(options.headerOutput): \(error)")
            return .failed
        }
        do {
            try fs.write(options.moduleMapOutput, contents: """
            framework module Test {
                umbrella header "Test.h"

                export *
                module * { export * }
            }
            """)
        } catch {
            outputDelegate.emitError("failed to write \(options.moduleMapOutput): \(error)")
            return .failed
        }

        return .succeeded
    }
}
