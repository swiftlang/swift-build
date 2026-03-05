#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBWindowsPlatform
  KnownFolders.swift
  Plugin.swift
  VSInstallation.swift)
SwiftBuild_Bundle(MODULE SWBWindowsPlatform FILES
  Specs/Windows.xcspec
  Specs/WindowsCompile.xcspec
  Specs/WindowsLd.xcspec
  Specs/WindowsLibtool.xcspec
  Specs/WindowsStripSymbols.xcspec)
target_link_libraries(SWBWindowsPlatform PUBLIC
  SWBCore
  SWBMacro
  SWBUtil)

set_target_properties(SWBWindowsPlatform PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBWindowsPlatform)

install(TARGETS SWBWindowsPlatform
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
