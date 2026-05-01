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
import SWBUtil
import Foundation

/// Workspace-level task producer that copies `experimentalWindowsDLL` artifact bundle variants
/// to each consuming target's build directory.
///
/// Following the same pattern as `XCFrameworkTaskProducer`, this producer runs in two phases:
///
/// 1. **prepare()** — iterates all target contexts *sequentially*, triple-matches DLL variants,
///    and registers (source, destination) pairs in `GlobalProductPlan.windowsDLLCopyContext`.
///    Because iteration is sequential, the first eligible target to register a destination always
///    wins, making winner selection deterministic across incremental builds.
///
/// 2. **generateTasks()** — emits exactly one `Copy` task per registered destination.
final class WindowsDLLCopyTaskProducer: StandardTaskProducer, TaskProducer {
    private let targetContexts: [TaskProducerContext]

    init(context globalContext: TaskProducerContext, targetContexts: [TaskProducerContext]) {
        self.targetContexts = targetContexts
        super.init(globalContext)
    }

    func prepare() {
        targetContexts.forEach(prepare(context:))
        context.globalProductPlan.windowsDLLCopyContext.freeze()
    }

    private func prepare(context: TaskProducerContext) {
        let scope = context.settings.globalScope

        // Collect artifact bundle build files, expanding package-product targets transitively
        // (the same traversal used by XCFrameworkTaskProducer).
        let artifactBundles = artifactBundleBuildFiles(for: context)

        for (_, absolutePath, _) in artifactBundles {
            let metadata: ArtifactBundleMetadata
            do {
                metadata = try context.globalProductPlan.artifactBundleMetadataCache
                    .getOrInsert(absolutePath) {
                        try ArtifactBundleMetadata.parse(at: absolutePath, fileSystem: context.fs)
                    }
            } catch {
                context.error("failed to parse artifact bundle metadata for '\(absolutePath)': \(error.localizedDescription)")
                continue
            }

            for (name, artifact) in metadata.artifacts {
                guard artifact.type == .experimentalWindowsDLL else { continue }

                // Triple matching is architecture-dependent, so evaluate per arch.
                var foundMatch = false
                for arch in scope.evaluate(BuiltinMacros.ARCHS) {
                    let archScope = scope.subscopeBindingArchAndTriple(arch: arch)
                    let triple = archScope.evaluate(BuiltinMacros.SWIFT_TARGET_TRIPLE)
                    let targetBuildDir = archScope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)

                    for variant in artifact.variants {
                        guard variant.supportedTriples == nil || variant.supportedTriples!.contains(where: {
                            normalizedTriplesCompareDisregardingOSVersions($0, triple)
                        }) else { continue }
                        foundMatch = true
                        let src = absolutePath.join(variant.path)
                        let dst = targetBuildDir.join(src.basename)
                        context.globalProductPlan.windowsDLLCopyContext.register(sourcePath: src, destinationPath: dst)
                    }
                }

                if !foundMatch {
                    context.warning("ignoring '\(name)' because the artifact bundle did not contain a matching variant", location: .path(absolutePath))
                }
            }
        }
    }

    func generateTasks() async -> [any PlannedTask] {
        let scope = context.settings.globalScope
        var tasks: [any PlannedTask] = []
        for req in context.globalProductPlan.windowsDLLCopyContext.copyRequirements {
            await appendGeneratedTasks(&tasks) { delegate in
                await context.copySpec.constructCopyTasks(
                    CommandBuildContext(producer: context, scope: scope,
                        inputs: [FileToBuild(context: context, absolutePath: req.sourcePath)],
                        output: req.destinationPath),
                    delegate, stripUnsignedBinaries: false)
            }
        }
        return tasks
    }

    // MARK: - Helpers

    /// Returns all artifact-bundle build files for a target, expanding package-product targets
    /// transitively (mirrors the traversal in XCFrameworkTaskProducer).
    private func artifactBundleBuildFiles(for context: TaskProducerContext) -> [(reference: Reference, absolutePath: Path, fileType: FileTypeSpec)] {
        let currentPlatformFilter = PlatformFilter(context.settings.globalScope)

        func buildFilesExpanding(phase: BuildPhaseWithBuildFiles) -> [BuildFile] {
            var phases = [phase]
            var enqueuedGUIDs: Set<String> = []
            var result: [BuildFile] = []
            while let current = phases.first {
                phases.removeFirst()
                for file in current.buildFiles {
                    guard currentPlatformFilter.matches(file.platformFilters) else { continue }
                    result.append(file)
                    if case .targetProduct(let guid) = file.buildableItem,
                       case let pkg as PackageProductTarget = context.workspaceContext.workspace.target(for: guid),
                       let frameworksPhase = pkg.frameworksBuildPhase,
                       !enqueuedGUIDs.contains(frameworksPhase.guid) {
                        phases.append(frameworksPhase)
                        enqueuedGUIDs.insert(frameworksPhase.guid)
                    }
                }
            }
            return result
        }

        let buildPhases: [BuildPhase]
        switch context.configuredTarget?.target {
        case let target as BuildPhaseTarget:
            buildPhases = target.buildPhases
        case let target as PackageProductTarget:
            guard let phase = target.frameworksBuildPhase else { return [] }
            buildPhases = [phase]
        default:
            return []
        }

        return buildPhases
            .compactMap { $0 as? BuildPhaseWithBuildFiles }
            .flatMap { buildFilesExpanding(phase: $0) }
            .compactMap { buildFile -> (Reference, Path, FileTypeSpec)? in
                guard currentPlatformFilter.matches(buildFile.platformFilters) else { return nil }
                return try? context.resolveBuildFileReference(buildFile)
            }
            .filter { $0.2.conformsTo(identifier: "wrapper.artifactbundle") }
    }
}
