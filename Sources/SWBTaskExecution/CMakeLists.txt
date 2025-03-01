#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBTaskExecution
  BuildDescription.swift
  BuildDescriptionManager.swift
  BuildDescriptionSignature.swift
  BuiltinTaskActionsExtension.swift
  DynamicTaskSpecs/ClangCachingKeyQueryDynamicTaskSpec.swift
  DynamicTaskSpecs/ClangCachingMaterializeKeyDynamicTaskSpec.swift
  DynamicTaskSpecs/ClangCachingOutputMaterializerDynamicTaskSpec.swift
  DynamicTaskSpecs/ClangCachingTaskCacheKey.swift
  DynamicTaskSpecs/ClangModuleDependencyGraph.swift
  DynamicTaskSpecs/CompilationCachingDataPruner.swift
  DynamicTaskSpecs/CompilationCachingUploader.swift
  DynamicTaskSpecs/DynamicTaskOperationContext.swift
  DynamicTaskSpecs/DynamicTaskSpecRegistry.swift
  DynamicTaskSpecs/PrecompileClangModuleDynamicTaskSpec.swift
  DynamicTaskSpecs/SwiftCachingDynamicTaskSpec.swift
  DynamicTaskSpecs/SwiftCachingTaskKeys.swift
  DynamicTaskSpecs/SwiftDriverJobDynamicTaskSpec.swift
  DynamicTaskSpecs/SwiftDriverPlanningDynamicTaskSpec.swift
  ProjectPlanner.swift
  Task.swift
  TaskActionExtensionPoint.swift
  TaskActions/AuxiliaryFileTaskAction.swift
  TaskActions/ClangCachingKeyQueryTaskAction.swift
  TaskActions/ClangCachingMaterializeKeyTaskAction.swift
  TaskActions/ClangCachingOutputMaterializerTaskAction.swift
  TaskActions/ClangCompileTaskAction.swift
  TaskActions/ClangModuleVerifierInputGeneratorTaskAction.swift
  TaskActions/ClangScanTaskAction.swift
  TaskActions/CodeSignTaskAction.swift
  TaskActions/ConcatenateTaskAction.swift
  TaskActions/ConstructStubExecutorInputFileListTaskAction.swift
  TaskActions/CopyPlistTaskAction.swift
  TaskActions/CopyStringsFileTaskAction.swift
  TaskActions/CopyTiffTaskAction.swift
  TaskActions/CreateBuildDirectoryTaskAction.swift
  TaskActions/DeferredExecutionTaskAction.swift
  TaskActions/EmbedSwiftStdLibTaskAction.swift
  TaskActions/FileCopyTaskAction.swift
  TaskActions/GenericCachingTaskAction.swift
  TaskActions/InfoPlistProcessorTaskAction.swift
  TaskActions/LinkAssetCatalogTaskAction.swift
  TaskActions/LSRegisterURLTaskAction.swift
  TaskActions/MergeInfoPlistTaskAction.swift
  TaskActions/ODRAssetPackManifestTaskAction.swift
  TaskActions/PrecompileClangModuleTaskAction.swift
  TaskActions/ProcessProductEntitlementsTaskAction.swift
  TaskActions/ProcessProductProvisioningProfileTaskAction.swift
  TaskActions/ProcessSDKImportsTaskAction.swift
  TaskActions/ProcessXCFrameworkTaskAction.swift
  TaskActions/RegisterExecutionPolicyExceptionTaskAction.swift
  TaskActions/SignatureCollectionTaskAction.swift
  TaskActions/SwiftCachingKeyQueryTaskAction.swift
  TaskActions/SwiftCachingMaterializeKeyTaskAction.swift
  TaskActions/SwiftCachingOutputMaterializerTaskAction.swift
  TaskActions/SwiftCompilationTaskAction.swift
  TaskActions/SwiftDriverCompilationRequirementTaskAction.swift
  TaskActions/SwiftDriverJobSchedulingTaskAction.swift
  TaskActions/SwiftDriverJobTaskAction.swift
  TaskActions/SwiftDriverTaskAction.swift
  TaskActions/SwiftHeaderToolTaskAction.swift
  TaskActions/TaskAction.swift
  TaskActions/ValidateDevelopmentAssetsTaskAction.swift
  TaskActions/ValidateProductTaskAction.swift
  TaskResult.swift
  TaskStore.swift)
set_target_properties(SWBTaskExecution PROPERTIES
  Swift_LANGUAGE_VERSION 5)
target_link_libraries(SWBTaskExecution PUBLIC
  SWBCAS
  SWBCore
  SWBLLBuild
  SWBTaskConstruction
  SWBUtil)
