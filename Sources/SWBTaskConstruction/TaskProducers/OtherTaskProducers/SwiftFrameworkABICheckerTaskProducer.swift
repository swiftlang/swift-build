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

fileprivate func supportSwiftABIChecking(_ context: TaskProducerContext) -> Bool {
    let scope = context.settings.globalScope

    // swift-api-digester is run only when the "build" component is present.
    guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return false }

    guard scope.evaluate(BuiltinMacros.SWIFT_EMIT_MODULE_INTERFACE) &&
          scope.evaluate(BuiltinMacros.SWIFT_ENABLE_LIBRARY_EVOLUTION) else {
        // BUILD_LIBRARY_FOR_DISTRIBUTION is the option clients should use (it's also what is exposed in the
        // Build Settings editor) and is what SWIFT_EMIT_MODULE_INTERFACE uses by default, but they are
        // configurable independently.
        context.error("Swift ABI checker is only functional when BUILD_LIBRARY_FOR_DISTRIBUTION = YES")
        return false
    }
    guard let productType = context.productType else { return false }

    if !productType.supportsSwiftABIChecker {
        return false
    }
    // Examine the sources build phase to see whether our target contains any Swift files.
    let buildingAnySwiftSourceFiles = (context.configuredTarget?.target as? BuildPhaseTarget)?.sourcesBuildPhase?.containsSwiftSources(context.workspaceContext.workspace, context, scope, context.filePathResolver) ?? false
    if !buildingAnySwiftSourceFiles {
        return false
    }
    return true
}

fileprivate func getBaselineFileName(_ scope: MacroEvaluationScope, _ arch: String) -> Path {
    return Path("\(arch)-\(scope.evaluate(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX))\(scope.evaluate(BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX)).json")
}

fileprivate func getGeneratedBaselineFilePath(_ context: TaskProducerContext, _ arch: String) -> Path {
    let scope = context.settings.globalScope
    var baselineDir = scope.evaluate(BuiltinMacros.SWIFT_ABI_GENERATION_TOOL_OUTPUT_DIR)
    if baselineDir.isEmpty {
        baselineDir = SwiftCompilerSpec.swiftModuleContentDir(scope, moduleName: scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME), isProject: true).join("Baseline").join("ABI").str
    }
    // Construct the abi baseline dir as input. The baseline directory is /Foo.swiftmodule/Project/Baseline/ABI
    return Path(baselineDir).join(getBaselineFileName(scope, arch))
}

final class SwiftFrameworkABICheckerTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .immediate
    }

    func generateTasks() async -> [any PlannedTask]
    {
        var tasks = [any PlannedTask]()
        let scope = context.settings.globalScope
        // If running this tool is disabled via build setting, then we can abort this task provider.
        guard scope.evaluate(BuiltinMacros.RUN_SWIFT_ABI_CHECKER_TOOL) else { return [] }
        guard supportSwiftABIChecking(context) else { return [] }
        // All archs
        let archs: [String] = scope.evaluate(BuiltinMacros.ARCHS)

        // All variants
        let buildVariants = scope.evaluate(BuiltinMacros.BUILD_VARIANTS)

        for variant in buildVariants {
            // Enter the per-variant scope.
            let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)
            for arch in archs {
                // Enter the per-arch scope.
                let scope = scope.subscope(binding: BuiltinMacros.archCondition, to: arch)
                let moduleDirPath = SwiftCompilerSpec.getSwiftModuleFilePath(scope)
                let moduleInput = FileToBuild(absolutePath: moduleDirPath, inferringTypeUsing: context)
                let interfaceInput = FileToBuild(absolutePath: Path(moduleDirPath.withoutSuffix + ".swiftinterface"), inferringTypeUsing: context)
                let serializedDiagPath = scope.evaluate(BuiltinMacros.TARGET_TEMP_DIR).join(scope.evaluate(BuiltinMacros.PRODUCT_NAME)).join("SwiftABIChecker").join(variant).join(getBaselineFileName(scope, arch).withoutSuffix + ".dia")
                var allInputs = [moduleInput, interfaceInput]
                if scope.evaluate(BuiltinMacros.RUN_SWIFT_ABI_GENERATION_TOOL) {
                    // If users also want to generate ABI baseline, we should generate the baseline first. This allows users to update
                    // baseline without re-running the build.
                    allInputs.append(FileToBuild(absolutePath: getGeneratedBaselineFilePath(context, arch), inferringTypeUsing: context))
                }
                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: allInputs, output: serializedDiagPath)

                // Construct the baseline file path if SWIFT_ABI_CHECKER_BASELINE_DIR is specified by the user
                let baselineDir = scope.evaluate(BuiltinMacros.SWIFT_ABI_CHECKER_BASELINE_DIR)
                var baselinePath: Path?
                if !baselineDir.isEmpty {
                    baselinePath = Path(baselineDir).join("ABI").join(getBaselineFileName(scope, arch))
                }

                let allowlist = scope.evaluate(BuiltinMacros.SWIFT_ABI_CHECKER_EXCEPTIONS_FILE)
                var allowlistFile: Path?
                if !allowlist.isEmpty {
                    allowlistFile = Path(allowlist)
                }

                await appendGeneratedTasks(&tasks) { delegate in
                    await context.swiftABICheckerToolSpec?.constructABICheckingTask(cbc, delegate, serializedDiagPath, baselinePath, allowlistFile)
                }
            }
        }
        return tasks
    }
}

class SwiftABIBaselineGenerationTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .immediate
    }
    func generateTasks() async -> [any PlannedTask] {
        var tasks = [any PlannedTask]()
        let scope = context.settings.globalScope
        // If running this tool is disabled via build setting, then we can abort this task provider.
        guard scope.evaluate(BuiltinMacros.RUN_SWIFT_ABI_GENERATION_TOOL) else { return [] }
        guard supportSwiftABIChecking(context) else { return [] }
        // All archs
        let archs: [String] = scope.evaluate(BuiltinMacros.ARCHS)

        // All variants
        let buildVariants = scope.evaluate(BuiltinMacros.BUILD_VARIANTS)
        for variant in buildVariants {
            // Enter the per-variant scope.
            let scope = scope.subscope(binding: BuiltinMacros.variantCondition, to: variant)
            for arch in archs {
                // Enter the per-arch scope.
                let scope = scope.subscope(binding: BuiltinMacros.archCondition, to: arch)

                // Construct the Swift interface file as input
                let moduleDirPath = SwiftCompilerSpec.getSwiftModuleFilePath(scope)
                let moduleInput = FileToBuild(absolutePath: moduleDirPath, inferringTypeUsing: context)
                let interfaceInput = FileToBuild(absolutePath: Path(moduleDirPath.withoutSuffix + ".swiftinterface"), inferringTypeUsing: context)

                let baselinePath = getGeneratedBaselineFilePath(context, arch)

                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [moduleInput, interfaceInput], output: baselinePath)
                await appendGeneratedTasks(&tasks) { delegate in
                    // Generate baseline into the baseline directory
                    await context.swiftABIGenerationToolSpec?.constructABIGenerationTask(cbc, delegate, baselinePath)
                }
            }
        }
        return tasks
    }
}
