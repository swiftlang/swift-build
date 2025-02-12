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

public struct BuiltinTaskActionsExtension: TaskActionExtension {
    public init() {
    }

    public var taskActionImplementations: [SerializableTypeCode : any PolymorphicSerializable.Type] {
        [
            1: AuxiliaryFileTaskAction.self,
            2: CopyPlistTaskAction.self,
            3: CopyStringsFileTaskAction.self,
            4: CopyTiffTaskAction.self,
            5: FileCopyTaskAction.self,
            6: InfoPlistProcessorTaskAction.self,
            // 7: Removed
            8: LSRegisterURLTaskAction.self,
            9: EmbedSwiftStdLibTaskAction.self,
            10: ProcessProductEntitlementsTaskAction.self,
            11: ProcessProductProvisioningProfileTaskAction.self,
            15: ValidateProductTaskAction.self,
            16: CreateBuildDirectoryTaskAction.self,
            17: ODRAssetPackManifestTaskAction.self,
            18: SwiftHeaderToolTaskAction.self,
            19: RegisterExecutionPolicyExceptionTaskAction.self,
            20: ClangCompileTaskAction.self,
            21: ProcessXCFrameworkTaskAction.self,
            22: SwiftCompilationTaskAction.self,
            23: SwiftDriverTaskAction.self,
            24: SwiftDriverCompilationRequirementTaskAction.self,
            26: ClangScanTaskAction.self,
            28: ValidateDevelopmentAssetsTaskAction.self,
            // 29: AppIntentsMetadataTaskAction.self, //removed
            30: DeferredExecutionTaskAction.self,
            31: LinkAssetCatalogTaskAction.self,
            32: SignatureCollectionTaskAction.self,
            33: CodeSignTaskAction.self,
            34: MergeInfoPlistTaskAction.self,
            35: ClangModuleVerifierInputGeneratorTaskAction.self,
            36: ConstructStubExecutorInputFileListTaskAction.self,
            37: ConcatenateTaskAction.self,
            38: GenericCachingTaskAction.self,
            39: ProcessSDKImportsTaskAction.self
        ]
    }
}
