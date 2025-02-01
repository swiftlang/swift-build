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

extension BuildPhaseTarget {
    fileprivate func filesToBuild(context: TaskProducerContext, scope: MacroEvaluationScope, buildFiles: [BuildFile], fileType: FileTypeSpec) -> [FileToBuild] {
        let buildFilesProcessingContext = BuildFilesProcessingContext(scope)
        return buildFiles.compactMap { buildFile in
            guard let resolvedBuildFileInfo = try? context.resolveBuildFileReference(buildFile),
                  !buildFilesProcessingContext.isExcluded(resolvedBuildFileInfo.absolutePath, filters: buildFile.platformFilters),
                  resolvedBuildFileInfo.fileType.conformsTo(fileType) else {
                return nil
            }

            return FileToBuild(absolutePath: resolvedBuildFileInfo.absolutePath, fileType: fileType)
        }
    }

    fileprivate func assetCatalogsToBuild(context: TaskProducerContext, scope: MacroEvaluationScope) -> [FileToBuild] {
        guard let buildFiles = resourcesBuildPhase?.buildFiles else { return [] }
        guard let assetCatalogFileType = context.lookupFileType(identifier: "folder.assetcatalog") else { return [] }

        return filesToBuild(context: context, scope: scope, buildFiles: buildFiles, fileType: assetCatalogFileType)
    }
}

final class GenerateAppPlaygroundAssetCatalogTaskProducer: PhasedTaskProducer, TaskProducer {
    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope

        if !scope.evaluate(BuiltinMacros.APP_PLAYGROUND_GENERATE_ASSET_CATALOG) { return [] }

        let assetCatalogsBeingBuilt = (context.configuredTarget?.target as? BuildPhaseTarget)?.assetCatalogsToBuild(
            context: context,
            scope: scope
        ) ?? []

        let assetCatalogToBeGenerated = scope.evaluate(BuiltinMacros.APP_PLAYGROUND_GENERATED_ASSET_CATALOG_FILE)

        let specialArgs: [String]
        if !assetCatalogsBeingBuilt.isEmpty {
            specialArgs = ["-assetCatalogResourcePaths"] + assetCatalogsBeingBuilt.map { $0.absolutePath.str }
        }
        else {
            specialArgs = []
        }

        var tasks: [any PlannedTask] = []
        await appendGeneratedTasks(&tasks) { delegate in
            await context.generateAppPlaygroundAssetCatalogSpec?.constructTasks(
                CommandBuildContext(
                    producer: context,
                    scope: scope,
                    inputs: assetCatalogsBeingBuilt,
                    output: assetCatalogToBeGenerated
                ),
                delegate,
                specialArgs: specialArgs
            )
        }
        return tasks
    }
}
