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

import SWBCore
import SWBUtil
import SWBMacro

/// AppleScript build phases are not supported in Swift Build.  If a project has a functional AppleScript build phase, then this producer will just emit an error instructing them to update their project.
final class AppleScriptTaskProducer: FilesBasedBuildPhaseTaskProducerBase, FilesBasedBuildPhaseTaskProducer {
    typealias ManagedBuildPhase = AppleScriptBuildPhase

    func generateTasks() -> [any PlannedTask] {
        let scope = context.settings.globalScope

        // These guard statements are to avoid emitting the error if this producer wouldn't normally set up tasks, even if we weren't deprecating it.

        // AppleScript files are processed only when the "build" component is present.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return [] }

        // $(SCRIPTS_FOLDER_PATH) must be defined for this build phase to be properly processed.
        guard !scope.evaluate(BuiltinMacros.SCRIPTS_FOLDER_PATH).isEmpty else { return [] }

        // If the build phase contains any source files, then emit an error.  There are a few projects in macOS with this phase which don't contain any files, and we treat that as a benign configuration.
        if !buildPhase.buildFiles.isEmpty {
            context.error("AppleScript build phases are no longer supported.  AppleScript source files should be moved to the Compile Sources build phase.")
        }

        return []
    }

    func addTasksForUngroupedFile(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) {
        // This producer doesn't generate any tasks, so this does nothing.
    }
}
