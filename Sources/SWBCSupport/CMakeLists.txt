#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBCSupport STATIC
  CLibclang.cpp
  CLibRemarksHelper.c)
target_compile_definitions(SWBCSupport PRIVATE
  $<$<PLATFORM_ID:Windows>:_CRT_SECURE_NO_WARNINGS>
  $<$<PLATFORM_ID:Windows>:_CRT_NONSTDC_NO_WARNINGS>)
target_compile_options(SWBCSupport PRIVATE
  -fblocks)
target_include_directories(SWBCSupport PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR})
# TODO(compnerd) wire this up with `find_package`
target_link_libraries(SWBCSupport PRIVATE
  $<$<NOT:$<PLATFORM_ID:Darwin>>:BlocksRuntime>)
