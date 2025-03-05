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

import SWBUtil
public import SWBMacro

public final class CreateAssetPackManifestToolSpec : CommandLineToolSpec, SpecImplementationType, @unchecked Sendable {
    public static let identifier = "com.apple.build-tools.odr.create-asset-pack-manifest"

    public class func construct(registry: SpecRegistry, proxy: SpecProxy) -> Spec {
        return CreateAssetPackManifestToolSpec(registry, proxy, ruleInfoTemplate: [], commandLineTemplate: [])
    }

    public func constructAssetPackManifestTask(_ producer: any CommandProducer, _ assetPacks: [ODRAssetPackInfo], orderingInputs: [any PlannedNode], _ scope: MacroEvaluationScope, _ delegate: any TaskGenerationDelegate) {
        let unlocalizedProductResourcesDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).join(scope.evaluate(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH)).normalize()
        let assetPackManifestURLPrefix = scope.evaluate(BuiltinMacros.ASSET_PACK_MANIFEST_URL_PREFIX)
        let embedAssetPacksInProductBundle = scope.evaluate(BuiltinMacros.EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE)

        // The actual filename we use depends on what we're putting into it, per rdar://problem/20734598.
        let assetPackManifestName = embedAssetPacksInProductBundle || !assetPackManifestURLPrefix.isEmpty ? "AssetPackManifest.plist" : "AssetPackManifestTemplate.plist"
        let assetPackManifestPath = unlocalizedProductResourcesDir.join(assetPackManifestName)

        let ruleInfo = ["CreateAssetPackManifest", assetPackManifestPath.str]
        let execDescription = "Creating asset pack manifest"

        let action = delegate.taskActionCreationDelegate.createODRAssetPackManifestTaskAction()

        let environment: [String: String] = [
            BuiltinMacros.ASSET_PACK_MANIFEST_URL_PREFIX.name: assetPackManifestURLPrefix,
            BuiltinMacros.EMBED_ASSET_PACKS_IN_PRODUCT_BUNDLE.name: embedAssetPacksInProductBundle ? "YES" : "NO",
            BuiltinMacros.UnlocalizedProductResourcesDir.name: unlocalizedProductResourcesDir.str,
            BuiltinMacros.OutputPath.name: assetPackManifestPath.str,
        ]

        let inputs: [any PlannedNode] = assetPacks.flatMap { assetPack -> [any PlannedNode] in
            [delegate.createDirectoryTreeNode(assetPack.path),
             delegate.createNode(assetPack.path.join("Info.plist"))]
        } + orderingInputs
        let outputPath = assetPackManifestPath
        let outputs = [delegate.createNode(outputPath)]
        let commandLine = assetPacks.map { $0.path.str }.sorted()

        delegate.createTask(type: self, ruleInfo: ruleInfo, commandLine: commandLine, environment: EnvironmentBindings(environment), workingDirectory: producer.defaultWorkingDirectory, inputs: inputs, outputs: outputs, mustPrecede: [], action: action, execDescription: execDescription, preparesForIndexing: false, enableSandboxing: enableSandboxing)
    }
}
