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
import SWBMacro

final class TouchToolSpec : CommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "com.apple.tools.touch"

    override func constructTasks(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) async {
        let input = cbc.input

        // FIXME: Declare a virtual output, or something. We need to deal with the mutating nature of this task. We currently just don't declare any inputs and outputs, but this command won't run in sequence properly.
        // For now, treat the touch output as an arbitrary virtual node until we have real support for representing this.
        //
        // FIXME: This is just broken, but it at least allows the task to run.
        let outputs = [delegate.createVirtualNode("Touch \(input.absolutePath.str)")]

        // Helper method to override the OutputFile macro with the input file, since touch commands do not declare an output.
        // FIXME: rdar://57299916 remove this helper method once OutputFile and OutputPath are standardized into a single macro.
        func outputFileOverride(_ macro: MacroDeclaration) -> MacroExpression? {
            switch macro {
            case BuiltinMacros.OutputFile, BuiltinMacros.OutputPath:
                return cbc.scope.table.namespace.parseLiteralString(input.absolutePath.str)
            default:
                return nil
            }
        }

        let commandLine: [String]
        if cbc.producer.hostOperatingSystem == .windows {
            // On Windows, TouchTool is only used for bundle/wrapper directories (never plain files)
            // Change into the directory and create/delete a temp file to update its timestamp
            // This works because modifying directory contents updates the directory's modification time
            guard let commandShellPath = getEnvironmentVariable("ComSpec") else {
                delegate.error("Can't determine path to cmd.exe because the ComSpec environment variable is not set")
                return
            }
            // Validate that the input is a directory, since the Windows implementation requires it
            let fs = cbc.producer.executableSearchPaths.fs
            if fs.exists(input.absolutePath) && !fs.isDirectory(input.absolutePath) {
                delegate.error("TouchTool on Windows can only be used on directories (bundles/wrappers), but was given a file: \(input.absolutePath.str)")
                return
            }
            // Use cd /d to change to the directory, then create and delete a marker file
            // The /d flag handles changing drives if needed
            commandLine = [commandShellPath, "/c", "cd /d \"\(input.absolutePath.str)\" && echo.> .swiftbuild_touch && del .swiftbuild_touch"]
        } else {
            commandLine = ["/usr/bin/touch", "-c", input.absolutePath.str]
        }

        delegate.createTask(type: self, ruleInfo: ["Touch", input.absolutePath.str], commandLine: commandLine, environment: EnvironmentBindings(), workingDirectory: cbc.producer.defaultWorkingDirectory, inputs: [delegate.createNode(input.absolutePath)], outputs: outputs, mustPrecede: [], action: delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: cbc.producer.userPreferences), execDescription: resolveExecutionDescription(cbc, delegate, lookup: outputFileOverride), enableSandboxing: enableSandboxing)
    }
}
