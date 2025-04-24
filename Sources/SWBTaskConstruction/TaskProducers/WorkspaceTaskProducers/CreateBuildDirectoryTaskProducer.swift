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

/// This produces the tasks which create the build directories which are conceptually not part of any target, such as the `SYMROOT`, `OBJROOT` and `DSTROOT`.
final class CreateBuildDirectoryTaskProducer: StandardTaskProducer, TaskProducer {
    private let targetContexts: [TaskProducerContext]

    init(context globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) {
        self.targetContexts = targetContexts
        super.init(globalContext)
    }

    func prepare() {
        let containsSwiftPackages = context.globalProductPlan.planRequest.buildGraph.containsSwiftPackages
        let buildDirectoryContext = context.globalProductPlan.buildDirectories
        buildDirectoryContext.add(targetContexts.flatMap { (targetContext: TaskProducerContext) -> [Path] in
            // Package products only group dependent targets or carry imparted settings, but never build any content of their own, so we should not create any build directories for them.
            if targetContext.configuredTarget?.target.type == .packageProduct {
                return []
            }
            return targetContext.workspaceContext.buildDirectoryMacros.flatMap { macro -> [Path] in
                let scope = targetContext.settings.globalScope
                let path = scope.evaluate(macro)

                switch macro {
                case BuiltinMacros.BUILT_PRODUCTS_DIR:
                    // If the workspace contains any packages, eagerly create the "PackageFrameworks" directory. As part of "rdar://72205262 (Explore moving away from two target approach for dynamic targets to changing linkage directly in Swift Build)", we should instead compute any search paths to "PackageFrameworks" dynamically to avoid this.
                    if containsSwiftPackages {
                        return [path, path.join("PackageFrameworks")]
                    }
                case BuiltinMacros.DSTROOT:
                    // Skip generating DSTROOT if DEPLOYMENT_LOCATION is not enabled.
                    if !scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) {
                        return []
                    }
                default:
                    break
                }

                return [path]
            }
        })
        buildDirectoryContext.freeze()
    }

    func generateTasks() async -> [any PlannedTask] {
        var tasks = [any PlannedTask]()

        await appendGeneratedTasks(&tasks) { delegate in
            let paths = delegate.buildDirectories
            for path in paths {
                // Force the directory creation tasks to be creates from outermost to innermost.
                // This is necessary because the build directory creation sets an xattr on created directories so that
                // the clean can identify a directory as having been created by the build system and know that it's safe
                // to delete, and we want to ensure the xattrs exist on intermediate directory components along the path.
                func nearestAncestor(of path: Path, in paths: Set<Path>) -> Path? {
                    var ancestor = path
                    while !ancestor.isRoot && !ancestor.isEmpty {
                        ancestor = ancestor.dirname

                        // Assume paths contains only normalized paths
                        if paths.contains(ancestor) {
                            return ancestor
                        }
                    }
                    return nil
                }

                let commandOrderingInputs = nearestAncestor(of: path, in: paths).map { [delegate.createBuildDirectoryNode(absolutePath: $0)] } ?? []

                context.createBuildDirectorySpec.constructTasks(CommandBuildContext(producer: context, scope: context.settings.globalScope, inputs: [], commandOrderingInputs: commandOrderingInputs), delegate, buildDirectoryNode: delegate.createBuildDirectoryNode(absolutePath: path))
            }
        }

        return tasks
    }
}
