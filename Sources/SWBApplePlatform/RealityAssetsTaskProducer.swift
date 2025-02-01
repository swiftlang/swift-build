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
import Foundation
import SWBTaskConstruction

/// This task producer is responsible for creating tasks which result in the Reality Asset .reality file being produced in its final form and location.
///
///   * Collecting a list of swift files in this build target and an any dependencies that have swift files, and creating a .json file with that info
///   * Creating a task to use the .json file as input to create a schema .usda file from the list of swift files as an intermediate file for realitytool compile
///   * Creating a task to create the .reality file from the .rkassets and the optional .usda schema file
///
/// The .reality is to be embedded into a binary, so the final version produced by these tasks will be consumed elsewhere (probably by the linker).

extension ModuleWithDependencies {
    fileprivate enum ModuleWithDependenciesError: Error {
        case failedToEncodeData
        case failedToWriteFile
    }

    fileprivate func write(_ filePath: Path, fsProxy: any FSProxy) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let jsonData = try? encoder.encode(self) else {
            throw ModuleWithDependenciesError.failedToEncodeData
        }
        do {
            try fsProxy.write(filePath, contents: ByteString(Array(jsonData)))
        } catch {
            throw ModuleWithDependenciesError.failedToWriteFile
        }
    }
}

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

    fileprivate func swiftFilesToBuild(context: TaskProducerContext, scope: MacroEvaluationScope) -> [FileToBuild] {
        guard let buildFiles = sourcesBuildPhase?.buildFiles else { return [] }
        guard let swiftFileType = context.lookupFileType(identifier: "sourcecode.swift") else { return [] }

        return filesToBuild(context: context, scope: scope, buildFiles: buildFiles, fileType: swiftFileType)
    }

    fileprivate func rkAssetFilesToBuild(context: TaskProducerContext, scope: MacroEvaluationScope) -> [FileToBuild] {
        guard let buildFiles = resourcesBuildPhase?.buildFiles else { return [] }
        guard let rkAssetsFileType = context.lookupFileType(identifier: "folder.rkassets") else { return [] }

        return filesToBuild(context: context, scope: scope, buildFiles: buildFiles, fileType: rkAssetsFileType)
    }

}

extension ConfiguredTarget {

    fileprivate func rkAssetsToBuild(context: TaskProducerContext) -> [FileToBuild] {
        guard let standardTarget = target as? StandardTarget else { return [] }
        return standardTarget.rkAssetFilesToBuild(context: context, scope: context.settings.globalScope)
    }

}

final class RealityAssetsTaskProducer: PhasedTaskProducer, TaskProducer {
    private let tempSubDirectory = "RealityAssetsGenerated"
    private let usdaSchemaFile = "CustomComponentUSDInitializers.usda"
    private let moduleWithDependenciesFile = "ModuleWithDependencies.json"

    override var defaultTaskOrderingOptions: TaskOrderingOptions {
        return .compilationRequirement
    }

    // find any targets that configuredTarget depends on that have .rkassets
    private func findDependencyTargetsWithRKAssetsToBuild(_ configuredTarget: ConfiguredTarget) -> [ConfiguredTarget] {
        context.globalProductPlan.dependencies(of: configuredTarget).compactMap { dependencyConfiguredTarget in
            !dependencyConfiguredTarget.rkAssetsToBuild(context: context).isEmpty ? dependencyConfiguredTarget : nil
        }
    }

    private func findRegularPackageTarget(for resourcePackageTarget: ConfiguredTarget) -> ConfiguredTarget? {
        // for swift packages there is a 1:1 relationship between a Swift Package PACKAGE-TARGET
        // which depends on its PACKAGE-RESOURCE "resource" which contains the .rkassets.
        // We need to find the PACKAGE-TARGET "regular" for this PACKAGE-RESOURCE which requires
        // that they both be in the same project as well.
        let resourcePackageTargetSettings = context.globalProductPlan.getTargetSettings(resourcePackageTarget)
        let resourcePackageTargetKind = resourcePackageTargetSettings.globalScope.evaluate(BuiltinMacros.PACKAGE_RESOURCE_TARGET_KIND)
        guard resourcePackageTargetKind == .resource else {
            return nil
        }

        // the resourcePackageTarget must be part of a project that isPackage,
        // and is the same project as the regularConfiguredTarget we find below
        guard let resourcePackageProject = resourcePackageTargetSettings.project, resourcePackageProject.isPackage else {
            return nil
        }

        // now search all targets in this product plan to find one with a dependency that is
        // resourcePackageTarget and that is in the resource package target project.
        // Maybe there is a better way...
        let regularConfiguredTarget = context.globalProductPlan.allTargets.first { regularConfiguredTarget in
            guard regularConfiguredTarget != resourcePackageTarget else {
                return false
            }

            let regularConfiguredTargetSettings = context.globalProductPlan.getTargetSettings(regularConfiguredTarget)
            guard let project = regularConfiguredTargetSettings.project,
               project.isPackage,
               resourcePackageProject == project else {
                return false
            }

            let regularConfiguredTargetKind = regularConfiguredTargetSettings.globalScope.evaluate(BuiltinMacros.PACKAGE_RESOURCE_TARGET_KIND)
            guard regularConfiguredTargetKind == .regular else {
                return false
            }
            return findDependencyTargetsWithRKAssetsToBuild(regularConfiguredTarget).contains(resourcePackageTarget)
        }
        guard let regularConfiguredTarget else {
            return nil
        }
        return regularConfiguredTarget
    }

    // dependencySwiftFiles() can be recursive...
    // since a target can have a dependency that is a "PACKAGE-PRODUCT"
    // which will depend on a "PACKAGE-TARGET" which actually has the
    // sources to build
    private func dependencySwiftFiles(_ configuredTarget: ConfiguredTarget) -> [ModuleSpec] {
        return context.globalProductPlan.dependencies(of: configuredTarget).compactMap { dependencyConfiguredTarget -> [ModuleSpec] in
            guard let target = dependencyConfiguredTarget.target as? BuildPhaseTarget else {
                return dependencySwiftFiles(dependencyConfiguredTarget)
            }

            let swiftFiles = target.swiftFilesToBuild(context: context, scope: context.settings.globalScope)
            guard !swiftFiles.isEmpty else {
                return []
            }
            let moduleSpec = ModuleSpec(
                moduleName: context.globalProductPlan.getTargetSettings(dependencyConfiguredTarget).globalScope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME),
                swiftFiles: swiftFiles.map { $0.absolutePath.str }
            )
            return [moduleSpec]
        }.flatMap { $0 }
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        var tasks: [any PlannedTask] = []

        guard let configuredTarget = context.configuredTarget else {
            return []
        }

        // get the rkAssets file to build for this producer
        let rkAssetsFilesToBuild = configuredTarget.rkAssetsToBuild(context: context)
        guard !rkAssetsFilesToBuild.isEmpty else {
            return []
        }
        // configuredTarget has a resources build phase and at least one .rkassets to build

        var schemaPath: Path?
        // regularStandardTarget will be non-nil if this target is a resource build with .rkassets,
        // and we found the "regular" sources target with this configuredTarget as a dependency
        if let regularConfiguredTarget = findRegularPackageTarget(for: configuredTarget),
           let regularStandardTarget = regularConfiguredTarget.target as? StandardTarget {

            // regularStandardTarget has sources build phase with .swift files that need to be
            // preprocessed into a .usda schema that will be used to compile the .rkassets
            // we also need any dependencies that have .swift files as input to the preprocess

            let swiftFiles = regularStandardTarget.swiftFilesToBuild(context: context, scope: scope)

            // Collect the dependencies of regularStandardTarget that have sources build phases with
            // .swift files.  This collection process can be recursive through dependencies of dependencies.
            let swiftDependencies = dependencySwiftFiles(regularConfiguredTarget)

            if !swiftFiles.isEmpty || !swiftDependencies.isEmpty {
                schemaPath = scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join(tempSubDirectory).join(usdaSchemaFile)

                let moduleWithDependencies = ModuleWithDependencies(
                    module: ModuleSpec(
                        moduleName: context.globalProductPlan.getTargetSettings(regularConfiguredTarget).globalScope.evaluate(BuiltinMacros.PRODUCT_MODULE_NAME),
                        swiftFiles: swiftFiles.map { $0.absolutePath.str }
                    ),
                    dependencies: swiftDependencies
                )

                let derivedDataPath = scope.evaluate(BuiltinMacros.DERIVED_FILE_DIR).join(tempSubDirectory)
                if !context.fs.exists(derivedDataPath) {
                    do {
                        try context.fs.createDirectory(derivedDataPath, recursive: true)
                    }
                    catch let error as NSError {
                        context.error("Could not create directory for '\(moduleWithDependenciesFile)', \(error.localizedDescription)")
                        return []
                    }
                }
                let moduleWithDependenciesPath = derivedDataPath.join(moduleWithDependenciesFile)

                do {
                    try moduleWithDependencies.write(moduleWithDependenciesPath, fsProxy: context.fs)
                }
                catch let error as NSError {
                    if error.domain == "org.swift.swift-build" {
                        context.error(error.localizedDescription)
                    } else {
                        context.error("Failed to create '\(moduleWithDependenciesPath.str)': \(error.localizedDescription)")
                    }
                    return []
                }

                let textSpec = context.workspaceContext.core.specRegistry.getSpec("text") as! FileTypeSpec
                let inputFile = FileToBuild(absolutePath: moduleWithDependenciesPath, fileType: textSpec)

                let cbc = CommandBuildContext(producer: context, scope: scope, inputs: [inputFile], output: schemaPath)

                // Construct tasks for the input group.
                await appendGeneratedTasks(&tasks) { delegate in
                    await (context.realityAssetsCompilerSpec as? RealityAssetsCompilerSpec)?.constructTasks(cbc, delegate, moduleWithDependencies: moduleWithDependencies)
                }
            }
        }

        for rkAssetsToBuild in rkAssetsFilesToBuild {
            var inputFiles = [rkAssetsToBuild]
            if let schemaPath {
                // TODO: check that schemaPath file exists and is not empty
                let fileType = context.workspaceContext.core.specRegistry.getSpec("file") as! FileTypeSpec
                inputFiles.append(FileToBuild(absolutePath: schemaPath, fileType: fileType))
            }

            let realtyFileName = rkAssetsToBuild.absolutePath.basenameWithoutSuffix.appending(".reality")
            let outputPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
                .join(scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH))
                .join(realtyFileName)

            let cbc = CommandBuildContext(producer: context, scope: scope, inputs: inputFiles, output: outputPath)

            // Construct tasks for the input group.
            await appendGeneratedTasks(&tasks) { delegate in
                await context.realityAssetsCompilerSpec?.constructTasks(cbc, delegate)
            }
        }

        return tasks
    }
}
