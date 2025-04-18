#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBServiceCore STATIC
  Request.swift
  Service.swift
  ServiceEntryPoint.swift
  ServiceExtensionPoint.swift
  ServiceHostConnection.swift)
set_target_properties(SWBServiceCore PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_link_libraries(SWBServiceCore PUBLIC
  SWBProtocol)

target_include_directories(SWBServiceCore PUBLIC
  ${CMAKE_CURRENT_BINARY_DIR})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBServiceCore)
