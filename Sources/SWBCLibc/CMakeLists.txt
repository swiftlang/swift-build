#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBCLibc
  libc.c)
target_include_directories(SWBCLibc INTERFACE
  include)

target_include_directories(SWBCLibc PUBLIC
  ${CMAKE_CURRENT_BINARY_DIR})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBCLibc)

install(TARGETS SWBCLibc
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
