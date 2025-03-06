#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBBuildService
  BuildDependencyInfo.swift
  BuildOperationMessages.swift
  BuildService.swift
  BuildServiceEntryPoint.swift
  ClientExchangeDelegate.swift
  DependencyGraphMessages.swift
  DocumentationInfo.swift
  LocalizationInfo.swift
  Messages.swift
  PlanningOperation.swift
  PreviewInfo.swift
  ProjectDescriptor.swift
  Session.swift
  Tools.swift)
set_target_properties(SWBBuildService PROPERTIES
  Swift_LANGUAGE_VERSION 5)
target_link_libraries(SWBBuildService PUBLIC
  SWBBuildSystem
  SWBServiceCore
  SWBTaskExecution
  SWBAndroidPlatform
  SWBApplePlatform
  SWBGenericUnixPlatform
  SWBQNXPlatform
  SWBUniversalPlatform
  SWBWebAssemblyPlatform
  SWBWindowsPlatform
  $<$<NOT:$<PLATFORM_ID:Darwin>>:SwiftSystem::SystemPackage>)
