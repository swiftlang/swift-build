#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_executable(SWBBuildServiceBundle
  main.swift)
set_target_properties(SWBBuildServiceBundle PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_link_libraries(SWBBuildServiceBundle PRIVATE
  SWBBuildService
  SWBBuildSystem
  SWBServiceCore
  SWBUtil
  SWBCore)

install(TARGETS SWBBuildServiceBundle)
