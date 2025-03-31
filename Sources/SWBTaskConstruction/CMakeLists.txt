#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBTaskConstruction
  BuildDirectoryContext.swift
  DiagnosticSupport.swift
  ProductPlanning/BuildPlan.swift
  ProductPlanning/BuildPlanDumping.swift
  ProductPlanning/ProductPlan.swift
  ProductPlanning/ProductPlanner.swift
  StaleFileRemovalContext.swift
  TaskPlanningDelegate.swift
  TaskProducers/BuildPhaseTaskProducers/AppleScriptTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/BuildRuleTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/CopyFilesTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/FilesBasedBuildPhaseTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/HeadersTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/ResourcesTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/RezTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/ShellBasedTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/ShellScriptTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/SourcesTaskProducer.swift
  TaskProducers/BuildPhaseTaskProducers/SwiftPackageCopyFilesTaskProducer.swift
  TaskProducers/OtherTaskProducers/CopySwiftPackageResourcesTaskProducer.swift
  TaskProducers/OtherTaskProducers/CustomTaskProducer.swift
  TaskProducers/OtherTaskProducers/DevelopmentAssetsTaskProducer.swift
  TaskProducers/OtherTaskProducers/DocumentationTaskProducer.swift
  TaskProducers/OtherTaskProducers/ExternalTargetTaskProducer.swift
  TaskProducers/OtherTaskProducers/GenerateAppPlaygroundAssetCatalogTaskProducer.swift
  TaskProducers/OtherTaskProducers/GeneratedFilesTaskProducer.swift
  TaskProducers/OtherTaskProducers/HeadermapTaskProducer.swift
  TaskProducers/OtherTaskProducers/InfoPlistTaskProducer.swift
  TaskProducers/OtherTaskProducers/ModuleMapTaskProducer.swift
  TaskProducers/OtherTaskProducers/ModuleVerifierTaskProducer.swift
  TaskProducers/OtherTaskProducers/ProductPostprocessingTaskProducer.swift
  TaskProducers/OtherTaskProducers/ProductStructureTaskProducer.swift
  TaskProducers/OtherTaskProducers/SanitizerTaskProducer.swift
  TaskProducers/OtherTaskProducers/SDKStatCacheTaskProducer.swift
  TaskProducers/OtherTaskProducers/SwiftFrameworkABICheckerTaskProducer.swift
  TaskProducers/OtherTaskProducers/SwiftStandardLibrariesTaskProducer.swift
  TaskProducers/OtherTaskProducers/TAPISymbolExtractorTaskProducer.swift
  TaskProducers/OtherTaskProducers/TargetOrderTaskProducer.swift
  TaskProducers/OtherTaskProducers/XCTestProductTypeTaskProducer.swift
  TaskProducers/StandardTaskProducer.swift
  TaskProducers/TaskProducer.swift
  TaskProducers/TaskProducerExtensionPoint.swift
  TaskProducers/WorkspaceTaskProducers/CreateBuildDirectoryTaskProducer.swift
  TaskProducers/WorkspaceTaskProducers/HeadermapVFSTaskProducer.swift
  TaskProducers/WorkspaceTaskProducers/IndexBuildVFSDirectoryRemapTaskProducer.swift
  TaskProducers/WorkspaceTaskProducers/PCHModuleMapTaskProducer.swift
  TaskProducers/WorkspaceTaskProducers/XCFrameworkTaskProducer.swift
  TaskProducerSandboxing.swift
  XCFrameworkContext.swift)
set_target_properties(SWBTaskConstruction PROPERTIES
  Swift_LANGUAGE_VERSION 5)
target_link_libraries(SWBTaskConstruction PUBLIC
  SWBCore
  SWBUtil)
