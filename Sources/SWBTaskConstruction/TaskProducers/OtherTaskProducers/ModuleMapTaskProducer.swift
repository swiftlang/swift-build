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
import struct SWBProtocol.BuildOperationTaskEnded
import SWBMacro

// This task producer makes tasks to generate the module map files for the product and copy them into the product.
// The equivalent native build system code is in -[XCProductTypeSpecification _defineModuleFilesWithMacroExpansionScope:] and  -[XCProductTypeSpecification _computeModuleMapProductDependenciesWithMacroExpansionScope:]

private final class ModuleMapPhaseBasedTaskGenerationDelegate: TaskGenerationDelegate {
    let delegate: any TaskGenerationDelegate
    let copyHeadersCompletionTasks: [any PlannedTask]

    init(delegate: any TaskGenerationDelegate, copyHeadersCompletionTasks: [any PlannedTask]) {
        self.delegate = delegate
        self.copyHeadersCompletionTasks = copyHeadersCompletionTasks
    }

    var userPreferences: UserPreferences {
        delegate.userPreferences
    }

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        return delegate.diagnosticsEngine(for: target)
    }

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        delegate.beginActivity(ruleInfo: ruleInfo, executionDescription: executionDescription, signature: signature, target: target, parentActivity: parentActivity)
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
        delegate.endActivity(id: id, signature: signature, status: status)
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
        delegate.emit(data: data, for: activity, signature: signature)
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
        delegate.emit(diagnostic: diagnostic, for: activity, signature: signature)
    }

    var hadErrors: Bool {
        delegate.hadErrors
    }

    var diagnosticContext: DiagnosticContextData {
        return delegate.diagnosticContext
    }

    func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        return delegate.createVirtualNode(name)
    }

    func createNode(_ path: Path) -> PlannedPathNode {
        return delegate.createNode(path)
    }

    func createDirectoryTreeNode(_ path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        return delegate.createDirectoryTreeNode(path, excluding: excluding)
    }

    func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode {
        return delegate.createBuildDirectoryNode(absolutePath: path)
    }

    func declareOutput(_ file: FileToBuild) {
        delegate.declareOutput(file)
    }

    func declareGeneratedSourceFile(_ path: Path) {
        delegate.declareGeneratedSourceFile(path)
    }

    func declareGeneratedInfoPlistContent(_ path: Path) {
        delegate.declareGeneratedInfoPlistContent(path)
    }

    func declareGeneratedPrivacyPlistContent(_ path: Path) {
        delegate.declareGeneratedPrivacyPlistContent(path)
    }

    func declareGeneratedTBDFile(_ path: Path, forVariant variant: String) {
        delegate.declareGeneratedTBDFile(path, forVariant: variant)
    }

    func declareGeneratedSwiftObjectiveCHeaderFile(_ path: Path, architecture: String) {
        delegate.declareGeneratedSwiftObjectiveCHeaderFile(path, architecture: architecture)
    }

    func declareGeneratedSwiftConstMetadataFile(_ path: Path, architecture: String) {
        delegate.declareGeneratedSwiftConstMetadataFile(path, architecture: architecture)
    }

    var additionalCodeSignInputs: OrderedSet<Path> {
        return delegate.additionalCodeSignInputs
    }

    var buildDirectories: Set<Path> {
        return delegate.buildDirectories
    }

    func createGateTask(inputs: [any PlannedNode], output: any PlannedNode, name: String?, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) {
        delegate.createGateTask(inputs: inputs, output: output, name: name, mustPrecede: mustPrecede, taskConfiguration: taskConfiguration)
    }

    var taskActionCreationDelegate: any TaskActionCreationDelegate {
        return delegate.taskActionCreationDelegate
    }

    var clientDelegate: any CoreClientDelegate {
        return delegate.clientDelegate
    }

    func createOrReuseSharedNodeWithIdentifier(_ ident: String, creator: () -> (any PlannedNode, any Sendable)) -> (any PlannedNode, any Sendable) {
        return delegate.createOrReuseSharedNodeWithIdentifier(ident, creator: creator)
    }

    func access(path: Path) {
        delegate.access(path: path)
    }

    func readFileContents(_ path: Path) throws -> ByteString {
        return try delegate.readFileContents(path)
    }

    func fileExists(at path: Path) -> Bool {
        return delegate.fileExists(at: path)
    }

    func recordAttachment(contents: SWBUtil.ByteString) -> SWBUtil.Path {
        return delegate.recordAttachment(contents: contents)
    }

    func createTask(_ builder: inout PlannedTaskBuilder) {
        builder.mustPrecede.append(contentsOf: copyHeadersCompletionTasks)
        delegate.createTask(&builder)
    }
}

final class ModuleMapTaskProducer: PhasedTaskProducer, TaskProducer {
    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return [.immediate, .compilationRequirement, .unsignedProductRequirement, .ignorePhaseOrdering]
    }

    let copyHeadersCompletionTasks: [any PlannedTask]

    init(_ context: TargetTaskProducerContext, phaseStartNodes: [any PlannedNode], phaseEndNode: any PlannedNode, phaseEndTask: (any PlannedTask)? = nil, copyHeadersCompletionTasks: [any PlannedTask]) {
        self.copyHeadersCompletionTasks = copyHeadersCompletionTasks
        super.init(context, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
    }

    @discardableResult
    override func appendGeneratedTasks( _ tasks: inout [any PlannedTask], options: TaskOrderingOptions? = nil, body: (any TaskGenerationDelegate) async -> Void) async -> (tasks: [any PlannedTask], outputs: [FileToBuild]) {
        return await super.appendGeneratedTasks(&tasks, options: options) { delegate in
            //
            await body(ModuleMapPhaseBasedTaskGenerationDelegate(delegate: delegate, copyHeadersCompletionTasks: copyHeadersCompletionTasks))
        }
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope

        // Module maps are generated for all build components, except installLoc.
        let buildComponents = scope.evaluate(BuiltinMacros.BUILD_COMPONENTS)
        guard !buildComponents.contains("installLoc") else {
            return []
        }

        // Get the computed module info descriptor for this target.
        guard let moduleInfo = context.moduleInfo else {
            // If there was no descriptor, no module map tasks are needed.
            return []
        }

        // We always construct the module map in a well-defined staging location before copying it into the actual product. This is primarily done for legacy compatibility with how Xcode did things, but we also use it in the VFS so that we have a simple, defined location for where to have the VFS look for module map entries.
        var hasModuleMap = false
        var hasPrivateModuleMap = false
        let unifdef = scope.evaluate(BuiltinMacros.COPY_HEADERS_RUN_UNIFDEF)

        // Create or copy into place the primary module map.
        var tasks: [any PlannedTask] = []
        var originalModuleMapFile: FileToBuild? = nil
        var originalModuleMapContents: ByteString? = nil
        if !moduleInfo.moduleMapPaths.sourcePath.isEmpty && moduleInfo.moduleMapPaths.sourcePath != moduleInfo.moduleMapPaths.tmpPath {
            let moduleMapSourceFile = FileToBuild(context: context, absolutePath: context.makeAbsolute(moduleInfo.moduleMapPaths.sourcePath))
            let moduleMapTmpPath = moduleInfo.moduleMapPaths.tmpPath
            do {
                // Extend the module map for Swift, if necessary.
                if let moduleMapExtension = try swiftModuleMapContents(moduleInfo: moduleInfo, scope: scope) {
                    let moduleMapExtensionPath = moduleMapTmpPath.appendingFileNameSuffix("-swiftextension")
                    let moduleMapExtensionFile = FileToBuild(context: context, absolutePath: context.makeAbsolute(moduleMapExtensionPath))
                    await appendGeneratedTasks(&tasks) { delegate in
                        context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: moduleMapExtensionPath), delegate, contents: moduleMapExtension, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions:  [.immediate, .ignorePhaseOrdering])
                        if unifdef {
                            let originalModuleMapPath = moduleMapTmpPath.appendingFileNameSuffix("-original")
                            await context.unifdefSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [moduleMapSourceFile], output: originalModuleMapPath), delegate)
                            originalModuleMapFile = FileToBuild(context: context, absolutePath: context.makeAbsolute(originalModuleMapPath))
                        } else {
                            originalModuleMapFile = moduleMapSourceFile
                        }
                        await context.concatenateSpec?.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [originalModuleMapFile!, moduleMapExtensionFile], output: moduleMapTmpPath, preparesForIndexing: true), delegate)
                    }
                } else {
                    await appendGeneratedTasks(&tasks) { delegate in
                        let buildContext = CommandBuildContext(producer: context, scope: scope, inputs: [moduleMapSourceFile], output: moduleMapTmpPath, preparesForIndexing: true)
                        if unifdef {
                            await context.unifdefSpec.constructTasks(buildContext, delegate)
                        } else {
                            await context.copySpec.constructCopyTasks(buildContext, delegate)
                        }
                    }
                }
                hasModuleMap = true
            } catch {
                context.error("Internal ModuleInfo was invalid. Please file a bug report and include the project if possible.")
            }
        } else {
            do {
                // If MODULEMAP_FILE is *not* defined, then we synthesize the file into the destination.
                let contents: ByteString

                // If we were provided the modulemap contents, then just use those.
                let moduleMapContents = scope.evaluate(BuiltinMacros.MODULEMAP_FILE_CONTENTS)
                if !moduleMapContents.isEmpty {
                    contents = ByteString(encodingAsUTF8: moduleMapContents)
                } else {
                    let swiftModuleMapContents = try swiftModuleMapContents(moduleInfo: moduleInfo, scope: scope)

                    if let generatedContents = try moduleMapGeneratedContents(moduleInfo: moduleInfo, scope: scope) {
                        // Extend the module map for Swift, if necessary.
                        if let moduleMapExtension = swiftModuleMapContents {
                            contents = ByteString(generatedContents.bytes + moduleMapExtension.bytes)
                            originalModuleMapContents = generatedContents
                        } else {
                            contents = generatedContents
                        }
                    } else if let swiftModuleMapContents = swiftModuleMapContents {
                        // If there are no generated C contents then there must be Swift contents.
                        contents = swiftModuleMapContents
                    } else {
                        throw StubError.error("Internal ModuleInfo was invalid. Please file a bug report and include the project if possible.")
                    }
                }

                await appendGeneratedTasks(&tasks) { delegate in
                    context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: moduleInfo.moduleMapPaths.tmpPath), delegate, contents: contents, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                }
                hasModuleMap = true
            } catch {
                context.error("\(error)")
            }
        }

        // Copy into place the private module map, if provided. We do not synthesize private module maps, yet.
        if let privateModuleMapPaths = moduleInfo.privateModuleMapPaths, !privateModuleMapPaths.sourcePath.isEmpty {
            let privateModuleMapSourceFile = FileToBuild(context: context, absolutePath: context.makeAbsolute(privateModuleMapPaths.sourcePath))
            await appendGeneratedTasks(&tasks) { delegate in
                let buildContext = CommandBuildContext(producer: context, scope: scope, inputs: [privateModuleMapSourceFile], output: privateModuleMapPaths.tmpPath, preparesForIndexing: true)
                if unifdef {
                    await context.unifdefSpec.constructTasks(buildContext, delegate)
                } else {
                    await context.copySpec.constructCopyTasks(buildContext, delegate)
                }
            }
            hasPrivateModuleMap = true
        }

        // Add the actual copy task to move the file into place.
        if hasModuleMap {
            let input = FileToBuild(context: context, absolutePath: moduleInfo.moduleMapPaths.tmpPath)
            await appendGeneratedTasks(&tasks) { delegate in
                await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: [input], output: moduleInfo.moduleMapPaths.builtPath, preparesForIndexing: true), delegate)
            }
        }
        if hasPrivateModuleMap, let privateModuleMapPaths = moduleInfo.privateModuleMapPaths {
            let input = FileToBuild(context: context, absolutePath: privateModuleMapPaths.tmpPath)
            await appendGeneratedTasks(&tasks) { delegate in
                await context.copySpec.constructCopyTasks(CommandBuildContext(producer: context, scope: scope, inputs: [input], output: privateModuleMapPaths.builtPath, preparesForIndexing: true), delegate)
            }
        }

        // If the module isn't Swift only, and Swift exports its API header, we
        // need to create unextended module information for the Swift compiler
        // to use. This is meant to break the cycle between the framework's
        // Swift module depending on its underlying Clang module contents, and
        // at the same time contributing to the framework's ObjectiveC
        // interface.
        //
        // In more detail, the following mechanism is used:
        // - We create a 'module.modulemap' for the resulting mixed-source
        // framework which contains a '<FrameworkName>.Swift' submodule, which
        // uses Swift's generated header (typically something like 'header
        // <FrameworkName>-Swift.h').
        //
        // - But this modulemap cannot be used when building the Swift portion
        // of the framework, because it must be able to import the underlying
        // Objective-C module before the interface header is produced. So we
        // generate another module map: 'unextended-module.modulemap', which
        // explicitly excludes ('exclude header') the generated header, to make
        // sure that compilation of the Swift portion of the framework can
        // successfully build a Clang module from this modulemap. We then
        // force the Swift compiler to use the "unextended" modulemap by
        // passing in as input the original (non-unextended) 'module.modulemap'
        // *and* a VFS overlay that remaps 'module.modulemap' -->
        // 'unextended-module.modulemap' to ensure the underlying Objective-C
        // module PCM can be built.
        //
        // - Since the PCM built above does not include the generated Swift
        // portions of the framework's Objective-C interface, clients of the
        // mixed-source framework discover the original (canonical)
        // 'module.modulemap' and, as a result, build a different PCM for the
        // framework.
        //
        // This is tightly coupled to the implementation in the Swift compiler spec.
        if (originalModuleMapFile != nil) || (originalModuleMapContents != nil) {
            let unextendedModuleMapPath = Path(scope.evaluate(BuiltinMacros.SWIFT_UNEXTENDED_MODULE_MAP_PATH))
            let unextendedOverlayPath = Path(scope.evaluate(BuiltinMacros.SWIFT_UNEXTENDED_VFS_OVERLAY_PATH))

            let vfsOverlayContents = swiftVFSOverlayContents(moduleInfo: moduleInfo, scope: scope)

            await appendGeneratedTasks(&tasks) { delegate in
                context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: unextendedOverlayPath), delegate, contents: vfsOverlayContents, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
            }

            do {
                // Create the "unextended" module map, which hides the generated interface header.
                let moduleMapUnextension = try swiftModuleMapUnextendedContents(scope: scope)

                if let originalModuleMapFile = originalModuleMapFile {
                    let moduleMapUnextensionPath = unextendedModuleMapPath.appendingFileNameSuffix("-swiftunextension")
                    let moduleMapUnextensionFile = FileToBuild(context: context, absolutePath: context.makeAbsolute(moduleMapUnextensionPath))
                    await appendGeneratedTasks(&tasks) { delegate in
                        context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: moduleMapUnextensionPath), delegate, contents: moduleMapUnextension, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                        await context.concatenateSpec?.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [originalModuleMapFile, moduleMapUnextensionFile], output: unextendedModuleMapPath, preparesForIndexing: true), delegate)
                    }
                } else if let originalModuleMapContents = originalModuleMapContents {
                    let unextendedModuleMapContents = ByteString(originalModuleMapContents.bytes + moduleMapUnextension.bytes)
                    await appendGeneratedTasks(&tasks) { delegate in
                        context.writeFileSpec.constructFileTasks(CommandBuildContext(producer: context, scope: scope, inputs: [], output: unextendedModuleMapPath), delegate, contents: unextendedModuleMapContents, permissions: nil, preparesForIndexing: true, additionalTaskOrderingOptions: [.immediate, .ignorePhaseOrdering])
                    }
                } else {
                    assertionFailure("originalModuleMapFile or originalModuleMapContents must be set")
                }
            } catch {
                context.error("\(error)")
            }
        }

        return tasks
    }

    private func moduleMapGeneratedContents(moduleInfo: ModuleInfo, scope: MacroEvaluationScope) throws -> ByteString? {
        let umbrellaHeaderName = moduleInfo.umbrellaHeader
        if !umbrellaHeaderName.isEmpty {
            let outputStream = OutputByteStream()

            // Determine the product module name.
            //
            // NOTE: This is unrelated to the "MODULE_NAME" build setting, which is much older and used by kexts.
            let moduleName = scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME)

            // Create the trivial synthesized module map.
            outputStream <<< "framework module \(try moduleName.asModuleIdentifierString()) {\n"
            outputStream <<< "  umbrella header \"\(umbrellaHeaderName.asCStringLiteralContent)\"\n"
            outputStream <<< "  export *\n"
            outputStream <<< "\n"
            outputStream <<< "  module * { export * }\n"
            outputStream <<< "}\n"

            return outputStream.bytes
        }

        return nil
    }

    private func swiftModuleMapContents(moduleInfo: ModuleInfo, scope: MacroEvaluationScope) throws -> ByteString? {
        if moduleInfo.exportsSwiftObjCAPI {
            let outputStream = OutputByteStream()

            let moduleName = scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME)

            let interfaceHeaderName = scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME)
            assert(!interfaceHeaderName.isEmpty) // implied by exportsSwiftObjCAPI

            // Swift only module map contents is a top level framework module. Swift contents
            // for a mixed module map is a submodule of the top level framework module (whose
            // name had better be PRODUCT_MODULE_NAME or things are going to get weird).
            if moduleInfo.forSwiftOnly {
                outputStream <<< "framework module \(try moduleName.asModuleIdentifierString()) {\n"
            } else {
                outputStream <<< "\n"
                outputStream <<< "module \(try moduleName.asModuleIdentifierString()).Swift {\n"
            }
            outputStream <<< "  header \"\(interfaceHeaderName.asCStringLiteralContent)\"\n"
            outputStream <<< "  requires objc\n"
            outputStream <<< "}\n"

            return outputStream.bytes
        }

        return nil
    }

    private func swiftModuleMapUnextendedContents(scope: MacroEvaluationScope) throws -> ByteString {
        let outputStream = OutputByteStream()

        let moduleName = scope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME)

        let interfaceHeaderName = scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME)
        assert(!interfaceHeaderName.isEmpty) // implied by exportsSwiftObjCAPI

        outputStream <<< "\n"
        outputStream <<< "module \(try moduleName.asModuleIdentifierString()).__Swift {\n"
        outputStream <<< "  exclude header \"\(interfaceHeaderName.asCStringLiteralContent)\"\n"
        outputStream <<< "}\n"

        return outputStream.bytes
    }

    private func swiftVFSOverlayContents(moduleInfo: ModuleInfo, scope: MacroEvaluationScope) -> ByteString {
        let unextendedModuleMapPath = Path(scope.evaluate(BuiltinMacros.SWIFT_UNEXTENDED_MODULE_MAP_PATH))
        let interfaceHeaderName = scope.evaluate(BuiltinMacros.SWIFT_OBJC_INTERFACE_HEADER_NAME)
        let unextendedInterfaceHeaderPath = Path(scope.evaluate(BuiltinMacros.SWIFT_UNEXTENDED_INTERFACE_HEADER_PATH))

        // Derive the ".framework" location of the module map. We can't use the actual location, because the VFS doesn't resolve symbolic links, so we need to use the path where the compiler will actually find the module map.
        var moduleMapPseudoDstPath = moduleInfo.moduleMapPaths.builtPath.dirname
        while true {
            // Check if we found the first ".framework" directory.
            if moduleMapPseudoDstPath.str.hasSuffix(".framework") {
                // If so, derive the modules directory path.
                moduleMapPseudoDstPath = moduleMapPseudoDstPath.join(scope.evaluate(BuiltinMacros.MODULES_FOLDER_PATH).basename)
                break
            }

            // If we got to the root and didn't find a framework, use the original path.
            if moduleMapPseudoDstPath.isRoot {
                moduleMapPseudoDstPath = moduleInfo.moduleMapPaths.builtPath.dirname
                break;
            }

            // Otherwise, keep searching the parent.
            moduleMapPseudoDstPath = moduleMapPseudoDstPath.dirname;
        }

        // The VFS doesn't currently handle resolving symbolic links correctly, which means we need to use paths relative to the BUILT_PRODUCTS_DIR (which is what gets passed as the framework search path), even though the canonical location is relative to TARGET_BUILD_DIR and the BUILT_PRODUCTS_DIR is seeded with symbolic links to the actual locations. We work around this problem by replacing TARGET_BUILD_DIR with the BUILT_PRODUCTS_DIR.
        let builtProductsDir = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR)
        let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
        if let subpath = moduleMapPseudoDstPath.relativeSubpath(from: targetBuildDir) {
            moduleMapPseudoDstPath = builtProductsDir.join(subpath)
        }

        // Similarly, derive the 'Headers' location of the to-be generated interface header relative to
        // where the modulemap will be discovered
        let generatedSwiftInterfaceHeaderPseudoDstPath = moduleMapPseudoDstPath.dirname.join(scope.evaluate(BuiltinMacros.PUBLIC_HEADERS_FOLDER_PATH).basename)

        let stream = OutputByteStream()
        stream <<< "{\n"
        stream <<< "  \"version\": 0,\n"
        stream <<< "  \"use-external-names\": false,\n"
        stream <<< "  \"case-sensitive\": false,\n"
        stream <<< "  \"roots\": [{\n"
        stream <<< "    \"type\": \"directory\",\n"
        stream <<< "    \"name\": " <<< Format.asJSON(moduleMapPseudoDstPath.str) <<< ",\n"
        stream <<< "    \"contents\": [{\n"
        stream <<< "      \"type\": \"file\",\n"
        stream <<< "      \"name\": " <<< Format.asJSON(moduleInfo.moduleMapPaths.builtPath.basename) <<< ",\n"
        stream <<< "      \"external-contents\": " <<< Format.asJSON(unextendedModuleMapPath.str) <<< ",\n"
        stream <<< "    }]\n"
        stream <<< "    },\n"
        // We also remap the excluded header for the compilation where it is actually excluded.
        // This ensures that the compilers' shared state does not cache the fact that this header does not
        // exist on the filesystem, for example, because it will be created in time for subsequent uses
        // (by this framework's clients).
        stream <<< "    {\n"
        stream <<< "    \"type\": \"directory\",\n"
        stream <<< "    \"name\": " <<< Format.asJSON(generatedSwiftInterfaceHeaderPseudoDstPath.str) <<< ",\n"
        stream <<< "    \"contents\": [{\n"
        stream <<< "      \"type\": \"file\",\n"
        stream <<< "      \"name\": " <<< Format.asJSON(interfaceHeaderName) <<< ",\n"
        stream <<< "      \"external-contents\": " <<< Format.asJSON(unextendedInterfaceHeaderPath.str) <<< ",\n"
        stream <<< "    }]\n"
        stream <<< "  }]\n"
        stream <<< "}\n"

        return stream.bytes
    }
}

extension String {
    func asModuleIdentifierString() throws -> String {
        struct Static {
            // https://clang.llvm.org/docs/Modules.html#lexical-structure
            static let keywords: Set<String> = [
                "config_macros",
                "conflict",
                "exclude",
                "explicit",
                "extern",
                "export",
                "export_as",
                "framework",
                "header",
                "link",
                "module",
                "private",
                "requires",
                "textual",
                "umbrella",
                "use",
            ]
        }
        let legal = asLegalCIdentifier
        if legal != self {
            throw StubError.error("\(self) is not a legal module identifier")
        }
        return Static.keywords.contains(legal) ? "\"\(legal)\"" : legal
    }
}
