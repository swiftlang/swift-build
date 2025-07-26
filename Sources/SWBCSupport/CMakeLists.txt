#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBCSupport
  CLibclang.cpp
  CLibRemarksHelper.c
  POSIXShims.c
  empty.swift)
# Use swiftc as the linker so we pick up search paths for the blocks runtime,
# and enable C++ interop so it delegates to clang++.
set_target_properties(SWBCSupport PROPERTIES
  LINKER_LANGUAGE Swift)
set_target_properties(SWBCSupport PROPERTIES
  Swift_MODULE_NAME __SWBCSupport_Empty)
target_link_options(SWBCSupport PRIVATE
  -cxx-interoperability-mode=default)
target_compile_definitions(SWBCSupport PRIVATE
  $<$<PLATFORM_ID:Windows>:_CRT_SECURE_NO_WARNINGS>
  $<$<PLATFORM_ID:Windows>:_CRT_NONSTDC_NO_WARNINGS>)
target_compile_options(SWBCSupport PRIVATE
  "$<$<COMPILE_LANGUAGE:CXX>:SHELL:-fblocks>")
target_include_directories(SWBCSupport PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR})
# TODO(compnerd) wire this up with `find_package`
target_link_libraries(SWBCSupport PRIVATE
  $<$<NOT:$<PLATFORM_ID:Darwin>>:BlocksRuntime>)

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBCSupport)

install(TARGETS SWBCSupport
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
