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

import SWBBuildSystem
package import SWBCore
import SWBTaskConstruction
package import SWBTaskExecution
package import SWBUtil
import SWBMacro

enum PreviewInfoErrors: Error {
    case noBuildDescription(any Error)
    case failedToGetTargetBuildGraph(targetIDs: [String])
    case cancelled
    case unableToFindTarget(targetID: String)
}

protocol PreviewInfoDelegate: BuildDescriptionConstructionDelegate, PlanningOperationDelegate, TargetDependencyResolverDelegate {
    var clientDelegate: any ClientDelegate { get }
}

package struct PreviewInfoContext: Sendable {
    package let sdkRoot: String
    package let sdkVariant: String?
    package let buildVariant: String
    package let architecture: String

    package let pifGUID: String
}

package struct PreviewInfoOutput: Sendable {
    package let context: PreviewInfoContext

    package struct ThunkInfo: Sendable {
        package let compileCommandLine: [String]
        package let linkCommandLine: [String]

        package let thunkSourceFile: Path
        package let thunkObjectFile: Path
        package let thunkLibrary: Path
    }

    package struct TargetDependencyInfo: Sendable {
        package let objectFileInputMap: [String: Set<String>]
        package let linkCommandLine: [String]
        package let linkerWorkingDirectory: String?

        package let swiftEnableOpaqueTypeErasure: Bool
        package let swiftUseIntegratedDriver: Bool
        package let enableJITPreviews: Bool
        package let enableDebugDylib: Bool
        package let enableAddressSanitizer: Bool
        package let enableThreadSanitizer: Bool
        package let enableUndefinedBehaviorSanitizer: Bool
    }

    package enum Kind: Sendable {
        case thunkInfo(ThunkInfo)
        case targetDependencyInfo(TargetDependencyInfo)
    }

    package let info: Kind
}

extension PreviewInfoOutput {
    package var thunkInfo: ThunkInfo? {
        switch info {
        case let .thunkInfo(info):
            return info
        case .targetDependencyInfo:
            return nil
        }
    }

    package var targetDependencyInfo: TargetDependencyInfo? {
        switch info {
        case .thunkInfo:
            return nil
        case let .targetDependencyInfo(info):
            return info
        }
    }
}

extension BuildDescriptionManager {
    func generatePreviewInfo(
        workspaceContext: WorkspaceContext,
        buildRequest: BuildRequest,
        buildRequestContext: BuildRequestContext,
        delegate: any PreviewInfoDelegate,
        targetIDs: [String],
        input: TaskGeneratePreviewInfoInput
    ) async throws -> [PreviewInfoOutput] {
        // FIXME: We have temporarily disabled going through the planning operation, since it was causing significant churn: <rdar://problem/31772753> ProvisioningInputs are changing substantially for the same request
        let buildGraph = await TargetBuildGraph(
            workspaceContext: workspaceContext,
            buildRequest: buildRequest,
            buildRequestContext: buildRequestContext,
            delegate: delegate
        )
        if delegate.hadErrors {
            throw PreviewInfoErrors.failedToGetTargetBuildGraph(targetIDs: targetIDs)
        }
        let planRequest = BuildPlanRequest(
            workspaceContext: workspaceContext,
            buildRequest: buildRequest,
            buildRequestContext: buildRequestContext,
            buildGraph: buildGraph,
            provisioningInputs: [:]
        )

        // Get the complete build description.
        let buildDescription: BuildDescription
        do {
            if let retrievedBuildDescription = try await getBuildDescription(
                planRequest,
                clientDelegate: delegate.clientDelegate,
                constructionDelegate: delegate
            ) {
                buildDescription = retrievedBuildDescription
            } else {
                // If we don't receive a build description it means we were cancelled.
                throw PreviewInfoErrors.cancelled
            }
        } catch {
            throw PreviewInfoErrors.noBuildDescription(error)
        }

        let targetsByGuid = planRequest.buildGraph.allTargets.reduce([:]) { (dict, configuredTarget) -> [String: [ConfiguredTarget]] in
            var dict = dict
            dict[configuredTarget.target.guid, default: []].append(configuredTarget)
            return dict
        }

        // Collect and return the preview info.
        var targets: [ConfiguredTarget] = []
        for targetID in targetIDs {
            guard let potentialTargets = targetsByGuid[targetID] else { continue }
            for configuredTarget in potentialTargets {
                if case .thunkInfo = input,
                   let packageProductTarget = configuredTarget.target as? PackageProductTarget,
                   let dynamicTargetVariantGuid = packageProductTarget.dynamicTargetVariantGuid,
                   let dynamicTargetVariants = targetsByGuid[dynamicTargetVariantGuid]
                {
                    targets.append(contentsOf: dynamicTargetVariants)
                } else {
                    targets.append(configuredTarget)
                }
            }
        }

        if targetIDs.count == 1, targets.isEmpty {
            throw PreviewInfoErrors.unableToFindTarget(targetID: targetIDs[0])
        }

        return buildDescription.generatePreviewInfo(
            for: targets,
            workspaceContext: workspaceContext,
            buildRequestContext: buildRequestContext,
            input: input
        )
    }
}

extension BuildDescription {
    func generatePreviewInfo(for targets: [ConfiguredTarget], workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, input: TaskGeneratePreviewInfoInput) -> [PreviewInfoOutput] {

        let requestedTargetGuids: Set<ConfiguredTarget.GUID> = Set(targets.lazy.map(\.guid))

        // Group preview info by configured target.
        var taskPreviewInfo = [ConfiguredTarget: [TaskGeneratePreviewInfoOutput]]()
        taskStore.forEachTask { task in
            guard let forTarget = task.forTarget, requestedTargetGuids.contains(forTarget.guid) else { return }
            taskPreviewInfo[forTarget, default: []].append(contentsOf: task.generatePreviewInfo(input: input, fs: workspaceContext.fs))
        }

        var resultArray = [PreviewInfoOutput]()
        for (configuredTarget, previewInfos) in taskPreviewInfo {
            // For each configured target, we can have multiple sets of tasks, differentiated by arch/build variant.
            for variant in Set(previewInfos.map { $0.buildVariant }) {
                for arch in Set(previewInfos.map { $0.architecture }) {
                    // Get settings to compute the effective SDK and SDK_VARIANT values.
                    let settings = buildRequestContext.getCachedSettings(configuredTarget.parameters, target: configuredTarget.target)
                    guard let sdk = settings.sdk else {
                        continue
                    }

                    // The `previewStyle` is derived by checking for `ENABLE_PREVIEWS` and
                    // `ENABLE_XOJIT_PREVIEWS`. But we force both to be `false` when not in a Swift
                    // target. (See `addPreviewsOverrides()`) This makes sense for thunk info because
                    // we'll never ask for it for a non-Swift target today.
                    //
                    // But previews will be asking for target dependency info for *any* target that is linked
                    // by a previewable target. We need the linker args to be able to parse out how to
                    // reconstruct the non-Swift target with XOJIT. So it's ok if `previewStyle` is `nil`.
                    let previewStyle = settings.globalScope.previewStyle

                    // There should always be an exact number of preview infos for a given target/arch/variant, unless the preview style or target type (e.g. static library) doesn't support it.
                    let relevantPreviewInfos = previewInfos.filter { $0.architecture == arch && $0.buildVariant == variant }

                    let requestingTargetDependencyInfo: Bool
                    let compileInfo: TaskGeneratePreviewInfoOutput?
                    switch input {
                    case .targetDependencyInfo:
                        requestingTargetDependencyInfo = true

                        compileInfo = nil
                    case .thunkInfo:
                        requestingTargetDependencyInfo = false

                        let infos = relevantPreviewInfos.filter({ $0.type == .Swift })
                        switch infos.count {
                        case 1:
                            compileInfo = infos[0]
                        case 0:
                            // The target may not build any Swift files
                            continue
                        default:
                            assertionFailure("Expected exactly one preview info for Swift compilation for architecture \(arch) and variant \(variant) but found: \(relevantPreviewInfos)")
                            continue
                        }
                    }

                    let linkInfo: TaskGeneratePreviewInfoOutput?
                    switch previewStyle {
                    case .dynamicReplacement,
                        .xojit where requestingTargetDependencyInfo,
                        nil where requestingTargetDependencyInfo:
                        let infos = relevantPreviewInfos.filter({ $0.type == .Ld })
                        switch infos.count {
                        case 1:
                            let info = infos[0]
                            linkInfo = info
                            assert(requestingTargetDependencyInfo || compileInfo?.output == info.input) // make sure the tasks match up.
                        case 0:
                            // No link task because the target type is a static library (which doesn't support previews), or previews dylib is enabled
                            continue
                        default:
                            assertionFailure("Expected exactly one preview info for linking for architecture \(arch) and variant \(variant) but found: \(relevantPreviewInfos)")
                            continue
                        }
                    case .xojit:
                        linkInfo = nil
                    case nil:
                        // We don't have a preview style and target dependency info was not requested.
                        linkInfo = nil
                    }

                    // Construct the preview info for a particular combination of configured target, arch and build variant.
                    let context = PreviewInfoContext(sdkRoot: sdk.canonicalName, sdkVariant: settings.sdkVariant?.name, buildVariant: variant, architecture: arch, pifGUID: configuredTarget.target.guid)
                    let info: PreviewInfoOutput.Kind
                    switch input {
                    case .thunkInfo:
                        info = .thunkInfo(.init(compileCommandLine: compileInfo?.commandLine ?? [], linkCommandLine: linkInfo?.commandLine ?? [], thunkSourceFile: compileInfo?.input ?? Path(""), thunkObjectFile: compileInfo?.output ?? Path(""), thunkLibrary: linkInfo?.output ?? Path("")))
                    case .targetDependencyInfo:
                        let swiftInfos = Dictionary(grouping: relevantPreviewInfos.filter({ $0.type == .Swift }), by: { $0.output.str }).mapValues { Set($0.map { $0.input.str }) }
                        let targetInfo = PreviewInfoOutput.TargetDependencyInfo(
                            objectFileInputMap: swiftInfos,
                            linkCommandLine: linkInfo?.commandLine ?? [],
                            linkerWorkingDirectory: linkInfo?.workingDirectory.str,
                            swiftEnableOpaqueTypeErasure: settings.globalScope.evaluate(BuiltinMacros.SWIFT_ENABLE_OPAQUE_TYPE_ERASURE),
                            swiftUseIntegratedDriver: settings.globalScope.evaluate(BuiltinMacros.SWIFT_USE_INTEGRATED_DRIVER),
                            enableJITPreviews: settings.globalScope.evaluate(BuiltinMacros.ENABLE_XOJIT_PREVIEWS),
                            enableDebugDylib: settings.globalScope.evaluate(BuiltinMacros.ENABLE_DEBUG_DYLIB),
                            enableAddressSanitizer: settings.globalScope.evaluate(BuiltinMacros.ENABLE_ADDRESS_SANITIZER),
                            enableThreadSanitizer: settings.globalScope.evaluate(BuiltinMacros.ENABLE_THREAD_SANITIZER),
                            enableUndefinedBehaviorSanitizer: settings.globalScope.evaluate(BuiltinMacros.ENABLE_UNDEFINED_BEHAVIOR_SANITIZER)
                        )
                        info = .targetDependencyInfo(targetInfo)
                    }
                    let previewInfoOutput = PreviewInfoOutput(context: context, info: info)
                    resultArray.append(previewInfoOutput)
                }
            }
        }

        return resultArray
    }
}

extension BuildDescription {
    package func generatePreviewInfoForTesting(for targets: [ConfiguredTarget], workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, input: TaskGeneratePreviewInfoInput) -> [PreviewInfoOutput] {
        return generatePreviewInfo(for: targets, workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, input: input)
    }
}
