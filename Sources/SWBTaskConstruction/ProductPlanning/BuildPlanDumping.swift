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

package import SWBUtil
import SWBCore
import SWBMacro
import Foundation

/// Ability to dump the contents of a build plan for diagnostic purposes.
package extension BuildPlan {

    func write(to directory: Path, fs: any FSProxy) throws {
        // Start by building up a mapping from target names to lists of tasks.
        var tasksByTarget: [ConfiguredTarget?: [any PlannedTask]] = [:]
        for task in tasks {
            tasksByTarget[task.forTarget, default: []].append(task)
        }

        // Emit a separate file for each target, inside a separate subdirectory for each project.
        for (target, plannedTasks) in tasksByTarget {
            // Get a hold of the product plan and macro evaluation scope.
            let productPlan = productPlans.first{ $0.forTarget == target }!
            let scope = target.map { target in productPlan.taskProducerContext.globalProductPlan.getTargetSettings(target).globalScope } ?? productPlan.taskProducerContext.globalProductPlan.getWorkspaceSettings().globalScope

            // Figure out the name of the project.
            let projectName = scope.evaluate(BuiltinMacros.PROJECT_NAME)

            // Build up a mapping from literal paths to more abstract macro reference strings.
            var literalPathsToMacroRefs: [String: String] = [:]
            let pathMacrosToSubstitute = [
                BuiltinMacros.SDKROOT,
                BuiltinMacros.SRCROOT,
                BuiltinMacros.OBJROOT,
                BuiltinMacros.SYMROOT,
                BuiltinMacros.CCHROOT,
                BuiltinMacros.MODULE_CACHE_DIR,
                BuiltinMacros.PROJECT_TEMP_DIR,
                BuiltinMacros.TARGET_TEMP_DIR,
                BuiltinMacros.DERIVED_SOURCES_DIR,
                BuiltinMacros.CONFIGURATION_BUILD_DIR,
            ]
            for macro in pathMacrosToSubstitute {
                let literalPath = scope.evaluate(macro)
                if literalPath.isEmpty { continue }
                literalPathsToMacroRefs[literalPath.str] = "$(" + macro.name + ")"
            }

            // Sort the evaluated paths in order of decreasing length, so that the longest match wins.
            let literalPathsFromLongestToShortest = literalPathsToMacroRefs.keys.sorted(>, by: \.count)

            // Write all the task info to a file with the same name as the target.  We are not in a position to write out parallel-execution barriers, since that's not how Swift Build works.
            let output = OutputByteStream()
            for task in plannedTasks {
                // Emit a version of the rule-info array that keeps literal paths, since that's what the build log does too.
                output <<< "ruleinfo: \(task.ruleInfo.quotedStringListRepresentation)\n"

                // Emit a version of the command line arguments array that back-maps as many strings as possible to macro refs.
                let commandLine = task.execTask.commandLineAsStrings.map { (commandLineArg: String) -> String in
                    literalPathsFromLongestToShortest.reduce(commandLineArg, { (result: String, path: String) -> String in
                        result.replacingOccurrences(of: path, with: literalPathsToMacroRefs[path]!)
                    })
                }
                output <<< "command: \(commandLine.quotedStringListRepresentation)\n"
            }
            output.flush()

            // Make sure the directory with the same name as the project exists, and write the stream contents to the file.
            if let target {
                let projDirPath = directory.join(projectName)
                try fs.createDirectory(projDirPath, recursive: true)
                let targetFilePath = projDirPath.join(target.target.name + ".txt")
                try fs.write(targetFilePath, contents: output.bytes)
            } else {
                try fs.createDirectory(directory, recursive: true)
                try fs.write(directory.join("workspace.txt"), contents: output.bytes)
            }
        }
    }
}
