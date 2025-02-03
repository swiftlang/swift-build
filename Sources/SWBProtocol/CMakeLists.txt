#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBProtocol
  AsyncSequence.swift
  BuildAction.swift
  BuildOperationMessages.swift
  BuildSettingsInfoMessageTypes.swift
  ClientExchangeMessages.swift
  DependencyClosureMessages.swift
  DependencyGraphMessages.swift
  DocumentationMessages.swift
  IndexingMessages.swift
  LocalizationMessages.swift
  MacroEvaluationMessages.swift
  Message.swift
  MessageSupport.swift
  PIFKeyConstants.swift
  PlanningOperationMessages.swift
  PreviewMessages.swift
  ProjectDescriptorMessages.swift
  ProjectDescriptorTypes.swift
  ProjectModel/BuildConfiguration.swift
  ProjectModel/BuildFile.swift
  ProjectModel/BuildPhase.swift
  ProjectModel/BuildRule.swift
  ProjectModel/CustomTask.swift
  ProjectModel/DependencyInfo.swift
  ProjectModel/ImpartedBuildProperties.swift
  ProjectModel/MacroExpressionSource.swift
  ProjectModel/PIFObject.swift
  ProjectModel/PlatformFilter.swift
  ProjectModel/Project.swift
  ProjectModel/ProvisioningSourceData.swift
  ProjectModel/Reference.swift
  ProjectModel/SourceTree.swift
  ProjectModel/Target.swift
  ProjectModel/TargetDependency.swift
  ProjectModel/Workspace.swift)
set_target_properties(SWBProtocol PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_link_libraries(SWBProtocol PUBLIC
  SWBUtil)
