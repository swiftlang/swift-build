#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBGenericUnixPlatform
  Plugin.swift)
SwiftBuild_Bundle(MODULE SWBGenericUnixPlatform FILES
  Specs/Unix.xcspec
  Specs/UnixCompile.xcspec
  Specs/UnixLd.xcspec
  Specs/UnixLibtool.xcspec)
target_link_libraries(SWBGenericUnixPlatform PUBLIC
  SWBCore
  SWBUtil)

set_target_properties(SWBGenericUnixPlatform PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBGenericUnixPlatform)

install(TARGETS SWBGenericUnixPlatform
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
