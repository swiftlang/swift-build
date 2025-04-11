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

public import SWBUtil
import SWBMacro

/// Protocol to support getting resolved information about a `BuildFile` within a `ConfiguredTarget`.
public protocol BuildFileResolution: SpecLookupContext {
    var workspaceContext: WorkspaceContext { get }
    var configuredTarget: ConfiguredTarget? { get }
    var settings: Settings { get }
    var globalTargetInfoProvider: any GlobalTargetInfoProvider { get }
}

extension BuildFileResolution {
    public var specRegistry: SpecRegistry {
        return platform?.specRegistry ?? workspaceContext.core.specRegistry
    }
}

/// Protocol to provide information about targets within the context of a build.
/// - remark: This is usually the `GlobalProductPlan` for the build. See that class for info about the characteristics of this protocol.
public protocol GlobalTargetInfoProvider {
    func getTargetSettings(_ configuredTarget: ConfiguredTarget) -> Settings
    func dependencies(of target: ConfiguredTarget) -> [ConfiguredTarget]
    var dynamicallyBuildingTargets: Set<Target> { get }
}

extension BuildFileResolution {

    /// Return the `Settings` for the given product reference `Target` in the target dependency graph of the current build.
    /// This is important if the producing target has context-dependent overrides which are important to the caller, rather than just applying the current configured target's parameters to the producing target.
    /// - remark: If the producing target is a dependency of the current target (likely, but not guaranteed), then the `Settings` will be looked up from the `TargetInfoProvider` (which is likely the `GlobalProductPlan`).  Otherwise a more complicated heuristic is used.
    public func settingsForProductReferenceTarget(_ productRefTarget: Target, parameters: BuildParameters) -> Settings {
        // If we have a concrete client target, we can look up the exact configured target that is producing the referenced product.
        if let clientConfiguredTarget = self.configuredTarget, let productRefConfiguredTarget = globalTargetInfoProvider.dependencies(of: clientConfiguredTarget).filter({ $0.target.guid == productRefTarget.guid }).only {
            return globalTargetInfoProvider.getTargetSettings(productRefConfiguredTarget)
        } else {
            // FIXME: A more reliable fallback might be to use GlobalProductPlan.productPathsToProducingTargets (where GlobalProductPlan conforms to TargetInfoProvider) if the absolute path of the product reference in this context were passed in.
            // If the reference is a product reference, then we want to use the settings for the configured target which produced it in this build, as it may have been built for a different platform and so we need to look up its information in the context of that platform.
            // FIXME: This is potentially unsound since there's no inherent guarantee that this configured target exists in the build graph, but I think in practice it should work?
            let potentialSettings = globalTargetInfoProvider.getTargetSettings(ConfiguredTarget(parameters: parameters, target: productRefTarget))
            // If the `productRefTarget` needs specialization, we need to override `SDKROOT`.
            // FIXME: Ideally, we would be in a position where we can just use the right configured target here.
            if potentialSettings.enableTargetPlatformSpecialization {
                var overrides = parameters.overrides
                overrides["SDKROOT"] = settings.globalScope.evaluate(BuiltinMacros.SDKROOT).str
                overrides["SUPPORTED_PLATFORMS"] = settings.globalScope.evaluate(BuiltinMacros.SUPPORTED_PLATFORMS).joined(separator: " ")
                overrides["SDK_VARIANT"] = settings.globalScope.evaluate(BuiltinMacros.SDK_VARIANT)
                if overrides["SDK_VARIANT"] != MacCatalystInfo.sdkVariantName {
                    overrides["SUPPORTS_MACCATALYST"] = "NO"
                }
                overrides["TOOLCHAINS"] = settings.globalScope.evaluate(BuiltinMacros.TOOLCHAINS).joined(separator: " ")
                return globalTargetInfoProvider.getTargetSettings(ConfiguredTarget(parameters: parameters.mergingOverrides(overrides), target: productRefTarget))
            } else {
                return potentialSettings
            }
        }
    }

    /// Resolve the information for a `BuildFile`.
    /// - returns: The concrete reference being built, its resolved absolute path, and its type.
    public func resolveBuildFileReference(_ buildFile: BuildFile, reference: Reference? = nil) throws -> (reference: Reference, absolutePath: Path, fileType: FileTypeSpec) {
        let (reference, _, absolutePath, fileType) = try resolveBuildFileReference(buildFile, reference: reference)
        return (reference, absolutePath, fileType)
    }

    /// Resolve the information for a `BuildFile`.
    /// - returns: The concrete reference being built, the `Settings` of its associated target, its resolved absolute path, and its type.
    /// - remark: This is a disfavored older version, as most clients don't need the `Settings` object.
    @_disfavoredOverload public func resolveBuildFileReference(_ buildFile: BuildFile, reference: Reference? = nil) throws -> (reference: Reference, settings: Settings, absolutePath: Path, fileType: FileTypeSpec) {
        let reference = try reference ?? workspaceContext.workspace.resolveBuildableItemReference(buildFile.buildableItem, dynamicallyBuildingTargets: globalTargetInfoProvider.dynamicallyBuildingTargets)
        let settingsForRef: Settings
        let specLookupContext: any SpecLookupContext
        switch reference {
        case let productRef as ProductReference:
            if let productRefTarget = productRef.target, let parameters = configuredTarget?.parameters {
                settingsForRef = settingsForProductReferenceTarget(productRefTarget, parameters: parameters)
                specLookupContext = SpecLookupCtxt(specRegistry: settingsForRef.platform?.specRegistry ?? workspaceContext.core.specRegistry, platform: settingsForRef.platform)
            }
            else {
                // If the product reference doesn't have a producing target, or we don't have a configured target, then... that's very weird.
                settingsForRef = settings
                specLookupContext = self
            }
        default:
            settingsForRef = settings
            specLookupContext = self
        }

        // Resolve the path and file type.
        let absolutePath: Path, fileType: FileTypeSpec?
        switch reference {
            // Variant groups always resolve the path and file type of the first reference.
            // FIXME: This is historical, and should be cleaned up by making the input model more explicit. This also isn't exactly what Xcode would do, which is very risky. It is possible that we should extend Xcode to pass this information down with the top-level variant group itself. (This FIXME is from 2017 and was ported from TaskProducer.)
        case let asVariantGroup as VariantGroup where !asVariantGroup.children.isEmpty:
            absolutePath = settingsForRef.filePathResolver.resolveAbsolutePath(asVariantGroup.children[0])
            fileType = specLookupContext.lookupFileType(reference: asVariantGroup.children[0])
        default:
            absolutePath = settingsForRef.filePathResolver.resolveAbsolutePath(reference)
            fileType = specLookupContext.lookupFileType(reference: reference)
        }

        return (reference, settingsForRef, absolutePath, fileType ?? specLookupContext.lookupFileType(identifier: "file")!)
    }

}

