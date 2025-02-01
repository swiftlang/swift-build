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

/// A task producer that constructs Build Documentation tasks IFF the target doesn't already have a documentation catalog input.
///
/// This task producer exists to support building documentation from just in-source documentation comments, when there is no documentation catalog input.
/// When the target has a documentation catalog input, this producer will do nothing, instead relying on task being constructed based on that output.
final class DocumentationTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .compilation
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        var tasks: [any PlannedTask] = []

        guard let target = context.configuredTarget?.target as? StandardTarget else {
            return []
        }

        // If the target has a documentation catalog input, the DocumentationCompilerSpec will be asked to construct a task based on that input.
        // In this case, we early return here to avoid creating more than one documentation task.
        guard !target.hasDocumentationCatalogInput(specLookupContext: context, referenceLookupContext: context, scope: scope, filePathResolver: context.settings.filePathResolver) else {
            return []
        }

        // The DocumentationCompilerSpec will check if it should construct a task, so can safely call `constructTasks` without checking that here.
        let output = scope.evaluate(BuiltinMacros.DOCC_ARCHIVE_PATH)
        let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [], output: Path(output))

        await appendGeneratedTasks(&tasks) { delegate in
            await context.documentationCompilerSpec?.constructTasks(cbc, delegate)
        }

        return tasks
    }
}

extension StandardTarget {
    func hasDocumentationCatalogInput(specLookupContext: any SpecLookupContext, referenceLookupContext: any ReferenceLookupContext, scope: MacroEvaluationScope, filePathResolver: FilePathResolver) -> Bool {
        guard let documentationCatalogFileType = specLookupContext.lookupFileType(identifier: "folder.documentationcatalog") else { return false }

        return buildPhases.contains(where: { phase in
            (phase as? BuildPhaseWithBuildFiles)?.containsFiles(ofType: documentationCatalogFileType, referenceLookupContext, specLookupContext, scope, filePathResolver) == true
        })
    }
}
