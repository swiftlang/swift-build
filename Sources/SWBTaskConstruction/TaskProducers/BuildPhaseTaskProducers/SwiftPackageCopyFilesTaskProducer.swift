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

import class Foundation.Bundle
import class Foundation.FileHandle

import SWBCore
import SWBUtil
import SWBMacro

/// Produces tasks for a runtime-synthesized build phase includes linked frameworks produced by package targets, into non-package targets.
final class SwiftPackageCopyFilesTaskProducer: CopyFilesTaskProducer {
    static func buildFilesForPackages(context: TargetTaskProducerContext, frameworksBuildPhase: FrameworksBuildPhase?) -> [BuildFile] {
        let scope = context.settings.globalScope
        let currentPlatformFilter = PlatformFilter(scope)
        var processedBuildFileGUIDs = [String]()

        func lookupProductType(_ ident: String) -> ProductTypeSpec? {
            do {
                return try context.getSpec(ident)
            } catch {
                context.error("Couldn't look up product type '\(ident)' in domain '\(context.domain)': \(error)")
                return nil
            }
        }

        // Do not embed frameworks into frameworks, application extensions (except watch extensions) or static libraries.
        let productTypeIdentifier = scope.evaluate(BuiltinMacros.PRODUCT_TYPE)
        if !productTypeIdentifier.isEmpty, let productType = lookupProductType(productTypeIdentifier), productType.conformsTo(identifier: "com.apple.product-type.framework") || (productType.conformsTo(identifier: "com.apple.product-type.app-extension") && !productType.conformsTo(identifier: "com.apple.product-type.watchkit2-extension")) || productType.conformsTo(identifier: "com.apple.product-type.library.static") || productType.conformsTo(identifier: "com.apple.product-type.library.dynamic") {
            return []
        }

        func recursiveBuildFilesForPackageProducts(phase: BuildPhaseWithBuildFiles) -> [BuildFile] {
            var phases = [phase]
            var enqueuedPhaseGUIDs: Set<String> = []
            var buildFiles: [BuildFile] = []
            // Don't include the files from the input build phase in the output.
            var includeBuildFiles = false
            while let phase = phases.first {
                phases.removeFirst()
                for file in phase.buildFiles {
                    guard currentPlatformFilter.matches(file.platformFilters) else { continue }

                    if includeBuildFiles {
                        buildFiles.append(file)
                    }
                    if case .targetProduct(let guid) = file.buildableItem, let target = context.workspaceContext.workspace.target(for: guid) {
                        // If this is a package producer reference, visit it recursively.
                        if let target = target as? PackageProductTarget, let frameworksBuildPhase = target.frameworksBuildPhase {
                            // If this target builds dynamically, make sure it gets copied.
                            if context.globalProductPlan.dynamicallyBuildingTargets.contains(target) && !processedBuildFileGUIDs.contains(file.guid) {
                                // We should only synthesize one build file per source build file here.
                                processedBuildFileGUIDs.append(file.guid)
                                let generatedBuildFileGuid = "\(target.guid)-\(file.guid)"
                                // Use an empty platform filter because package product dependencies cannot be conditionalized.
                                buildFiles.append(BuildFile(guid: generatedBuildFileGuid, targetProductGuid: target.guid, platformFilters: Set()))
                            }

                            if !enqueuedPhaseGUIDs.contains(frameworksBuildPhase.guid) {
                                phases.append(frameworksBuildPhase)
                                enqueuedPhaseGUIDs.insert(frameworksBuildPhase.guid)
                            }
                            continue
                        }
                        // If this references a standard target from a package, it could also reference additional frameworks.
                        if context.workspaceContext.workspace.project(for: target).isPackage, let target = target as? StandardTarget, let frameworksBuildPhase = target.frameworksBuildPhase, !enqueuedPhaseGUIDs.contains(frameworksBuildPhase.guid) {
                            phases.append(frameworksBuildPhase)
                            enqueuedPhaseGUIDs.insert(frameworksBuildPhase.guid)
                        }
                    }
                }
                includeBuildFiles = true
            }

            return buildFiles
        }

        func shouldEmbedXCFramework(path xcframeworkPath: Path) throws -> Bool {
            let xcFramework = try XCFramework(path: xcframeworkPath, fs: context.fs)
            guard let library = xcFramework.findLibrary(sdk: context.sdk, sdkVariant: context.sdkVariant) else { return false }

            switch library.libraryType {
            case .dynamicLibrary:
                return true

            case .staticLibrary:
                return false

            case .framework:
                let rootPathToFramework = xcframeworkPath.join(library.libraryIdentifier)
                let frameworkPath = rootPathToFramework.join(library.libraryPath)
                let machOInfo = try context.globalProductPlan.planRequest.buildRequestContext.getCachedMachOInfo(at: frameworkPath)

                switch machOInfo.linkage {
                case .macho(let fileType):
                    switch fileType {
                    case .dylib:
                        return !context.skipDynamicFrameworks
                    case .object:
                        return !context.skipStaticFrameworks
                    default:
                        return true
                    }
                case .static:
                    return !context.skipStaticFrameworks
                }

            case .unknown(_):
                return false // Embedding unknown files will likely only end up tripping up validation, so we should not do that.
            }
        }

        func frameworksFor(phase: BuildPhaseWithBuildFiles?, outputPathsToFilter: [Path]) -> [BuildFile] {
            guard let phase else { return [] }
            // If the frameworks phase we are starting with is itself declared in a package product, include its build files in the automatic discovery. For all other target types, XCFrameworks have to be manually added to the copy phase, so we do not include their build files here.
            let isPackageProduct = context.configuredTarget?.target.type == .packageProduct
            let initialBuildFiles = isPackageProduct ? phase.buildFiles : []
            return (initialBuildFiles + recursiveBuildFilesForPackageProducts(phase: phase)).filter { buildFile in
                guard currentPlatformFilter.matches(buildFile.platformFilters) else { return false }
                guard let resolvedBuildFile = try? context.resolveBuildFileReference(buildFile) else { return false }
                // If the given framework is already embedded by the explicit Copy Frameworks phase, skip it, unless its dynamic variant is being used.
                guard buildFile.buildsDynamically(context) || !outputPathsToFilter.contains(resolvedBuildFile.absolutePath) else { return false }
                //  We do not need to do a conformance check here because we do not expect package products to ever have build files for any subtypes of these file types.
                if resolvedBuildFile.fileType.identifier == "wrapper.xcframework" {
                    do {
                        return try shouldEmbedXCFramework(path: resolvedBuildFile.absolutePath)
                    } catch {
                        context.error(error.localizedDescription)
                        // Fall back to embedding the XCFramework.
                        return true
                    }
                }
                return resolvedBuildFile.fileType.identifier == "wrapper.framework"
            }
        }

        if let frameworksBuildPhase {
            let outputPaths = frameworksBuildPhase.buildFiles.compactMap { try? context.resolveBuildFileReference($0).absolutePath }
            let buildFilesToInclude = frameworksFor(phase: frameworksBuildPhase, outputPathsToFilter: outputPaths)

            // There can still be multiple build files for the same framework that differ in their platform filters, we need to merge them.
            var buildFilesPerOutputPath = [Path: [BuildFile]]()
            for buildFile in buildFilesToInclude {
                guard let resolvedBuildFile = try? context.resolveBuildFileReference(buildFile) else { continue }
                buildFilesPerOutputPath[resolvedBuildFile.absolutePath, default: []].append(buildFile)
            }

            let buildFiles: [BuildFile] = buildFilesPerOutputPath.compactMap { _, buildFiles in
                // We can use the first build file as representative for anything but platform filters, because they are all created uniformly by SwiftPM.
                guard let firstBuildFile = buildFiles.first else { return nil }

                let platformFilters = buildFiles.map { $0.platformFilters }
                let aggregatedPlatformFilters: Set<PlatformFilter>
                if platformFilters.contains(where: { $0.isEmpty }) {
                    aggregatedPlatformFilters = [] // If any build file supports all platforms, we embed for all platforms.
                } else {
                    aggregatedPlatformFilters = platformFilters.reduce([]) { $0.union($1) }
                }

                let target: Target
                if case .targetProduct(let guid) = firstBuildFile.buildableItem, let _target = context.workspaceContext.workspace.target(for: guid)  {
                    target = _target
                } else {
                    // If this isn't a target product reference, it has to be a `binaryTarget` which does not support platform filters by definition, so we can return the first build file instead.
                    assert(aggregatedPlatformFilters.isEmpty)
                    return firstBuildFile
                }

                return BuildFile(guid: firstBuildFile.guid, targetProductGuid: target.guid, platformFilters: aggregatedPlatformFilters)
            }

            return buildFiles
        } else {
            return []
        }
    }

    private let generatedBuildPhase: CopyFilesBuildPhase

    init(_ context: TargetTaskProducerContext, phaseStartNodes: [any PlannedNode], phaseEndNode: any PlannedNode, phaseEndTask: any PlannedTask, frameworksBuildPhase: FrameworksBuildPhase?) {
        let configuredTarget = context.configuredTarget! // We assume a `TargetTaskProducerContext` always has an associated configured target.

        let guid = "\(configuredTarget.target.guid)-package-copy-files-phase"
        let buildFiles = Self.buildFilesForPackages(context: context, frameworksBuildPhase: frameworksBuildPhase)
        let destinationSubfolder = context.settings.globalScope.namespace.parseString("$(CONTENTS_FOLDER_PATH)/Frameworks")
        let destinationSubpath = context.settings.globalScope.namespace.parseString("")
        self.generatedBuildPhase = CopyFilesBuildPhase(guid: guid, buildFiles: buildFiles, destinationSubfolder: destinationSubfolder, destinationSubpath: destinationSubpath, runOnlyForDeploymentPostprocessing: false)

        super.init(context, buildPhase: generatedBuildPhase, phaseStartNodes: phaseStartNodes, phaseEndNode: phaseEndNode, phaseEndTask: phaseEndTask)
    }
}

fileprivate extension BuildFile {
    func buildsDynamically(_ context: TaskProducerContext) -> Bool {
        if case .targetProduct(let guid) = buildableItem, let target = context.workspaceContext.workspace.target(for: guid) {
            return context.globalProductPlan.dynamicallyBuildingTargets.contains(target)
        } else {
            return false
        }
    }
}

fileprivate extension TargetTaskProducerContext {
    var skipDynamicFrameworks: Bool {
        return settings.globalScope.evaluate(BuiltinMacros.PACKAGE_SKIP_AUTO_EMBEDDING_DYNAMIC_BINARY_FRAMEWORKS)
    }

    var skipStaticFrameworks: Bool {
        return settings.globalScope.evaluate(BuiltinMacros.PACKAGE_SKIP_AUTO_EMBEDDING_STATIC_BINARY_FRAMEWORKS)
    }
}
