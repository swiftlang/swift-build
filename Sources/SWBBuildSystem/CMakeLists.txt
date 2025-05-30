#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBBuildSystem
  BuildManager.swift
  BuildOperation.swift
  BuildOperationExtension.swift
  BuildSystemCache.swift
  CleanOperation.swift
  DependencyCycleFormatter.swift
  SandboxViolations.swift)
set_target_properties(SWBBuildSystem PROPERTIES
  Swift_LANGUAGE_VERSION 5)
target_link_libraries(SWBBuildSystem PUBLIC
  SWBCore
  SWBTaskConstruction
  SWBTaskExecution)

set_target_properties(SWBBuildSystem PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBBuildSystem)

install(TARGETS SWBBuildSystem
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
