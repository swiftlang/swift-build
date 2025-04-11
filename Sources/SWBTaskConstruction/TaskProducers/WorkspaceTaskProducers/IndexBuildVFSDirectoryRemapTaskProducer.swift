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

final class IndexBuildVFSDirectoryRemapTaskProducer: StandardTaskProducer, TaskProducer {

    init(context globalContext: TaskProducerContext) {
        super.init(globalContext)
    }

    func generateTasks() async -> [any PlannedTask] {
        guard context.globalProductPlan.planRequest.buildRequest.enableIndexBuildArena else { return [] }

        var tasks = [any PlannedTask]()

        let scope = context.settings.globalScope
        let regularBuildProductsPathStr = scope.evaluate(BuiltinMacros.INDEX_REGULAR_BUILD_PRODUCTS_DIR)
        let indexBuildProductsPathStr = scope.evaluate(BuiltinMacros.SYMROOT)
        let regularBuildIntermediatesPathStr = scope.evaluate(BuiltinMacros.INDEX_REGULAR_BUILD_INTERMEDIATES_DIR)
        let indexBuildIntermediatesPathStr = scope.evaluate(BuiltinMacros.OBJROOT)

        var remappings = [DirectoryRemapVFSOverlay.Remap]()
        if !regularBuildProductsPathStr.isEmpty && !indexBuildProductsPathStr.isEmpty {
            remappings.append(DirectoryRemapVFSOverlay.Remap(name: indexBuildProductsPathStr.str, externalContents: regularBuildProductsPathStr))
        }
        if !regularBuildIntermediatesPathStr.isEmpty && !indexBuildIntermediatesPathStr.isEmpty {
            remappings.append(DirectoryRemapVFSOverlay.Remap(name: indexBuildIntermediatesPathStr.str, externalContents: regularBuildIntermediatesPathStr))
        }
        guard !remappings.isEmpty else { return [] }

        await appendGeneratedTasks(&tasks) { delegate in
            let path = Path(scope.evaluate(BuiltinMacros.INDEX_DIRECTORY_REMAP_VFS_FILE))
            let overlay = DirectoryRemapVFSOverlay(
                version: 0,
                caseSensitive: false,
                redirectingWith: .fallback,
                remapping: remappings
            )

            let contents: ByteString
            do {
                contents = try PropertyListItem(overlay).asJSONFragment()
            } catch {
                context.error("\(error)")
                return
            }

            context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: path), delegate, contents: contents, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
        }

        return tasks
    }
}
