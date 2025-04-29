#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBCAS
  CASFSNode.swift
  CASProtocol.swift
  Errors.swift
  plugin_api_t.swift
  ToolchainCASPlugin.swift)
set_target_properties(SWBCAS PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_link_libraries(SWBCAS PUBLIC
  SWBUtil
  SWBCSupport)

set_target_properties(SWBCAS PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBCAS)

install(TARGETS SWBCAS
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
