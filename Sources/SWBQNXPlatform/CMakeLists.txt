#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBQNXPlatform
  Plugin.swift
  QNXSDP.swift)
SwiftBuild_Bundle(MODULE SWBQNXPlatform FILES
  Specs/QNX.xcspec
  Specs/QNXCompile.xcspec
  Specs/QNXLd.xcspec
  Specs/QNXLibtool.xcspec)
target_link_libraries(SWBQNXPlatform PUBLIC
  SWBCore
  SWBMacro
  SWBUtil)

set_target_properties(SWBQNXPlatform PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBQNXPlatform)

install(TARGETS SWBQNXPlatform
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
