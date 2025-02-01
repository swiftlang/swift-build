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

/// Rez build phases are not supported in Swift Build.  If a project has a functional Rez build phase, then this producer will just emit a warning instructing them to update their project.
final class RezTaskProducer: FilesBasedBuildPhaseTaskProducerBase, FilesBasedBuildPhaseTaskProducer {
    typealias ManagedBuildPhase = RezBuildPhase

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope

        // Rez files are processed only when the "build" component is present.
        guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return [] }

        context.warning("Build Carbon Resources build phases are no longer supported.  Rez source files should be moved to the Copy Bundle Resources build phase.")

        return await generateTasks(self, scope, BuildFilesProcessingContext(scope, resolveBuildRules: true))
    }

    func addTasksForUngroupedFile(_ ftb: FileToBuild, _ buildFilesContext: BuildFilesProcessingContext, _ scope: MacroEvaluationScope, _ tasks: inout [any PlannedTask]) {
    }
}
