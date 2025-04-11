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

import struct Foundation.Data
import class Foundation.PropertyListDecoder
import SWBMacro

/// The XCFrameworkTaskProducer needs to look at a various number of build phases to determine what work actually needs to be done. As part of this, the XCFramework itself needs to be inspected. The matching library within the XCFramework will be copied into the build destination root for later processing by the other build phases, such as the `SourcesBuildPhase`, to handle the linking of the library.
final class XCFrameworkTaskProducer: StandardTaskProducer, TaskProducer {
    private let targetContexts: [TaskProducerContext]

    init(context globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) {
        self.targetContexts = targetContexts
        super.init(globalContext)
    }

    /// Collects all of the XCFrameworks that are used within the project/workspace and adds them to a context object.
    func prepare() {
        targetContexts.forEach(prepare(context:))
        context.globalProductPlan.xcframeworkContext.freeze()
    }

    private func prepare(context: TaskProducerContext) {
        let scope = context.settings.globalScope
        let currentPlatformFilter = PlatformFilter(scope)

        func recursiveBuildFilesForPackageProducts(phase: BuildPhaseWithBuildFiles) -> [BuildFile] {
            var phases = [phase]
            var enqueuedPhaseGUIDs: Set<String> = []
            var buildFiles: [BuildFile] = []
            while let phase = phases.first {
                phases.removeFirst()
                for file in phase.buildFiles {
                    guard currentPlatformFilter.matches(file.platformFilters) else { continue }
                    buildFiles.append(file)
                    if case .targetProduct(let guid) = file.buildableItem, case let target as PackageProductTarget = context.workspaceContext.workspace.target(for: guid), let frameworksBuildPhase = target.frameworksBuildPhase {
                        if !enqueuedPhaseGUIDs.contains(frameworksBuildPhase.guid) {
                            phases.append(frameworksBuildPhase)
                            enqueuedPhaseGUIDs.insert(frameworksBuildPhase.guid)
                        }
                    }
                }
            }
            return buildFiles
        }

        func xcframeworksFor(phase: BuildPhaseWithBuildFiles?) -> [(reference: Reference, absolutePath: Path, fileType: FileTypeSpec)] {
            guard let phase else { return [] }
            return (recursiveBuildFilesForPackageProducts(phase: phase))
                .compactMap({ buildFile -> (reference: Reference, absolutePath: Path, fileType: FileTypeSpec)? in
                    guard currentPlatformFilter.matches(buildFile.platformFilters) else { return nil }
                    return try? context.resolveBuildFileReference(buildFile)
                })
                .filter({ $0.fileType.identifier == "wrapper.xcframework" })
        }

        guard let configuredTarget = context.configuredTarget else {
            assertionFailure("The XCFramework task producer preparation phase can only run in the context of a configured target.")
            return
        }

        let buildPhases: [BuildPhase]

        switch configuredTarget.target {
        case let target as BuildPhaseTarget:
            buildPhases = target.buildPhases
        case let target as PackageProductTarget:
            if let frameworksBuildPhase = target.frameworksBuildPhase {
                buildPhases = [frameworksBuildPhase]
            } else {
                return
            }
        default:
            // If the configured target is not a build phase or package product target, then we have no work to be done.
            return
        }

        // Track any of the XCFrameworks that can found across any of the build phases. This need to be stored in the `workspaceContext` to ensure that multiple are not created for the same XCFramework.
        for buildPhase in buildPhases.compactMap({ $0 as? BuildPhaseWithBuildFiles }) {
            for buildFile in xcframeworksFor(phase: buildPhase) {
                do {
                    let xcframeworkPath = buildFile.absolutePath
                    let expectedSignature = (context.workspaceContext.workspace.lookupReference(for: buildFile.reference.guid) as? FileReference)?.expectedSignature
                    try context.globalProductPlan.xcframeworkContext.add(xcframeworkPath, for: configuredTarget, expectedSignature: expectedSignature) { xcframework in
                        guard let library = xcframework.findLibrary(sdk: context.sdk, sdkVariant: context.sdkVariant) else {
                            let platformDisplayName = context.sdk?.targetBuildVersionPlatform(sdkVariant: context.sdkVariant)?.displayName(infoLookup: context) ?? context.platform?.displayName ?? "No Platform"
                            context.error("While building for \(platformDisplayName), no library for this platform was found in '\(xcframeworkPath.str)'.", location: .path(xcframeworkPath))
                            return nil
                        }

                        let outputDirectory = XCFramework.computeOutputDirectory(context.settings.globalScope)

                        return (library, outputDirectory)
                    }
                }
                catch {
                    context.error(error.localizedDescription)
                }
            }
        }
    }

    /// Creates the tasks to process all of the XCFrameworks found during the `.planning` phase.
    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        var tasks: [any PlannedTask] = []

        for config in context.globalProductPlan.xcframeworkContext.copyConfigurations {
            await appendGeneratedTasks(&tasks) { delegate in
                // Capture whether the XCFramework's output directory is a build directory.
                // While llbuild normally creates the directory hierarchy for the outputs of build tasks,
                // we specially create build directories regardless of whether other tasks would produce them, and with a
                // special extended attribute to mark them as having been created by the build system as a build directory.
                // Therefore, we need to create a strong ordering so that llbuild won't create the directory without the
                // attribute if the XCFramework task happens to run before the CreateBuildDirectory task.
                let outputDirectoryIsBuildDirectory = delegate.buildDirectories.contains(config.outputDirectory)

                let expectedSignatures: [String]?
                if let expectedSignature = config.expectedSignature {
                    expectedSignatures = [expectedSignature]
                }
                else {
                    expectedSignatures = nil
                }

                access(path: config.path)
                await context.processXCFrameworkLibrarySpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: config.path)], outputs: config.outputs, commandOrderingInputs: outputDirectoryIsBuildDirectory ? [delegate.createBuildDirectoryNode(absolutePath: config.outputDirectory)] : []), delegate, platform: config.platform, environment: config.environment, outputDirectory: config.outputDirectory, libraryPath: config.libraryPath, expectedSignatures: expectedSignatures)

                if scope.evaluate(BuiltinMacros.ENABLE_SIGNATURE_AGGREGATION) {
                    let output = config.outputDirectory.join("\(config.path.basename)-\(config.platform)\(config.environment.map { "-\($0)"} ?? "").signature")
                    context.signatureCollectionSpec.constructTasks(CommandBuildContext(producer: context, scope: scope, inputs: [FileToBuild(context: context, absolutePath: config.path)], output: output), delegate, platform: config.platform, platformVariant: config.environment, libraryPath: config.libraryPath)
                }
            }
        }

        return tasks
    }
}
