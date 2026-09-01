//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SWBCore
import SWBMacro
import SWBProtocol
import SWBUtil

extension SourcesTaskProducer {
    struct EmbeddedResourceObject {
        let input: FileToBuild
        let info: EmbeddedResourceObjectInfo
        let seedSourcePath: Path
        let objectFormat: EmbeddedResourceObjectFormat
    }

    struct EmbeddedResourceBuildPlan {
        let accessor: GeneratedSourceCodeResult
        let objects: [EmbeddedResourceObject]
    }

    func prepareEmbeddedResources(
        _ scope: MacroEvaluationScope,
        baseTriples: [LLVMTriple],
        baseTripleStrings: [String]
    ) async -> EmbeddedResourceBuildPlan? {
        guard scope.evaluate(BuiltinMacros.GENERATE_EMBED_IN_CODE_ACCESSORS),
            let configuredTarget = context.configuredTarget,
            buildPhase.containsSwiftSources(
                context.workspaceContext.workspace,
                context,
                scope,
                context.filePathResolver
            )
        else {
            return nil
        }

        let ownTargetBuildFiles =
            ((context.workspaceContext.workspace.target(for: configuredTarget.target.guid) as? SWBCore.StandardTarget)?
                .buildPhases.compactMap { $0 as? SWBCore.BuildPhaseWithBuildFiles }
                .flatMap { $0.buildFiles }) ?? []
        let bundleDependencies = configuredTarget.target.dependencies
            .map(\.guid)
            .compactMap { context.workspaceContext.workspace.target(for: $0) as? SWBCore.StandardTarget }
            .filter {
                let settings = context.globalProductPlan.planRequest.buildRequestContext.getCachedSettings(
                    configuredTarget.parameters,
                    target: $0
                )
                return settings.globalScope.evaluate(BuiltinMacros.PRODUCT_TYPE) == "com.apple.product-type.bundle"
            }
        let bundleResourceBuildFiles =
            bundleDependencies
            .compactMap { $0.buildPhases.only as? SWBCore.BuildPhaseWithBuildFiles }
            .flatMap { $0.buildFiles }
        let resourceBuildFiles = ownTargetBuildFiles + bundleResourceBuildFiles
        let byteArrayResourceBuildFiles = resourceBuildFiles.filter { $0.resourceRule == .embedInCode }
        var objectResourceBuildFiles = resourceBuildFiles.filter { $0.resourceRule == .embedInCodeAsObject }

        let objectFormat: EmbeddedResourceObjectFormat?
        if objectResourceBuildFiles.isEmpty {
            objectFormat = nil
        } else if !scope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains([
            "-enable-experimental-feature", "Lifetimes",
        ]) {
            context.error(
                "target '\(scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME))' uses object-file resource embedding, which requires Swift's experimental 'Lifetimes' feature; add '.enableExperimentalFeature(\"Lifetimes\")' to the target's 'swiftSettings'"
            )
            objectResourceBuildFiles = []
            objectFormat = nil
        } else {
            let targetFormats = baseTriples.map(Self.embeddedResourceObjectFormat)
            let formats = Set(targetFormats.compactMap { $0 })
            if targetFormats.allSatisfy({ $0 != nil }), formats.count == 1, let format = formats.first {
                objectFormat = format
            } else {
                context.error("object-file resource embedding is not supported for target \(baseTripleStrings.joined(separator: ", "))")
                objectResourceBuildFiles = []
                objectFormat = nil
            }
        }

        do {
            return try await generateEmbeddedResourceBuildPlan(
                scope,
                byteArrayResourceBuildFiles: byteArrayResourceBuildFiles,
                objectResourceBuildFiles: objectResourceBuildFiles,
                objectFormat: objectFormat
            )
        } catch {
            context.error("failed to generate embed-in-code accessor: \(error)")
            return nil
        }
    }

    func constructEmbeddedResourceObjectTasks(
        _ resources: [EmbeddedResourceObject],
        scope: MacroEvaluationScope,
        buildFilesContext: BuildFilesProcessingContext,
        tasks: inout [any PlannedTask]
    ) async -> Set<Path> {
        guard !resources.isEmpty, let embedResourceSpec = context.embedInCodeResourceSpec else {
            return []
        }

        let assemblyFileType = context.lookupFileType(identifier: "sourcecode.asm")!
        let objectFileType = context.lookupFileType(identifier: "compiled.mach-o.objfile")!
        var seedObjects = Set<Path>()

        for resource in resources {
            let assemblyTasks = await appendGeneratedTasks(&tasks) { delegate in
                await context.clangSpec.constructTasks(
                    CommandBuildContext(
                        producer: context,
                        scope: scope,
                        inputs: [FileToBuild(absolutePath: resource.seedSourcePath, fileType: assemblyFileType)],
                        isPreferredArch: buildFilesContext.belongsToPreferredArch,
                        currentArchSpec: buildFilesContext.currentArchSpec
                    ),
                    delegate
                )
            }
            guard
                let seedObject = assemblyTasks.tasks
                    .flatMap(\.outputs)
                    .first(where: { $0.path.fileExtension == "o" })
            else {
                context.error("failed to assemble storage for embedded resource '\(resource.input.absolutePath.str)'")
                continue
            }
            seedObjects.insert(seedObject.path)

            let objectPath = scope.evaluate(BuiltinMacros.PER_ARCH_OBJECT_FILE_DIR)
                .join("swiftpm_resource_\(resource.info.identifier).o")
            await appendGeneratedTasks(&tasks) { delegate in
                embedResourceSpec.constructTasks(
                    CommandBuildContext(
                        producer: context,
                        scope: scope,
                        inputs: [
                            FileToBuild(absolutePath: seedObject.path, fileType: objectFileType),
                            resource.input,
                        ],
                        isPreferredArch: buildFilesContext.belongsToPreferredArch,
                        currentArchSpec: buildFilesContext.currentArchSpec,
                        output: objectPath
                    ),
                    delegate,
                    objectFormat: resource.objectFormat,
                    sectionName: resource.info.sectionName,
                    dataSymbol: resource.info.dataSymbol
                )
            }
        }

        return seedObjects
    }

    private static func embeddedResourceObjectFormat(for triple: LLVMTriple) -> EmbeddedResourceObjectFormat? {
        if triple.vendor == "apple" {
            return .macho
        }
        if triple.arch.hasPrefix("wasm") || triple.system == "windows" {
            return nil
        }
        return .elf
    }

    private func generateEmbeddedResourceBuildPlan(
        _ scope: MacroEvaluationScope,
        byteArrayResourceBuildFiles: [SWBCore.BuildFile],
        objectResourceBuildFiles: [SWBCore.BuildFile],
        objectFormat: EmbeddedResourceObjectFormat?
    ) async throws -> EmbeddedResourceBuildPlan? {
        if byteArrayResourceBuildFiles.isEmpty && objectResourceBuildFiles.isEmpty {
            return nil
        }

        guard let spec = context.generateEmbedInCodeAccessorSpec else {
            return nil
        }

        let filePath = scope.evaluate(BuiltinMacros.DERIVED_SOURCES_DIR).join("embedded_resources.swift")
        let moduleName = scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME)
        let byteArrayResourceInputs = try byteArrayResourceBuildFiles.map { file -> FileToBuild in
            let (_, path, fileType) = try context.resolveBuildFileReference(file)
            return FileToBuild(absolutePath: path, fileType: fileType)
        }
        let embeddedResourceObjects = try objectResourceBuildFiles.map { file -> EmbeddedResourceObject in
            guard let objectFormat else {
                throw StubError.error("missing object format for embedded resource")
            }
            let (_, path, fileType) = try context.resolveBuildFileReference(file)
            let input = FileToBuild(absolutePath: path, fileType: fileType)
            let info = EmbeddedResourceObjectInfo(moduleName: moduleName, path: path, objectFormat: objectFormat)
            return EmbeddedResourceObject(
                input: input,
                info: info,
                seedSourcePath: scope.evaluate(BuiltinMacros.DERIVED_SOURCES_DIR).join("embedded_resource_\(info.identifier).s"),
                objectFormat: objectFormat
            )
        }

        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            spec.constructTasks(
                CommandBuildContext(
                    producer: context,
                    scope: context.settings.globalScope,
                    inputs: byteArrayResourceInputs + embeddedResourceObjects.map(\.input),
                    output: filePath
                ),
                delegate,
                byteArrayResources: byteArrayResourceInputs,
                objectResources: embeddedResourceObjects.map { ($0.input, $0.seedSourcePath) },
                moduleName: moduleName,
                objectFormat: objectFormat
            )
        }

        return EmbeddedResourceBuildPlan(
            accessor: GeneratedSourceCodeResult(
                tasks: tasks,
                fileToBuild: filePath,
                fileToBuildFileType: context.lookupFileType(identifier: "sourcecode.swift")!
            ),
            objects: embeddedResourceObjects
        )
    }
}
