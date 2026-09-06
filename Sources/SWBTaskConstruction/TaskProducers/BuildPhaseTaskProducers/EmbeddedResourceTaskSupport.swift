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
    struct EmbeddedResourceBuildPlan {
        let accessor: GeneratedSourceCodeResult
        let cSources: [Path]
    }

    func prepareEmbeddedResources(_ scope: MacroEvaluationScope) async -> EmbeddedResourceBuildPlan? {
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

        if !objectResourceBuildFiles.isEmpty && !scope.evaluate(BuiltinMacros.OTHER_SWIFT_FLAGS).contains([
            "-enable-experimental-feature", "Lifetimes",
        ]) {
            context.error(
                "target '\(scope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME))' uses object-file resource embedding, which requires Swift's experimental 'Lifetimes' feature; add '.enableExperimentalFeature(\"Lifetimes\")' to the target's 'swiftSettings'"
            )
            objectResourceBuildFiles = []
        }

        do {
            return try await generateEmbeddedResourceBuildPlan(
                scope,
                resourceBuildFiles: byteArrayResourceBuildFiles + objectResourceBuildFiles
            )
        } catch {
            context.error("failed to generate embed-in-code accessor: \(error)")
            return nil
        }
    }

    private func generateEmbeddedResourceBuildPlan(
        _ scope: MacroEvaluationScope,
        resourceBuildFiles: [SWBCore.BuildFile]
    ) async throws -> EmbeddedResourceBuildPlan? {
        if resourceBuildFiles.isEmpty {
            return nil
        }

        guard let spec = context.generateEmbedInCodeAccessorSpec else {
            return nil
        }

        let filePath = scope.evaluate(BuiltinMacros.DERIVED_SOURCES_DIR).join("embedded_resources.swift")
        let resourceInputs = try resourceBuildFiles.map { file -> FileToBuild in
            let (_, path, fileType) = try context.resolveBuildFileReference(file)
            return FileToBuild(absolutePath: path, fileType: fileType, buildFile: file)
        }

        var tasks = [any PlannedTask]()
        await appendGeneratedTasks(&tasks) { delegate in
            spec.constructTasks(
                CommandBuildContext(
                    producer: context,
                    scope: scope,
                    inputs: resourceInputs,
                    output: filePath
                ),
                delegate
            )
        }

        return EmbeddedResourceBuildPlan(
            accessor: GeneratedSourceCodeResult(
                tasks: tasks,
                fileToBuild: filePath,
                fileToBuildFileType: context.lookupFileType(identifier: "sourcecode.swift")!
            ),
            cSources: tasks.flatMap { $0.outputs }.map(\.path).filter { $0.fileExtension == "c" }
        )
    }
}
