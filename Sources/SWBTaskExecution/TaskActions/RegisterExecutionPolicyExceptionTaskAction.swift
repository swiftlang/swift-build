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

import struct Foundation.URL

public import SWBUtil
import SWBLibc
public import SWBCore

// Weak-linked because the framework isn't available in all contexts
#if canImport(ExecutionPolicy)
@_weakLinked import ExecutionPolicy
#endif

/// Concrete implementation of task for registering a built bundle or binary with the system to speed up execution policy checks.
public final class RegisterExecutionPolicyExceptionTaskAction: TaskAction {
    /// The parsed command line options.
    private struct Options {
        static func emitUsage(_ name: String, _ outputDelegate: any TaskOutputDelegate) {
            outputDelegate.emitOutput { stream in
                stream <<< "usage: \(name) <input-file>\n"
            }
        }

        /// The path to register.
        let input: Path

        init?(_ commandLine: AnySequence<String>, _ outputDelegate: any TaskOutputDelegate) {
            var input: Path? = nil
            var hadErrors = false
            func error(_ message: String) {
                outputDelegate.emitError(message)
                hadErrors = true
            }

            // Parse the arguments.
            let commandLine = [String](commandLine)
            let programName = commandLine.first ?? "<<missing program name>>"
            if commandLine.count != 2 {
                error("invalid number of arguments")
            } else {
                input = Path(commandLine[1])
            }

            // If there were errors, emit the usage and return an error.
            if hadErrors {
                outputDelegate.emitOutput("\n")
                Options.emitUsage(programName, outputDelegate)
                return nil
            }

            // Initialize contents.
            self.input = input!
        }
    }

    public override class var toolIdentifier: String {
        return "register-execution-policy-exception"
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

        if SWBFeatureFlag.disableExecutionPolicyExceptionRegistration.value {
            outputDelegate.note("Execution policy exception registration was skipped because the DisableExecutionPolicyExceptionRegistration feature flag is set")
            return .succeeded
        }

        #if canImport(ExecutionPolicy)
        if #_hasSymbol(EPExecutionPolicy.self) {
            do {
                // EPExecutionPolicy manages an XPC connection to syspolicyd, and we only need one per process.
                // Further, concurrent deallocations of EPExecutionPolicy can trigger an ASan issue in libxpc <rdar://76685500>
                enum Static {
                    static let shared = EPExecutionPolicy()
                }

                // Register the file.
                try Static.shared.addException(for: URL(fileURLWithPath: options.input.str))
            } catch {
                // We don't ever fail if blessing fails, and the failure information is not particularly interesting to users.
            }
        }
        #endif

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
