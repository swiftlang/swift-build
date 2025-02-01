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
import SWBTaskConstruction

struct StubBinary: Hashable {
    var sourcePath: Path
    var bundleSidecarPath: Path?
    var archiveSidecarPath: Path?
}

fileprivate func generateStubBinaryTasks(stubBinarySourcePath: Path, archs: [String], thinArchs: Bool, copyToApp: Bool, bundleSidecarPath: Path?, archiveSidecarPath: Path?, context: TaskProducerContext, delegate: any TaskGenerationDelegate) async {
    let scope = context.settings.globalScope

    /// Empty paths are allowed and silently skipped. Non-absolute paths emit errors.
    func check(_ path: Path, label: String) -> Bool {
        guard !path.isEmpty else { return false }

        guard path.isAbsolute else {
            context.error("\(label) is not an absolute path but is '\(path.str)'")
            return false
        }

        return true
    }

    guard check(stubBinarySourcePath, label: "Main binary source path") else { return }

    func copyBinary(_ cbc: CommandBuildContext, executionDescription: String) async {
        // If we have no architectures, then simply copy the binary as-is
        if thinArchs && !archs.isEmpty {
            context.lipoSpec.constructCopyAndProcessArchsTasks(cbc, delegate, executionDescription: executionDescription, archsToPreserve: archs)
        } else {
            await context.copySpec.constructCopyTasks(cbc, delegate, executionDescription: executionDescription, stripUnsignedBinaries: false, stripBitcode: false)
        }
    }

    // Copy the stub binary into the app as its actual binary.
    if copyToApp {
        let outputPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.EXECUTABLE_PATH))
        // Create a virtual output node so code signing can be ordered with respect to this task.
        let orderingOutputNode = context.createVirtualNode("Copy \(outputPath.str)")
        let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: stubBinarySourcePath, inferringTypeUsing: context)], output: outputPath, commandOrderingOutputs: [orderingOutputNode])
        await copyBinary(cbc, executionDescription: "Copy main binary")
    }

    // Also copy the stub binary to a special location inside the wrapper which preserves its Apple-signed nature.
    if let outputPath = bundleSidecarPath, check(outputPath, label: "Main binary resource sidecar path") {
        let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: stubBinarySourcePath, inferringTypeUsing: context)], output: outputPath)
        await copyBinary(cbc, executionDescription: "Copy binary resource")
    }

    // If doing an archive build then also copy the stub binary to a sidecar directory in the archive.  Whether to do this depends on whether a build setting corresponding to a product type has been set, which the archive scheme action will do.
    if let outputPath = archiveSidecarPath, check(outputPath, label: "Main binary archive sidecar path") {
        let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(absolutePath: stubBinarySourcePath, inferringTypeUsing: context)], output: outputPath.join(stubBinarySourcePath.basename))
        await copyBinary(cbc, executionDescription: "Copy binary for archiving")
    }
}

extension TaskProducerContext {
    var stubBinary: StubBinary? {
        let scope = settings.globalScope

        // These are all of the possible stub binaries we may need to copy over for a product.
        // These are produced based on particular build settings set by the product type.
        // At most one of these should have a non-empty source path, and that's the one
        // we will use.
        let stubBinaries = [
            StubBinaryTaskProducer.watchKitStubBinary(scope, productType: productType),
            StubBinaryTaskProducer.messagesAppStubBinary(scope),
            StubBinaryTaskProducer.messagesAppExtensionStubBinary(scope)
        ]

        return stubBinaries.filter{ !$0.sourcePath.isEmpty }.only
    }
}

final class StubBinaryTaskProducer: PhasedTaskProducer, TaskProducer {
    class func watchKitStubBinary(_ scope: MacroEvaluationScope, productType: ProductTypeSpec?) -> StubBinary {
        let sourcePath = Path(scope.evaluate(BuiltinMacros.PRODUCT_BINARY_SOURCE_PATH))

        let (bundleSidecarPath, archiveSidecarPath): (Path?, Path?) = {
            if productType?.identifier == "com.apple.product-type.application.watchapp2" {
                return (scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.FULL_PRODUCT_NAME)).join("_WatchKitStub/WK"),
                        Path(scope.evaluate(BuiltinMacros.WATCHKIT_2_SUPPORT_FOLDER_PATH)))
            }
            return (nil, nil)
        }()

        return StubBinary(sourcePath: sourcePath, bundleSidecarPath: bundleSidecarPath, archiveSidecarPath: archiveSidecarPath)
    }

    class func messagesAppStubBinary(_ scope: MacroEvaluationScope) -> StubBinary {
        let sourcePath = Path(scope.evaluate(BuiltinMacros.MESSAGES_APPLICATION_PRODUCT_BINARY_SOURCE_PATH))
        let archiveSidecarPath = Path(scope.evaluate(BuiltinMacros.MESSAGES_APPLICATION_SUPPORT_FOLDER_PATH))

        return StubBinary(sourcePath: sourcePath, bundleSidecarPath: nil, archiveSidecarPath: archiveSidecarPath)
    }

    class func messagesAppExtensionStubBinary(_ scope: MacroEvaluationScope) -> StubBinary {
        let sourcePath = Path(scope.evaluate(BuiltinMacros.MESSAGES_APPLICATION_EXTENSION_PRODUCT_BINARY_SOURCE_PATH))
        let archiveSidecarPath = Path(scope.evaluate(BuiltinMacros.MESSAGES_APPLICATION_EXTENSION_SUPPORT_FOLDER_PATH))

        return StubBinary(sourcePath: sourcePath, bundleSidecarPath: nil, archiveSidecarPath: archiveSidecarPath)
    }

    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return [.immediate, .unsignedProductRequirement]
    }

    func generateTasks() async -> [any PlannedTask] {
        guard let stubBinary = context.stubBinary else {
            return []
        }

        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            let scope = context.settings.globalScope

            // The stub is copied only when the "build" component is present.
            guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return }

            await generateStubBinaryTasks(stubBinarySourcePath: stubBinary.sourcePath, archs: scope.evaluate(BuiltinMacros.ARCHS), thinArchs: scope.evaluate(BuiltinMacros.THIN_PRODUCT_STUB_BINARY), copyToApp: true, bundleSidecarPath: stubBinary.bundleSidecarPath, archiveSidecarPath: nil, context: context, delegate: delegate)
        }
        return tasks
    }
}

final class GlobalStubBinaryTaskProducer: StandardTaskProducer, TaskProducer {
    private let targetContexts: [TaskProducerContext]

    init(context globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) {
        self.targetContexts = targetContexts
        super.init(globalContext)
    }

    func generateTasks() async -> [any PlannedTask] {
        struct StubBinaryWithArchs: Hashable {
            let stubBinary: StubBinary
            let archs: Set<String>
            let thinArchs: Bool
        }

        let stubBinaries: Set<StubBinaryWithArchs> = Set(targetContexts.compactMap { targetContext in
            let scope = targetContext.settings.globalScope

            // The stub is copied only when the "build" component is present.
            guard scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("build") else { return nil }

            guard var tmp = targetContext.stubBinary else { return nil }
            tmp.bundleSidecarPath = nil
            return StubBinaryWithArchs(stubBinary: tmp, archs: Set(scope.evaluate(BuiltinMacros.ARCHS)), thinArchs: scope.evaluate(BuiltinMacros.THIN_PRODUCT_STUB_BINARY))
        })

        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            for stubBinaryWithArchs in stubBinaries {
                await generateStubBinaryTasks(stubBinarySourcePath: stubBinaryWithArchs.stubBinary.sourcePath, archs: stubBinaryWithArchs.archs.sorted(), thinArchs: stubBinaryWithArchs.thinArchs, copyToApp: false, bundleSidecarPath: nil, archiveSidecarPath: stubBinaryWithArchs.stubBinary.archiveSidecarPath, context: context, delegate: delegate)
            }
        }
        return tasks
    }
}
