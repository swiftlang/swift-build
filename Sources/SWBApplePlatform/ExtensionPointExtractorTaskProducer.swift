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

final class ExtensionPointExtractorTaskProducer: PhasedTaskProducer, TaskProducer {

    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .unsignedProductRequirement
    }

    private func filterBuildFiles(_ buildFiles: [BuildFile]?, identifiers: [String], buildFilesProcessingContext: BuildFilesProcessingContext) -> [FileToBuild] {
        guard let buildFiles else {
            return []
        }

        let fileTypes = identifiers.compactMap { identifier in
            context.lookupFileType(identifier: identifier)
        }

        return fileTypes.flatMap { fileType in
            buildFiles.compactMap { buildFile in
                guard let resolvedBuildFileInfo = try? self.context.resolveBuildFileReference(buildFile),
                      !buildFilesProcessingContext.isExcluded(resolvedBuildFileInfo.absolutePath, filters: buildFile.platformFilters),
                      resolvedBuildFileInfo.fileType.conformsTo(fileType) else {
                    return nil
                }

                return FileToBuild(absolutePath: resolvedBuildFileInfo.absolutePath, fileType: fileType)
            }
        }
    }

    func generateTasks() async -> [any PlannedTask] {

        guard ExtensionPointExtractorSpec.shouldConstructTask(scope: context.settings.globalScope, productType: context.productType, isApplePlatform: context.isApplePlatform) else {
            return []
        }

        context.addDeferredProducer {

            let scope = self.context.settings.globalScope
            let buildFilesProcessingContext = BuildFilesProcessingContext(scope)

            let perArchConstMetadataFiles = self.context.generatedSwiftConstMetadataFiles()

            let constMetadataFiles: [Path]
            if let firstArch = perArchConstMetadataFiles.keys.sorted().first {
                constMetadataFiles = perArchConstMetadataFiles[firstArch]!
            } else {
                constMetadataFiles = []
            }

            let constMetadataFilesToBuild = constMetadataFiles.map { absolutePath -> FileToBuild in
                let fileType = self.context.workspaceContext.core.specRegistry.getSpec("file") as! FileTypeSpec
                return FileToBuild(absolutePath: absolutePath, fileType: fileType)
            }

            let inputs = constMetadataFilesToBuild
            guard inputs.isEmpty == false else {
                return []
            }

            var deferredTasks: [any PlannedTask] = []

            let cbc = CommandBuildContext(producer: self.context, scope: scope, inputs: inputs, resourcesDir: buildFilesProcessingContext.resourcesDir)
            await self.appendGeneratedTasks(&deferredTasks) { delegate in
                let domain = self.context.settings.platform?.name ?? ""
                guard let spec = self.context.specRegistry.getSpec("com.apple.compilers.extract-appextensionpoints", domain:domain) as? ExtensionPointExtractorSpec else {
                    return
                }
                await spec.constructTasks(cbc, delegate)
            }

            return deferredTasks
        }
        return []
    }
}


final class AppExtensionInfoPlistGeneratorTaskProducer: PhasedTaskProducer, TaskProducer {

    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .unsignedProductRequirement
    }

    private func filterBuildFiles(_ buildFiles: [BuildFile]?, identifiers: [String], buildFilesProcessingContext: BuildFilesProcessingContext) -> [FileToBuild] {
        guard let buildFiles else {
            return []
        }

        let fileTypes = identifiers.compactMap { identifier in
            context.lookupFileType(identifier: identifier)
        }

        return fileTypes.flatMap { fileType in
            buildFiles.compactMap { buildFile in
                guard let resolvedBuildFileInfo = try? self.context.resolveBuildFileReference(buildFile),
                      !buildFilesProcessingContext.isExcluded(resolvedBuildFileInfo.absolutePath, filters: buildFile.platformFilters),
                      resolvedBuildFileInfo.fileType.conformsTo(fileType) else {
                    return nil
                }

                return FileToBuild(absolutePath: resolvedBuildFileInfo.absolutePath, fileType: fileType)
            }
        }
    }

    func generateTasks() async -> [any PlannedTask] {

        let scope = context.settings.globalScope
        let productType = context.productType
        let isApplePlatform = context.isApplePlatform
        guard AppExtensionPlistGeneratorSpec.shouldConstructTask(scope: scope, productType: productType, isApplePlatform: isApplePlatform) else {
            return []
        }

        let tasks: [any PlannedTask] = []
        let buildFilesProcessingContext = BuildFilesProcessingContext(scope)

        let moduelName = context.settings.globalScope.evaluate(BuiltinMacros.TARGET_NAME)
        let plistPath = buildFilesProcessingContext.tmpResourcesDir.join(Path("\(moduelName)-appextension-generated-info.plist"))

        context.addDeferredProducer {

            let perArchConstMetadataFiles = self.context.generatedSwiftConstMetadataFiles()

            let constMetadataFiles: [Path]
            if let firstArch = perArchConstMetadataFiles.keys.sorted().first {
                constMetadataFiles = perArchConstMetadataFiles[firstArch]!
            } else {
                constMetadataFiles = []
            }

            let constMetadataFilesToBuild = constMetadataFiles.map { absolutePath -> FileToBuild in
                let fileType = self.context.workspaceContext.core.specRegistry.getSpec("file") as! FileTypeSpec
                return FileToBuild(absolutePath: absolutePath, fileType: fileType)
            }

            let inputs = constMetadataFilesToBuild
            var deferredTasks: [any PlannedTask] = []

            let cbc = CommandBuildContext(producer: self.context, scope: scope, inputs: inputs, output: plistPath)

            await self.appendGeneratedTasks(&deferredTasks) { delegate in
                let domain = self.context.settings.platform?.name ?? ""
                guard let spec = self.context.specRegistry.getSpec("com.apple.compilers.appextension-plist-generator",domain: domain) as? AppExtensionPlistGeneratorSpec else {
                    return
                }
                await spec.constructTasks(cbc, delegate)
            }

            return deferredTasks
        }
        self.context.addGeneratedInfoPlistContent(plistPath)
        return tasks
    }
}
