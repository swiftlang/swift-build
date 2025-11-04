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
import SWBTaskConstruction
import SWBMacro
import SWBUtil

class TestEntryPointTaskProducer: PhasedTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        var tasks: [any PlannedTask] = []
        if context.settings.globalScope.evaluate(BuiltinMacros.GENERATE_TEST_ENTRY_POINT) {
            await self.appendGeneratedTasks(&tasks) { delegate in
                let scope = context.settings.globalScope
                let outputPath = scope.evaluate(BuiltinMacros.GENERATED_TEST_ENTRY_POINT_PATH)

                guard let configuredTarget = context.configuredTarget else {
                    context.error("Cannot generate a test entry point without a target")
                    return
                }
                var indexStoreDirectories: OrderedSet<Path> = []
                var linkerFileLists: OrderedSet<Path> = []
                var indexUnitBasePaths: OrderedSet<Path> = []
                var binaryPaths: OrderedSet<Path> = []
                for directDependency in context.globalProductPlan.dependencies(of: configuredTarget) {
                    let settings = context.globalProductPlan.getTargetSettings(directDependency)
                    guard settings.productType?.conformsTo(identifier: "com.apple.product-type.bundle.unit-test") == true else {
                        continue
                    }
                    guard settings.globalScope.evaluate(BuiltinMacros.SWIFT_ENABLE_TESTABILITY) || settings.globalScope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains("-enable-testing") else {
                        context.warning("Skipping XCTest discovery for '\(directDependency.target.name)' because it was not built for testing")
                        continue
                    }
                    guard settings.globalScope.evaluate(BuiltinMacros.SWIFT_INDEX_STORE_ENABLE) else {
                        context.warning("Skipping XCTest discovery for '\(directDependency.target.name)' because indexing was disabled")
                        continue
                    }
                    let path = settings.globalScope.evaluate(BuiltinMacros.SWIFT_INDEX_STORE_PATH)
                    guard !path.isEmpty else {
                        context.warning("Skipping XCTest discovery for '\(directDependency.target.name)' because the index store path could not be determined")
                        continue
                    }
                    indexStoreDirectories.append(path)

                    for arch in settings.globalScope.evaluate(BuiltinMacros.ARCHS) {
                        for variant in settings.globalScope.evaluate(BuiltinMacros.BUILD_VARIANTS) {
                            let innerScope = settings.globalScope
                                .subscope(binding: BuiltinMacros.archCondition, to: arch)
                                .subscope(binding: BuiltinMacros.variantCondition, to: variant)
                            let linkerFileListPath = innerScope.evaluate(BuiltinMacros.__INPUT_FILE_LIST_PATH__)
                            if !linkerFileListPath.isEmpty {
                                linkerFileLists.append(linkerFileListPath)
                            }
                            let objroot = innerScope.evaluate(BuiltinMacros.OBJROOT)
                            if !objroot.isEmpty {
                                indexUnitBasePaths.append(objroot)
                            }

                            let binaryPath = innerScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(innerScope.evaluate(BuiltinMacros.EXECUTABLE_PATH)).normalize()
                            binaryPaths.append(binaryPath)
                        }
                    }
                }

                let inputs: [FileToBuild] = linkerFileLists.map { FileToBuild(absolutePath: $0, fileType: self.context.workspaceContext.core.specRegistry.getSpec("text") as! FileTypeSpec) } + binaryPaths.map { FileToBuild(absolutePath: $0, fileType: self.context.workspaceContext.core.specRegistry.getSpec("compiled.mach-o") as! FileTypeSpec) }

                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: inputs, outputs: [outputPath])
                await context.testEntryPointGenerationToolSpec.constructTasks(cbc, delegate, indexStorePaths: indexStoreDirectories.elements, indexUnitBasePaths: indexUnitBasePaths.elements)
            }
        }
        return tasks
    }
}

extension TaskProducerContext {
    var testEntryPointGenerationToolSpec: TestEntryPointGenerationToolSpec {
        return workspaceContext.core.specRegistry.getSpec(TestEntryPointGenerationToolSpec.identifier, domain: domain) as! TestEntryPointGenerationToolSpec
    }
}
