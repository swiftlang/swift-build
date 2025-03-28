#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SwiftBuild
  CompatibilityShims.swift
  ConsoleCommands/SWBServiceConsoleBuildCommand.swift
  ConsoleCommands/SWBServiceConsoleBuildCommandProtocol.swift
  ConsoleCommands/SWBServiceConsoleCreateXCFrameworkCommand.swift
  ConsoleCommands/SWBServiceConsoleGeneralCommands.swift
  ConsoleCommands/SWBServiceConsoleSessionCommands.swift
  ConsoleCommands/SWBServiceConsoleXcodeCommands.swift
  ProjectModel/BuildConfig.swift
  ProjectModel/BuildFile.swift
  ProjectModel/BuildPhases.swift
  ProjectModel/BuildRule.swift
  ProjectModel/BuildSettings.swift
  ProjectModel/CustomTask.swift
  ProjectModel/ImpartedBuildProperties.swift
  ProjectModel/PlatformFilter.swift
  ProjectModel/Project.swift
  ProjectModel/ProjectModel.swift
  ProjectModel/References.swift
  ProjectModel/SandboxingOverride.swift
  ProjectModel/TargetDependency.swift
  ProjectModel/Targets.swift
  SWBBuildAction.swift
  SWBBuildOperation.swift
  SWBBuildOperationBacktraceFrame.swift
  SWBBuildParameters.swift
  SWBBuildRequest.swift
  SWBBuildService.swift
  SWBBuildServiceConnection.swift
  SWBBuildServiceConsole.swift
  SWBBuildServiceSession.swift
  SWBChannel.swift
  SWBClientExchangeSupport.swift
  SWBDocumentationSupport.swift
  SWBIndexingSupport.swift
  SWBLocalizationSupport.swift
  SWBMacroEvaluation.swift
  SWBPreviewSupport.swift
  SWBProductPlannerSupport.swift
  SWBPropertyList.swift
  SWBProvisioningTaskInputs.swift
  SWBSystemInfo.swift
  SWBTargetGUID.swift
  SWBTerminal.swift
  SWBuildMessage+Protocol.swift
  SWBUserInfo.swift
  SWBWorkspaceInfo.swift
  SwiftBuild.swift
  SwiftBuildVersion.swift
  TerminalAttributes.swift)
set_target_properties(SwiftBuild PROPERTIES
  Swift_LANGUAGE_VERSION 5)
target_link_libraries(SwiftBuild PUBLIC
  SWBCSupport
  SWBCore
  SWBProtocol
  SWBUtil
  SWBProjectModel)
