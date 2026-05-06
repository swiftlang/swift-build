#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_executable(swbuild
  SWBuildMain.swift)
set_target_properties(swbuild PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_compile_options(swbuild PRIVATE
  -parse-as-library)
target_link_libraries(swbuild PRIVATE
  SwiftBuild)

install(TARGETS swbuild)
if(MSVC)
  install(FILES $<TARGET_FILE_DIR:swbuild>/$<TARGET_FILE_BASE_NAME:swbuild>.pdb
    DESTINATION bin
    OPTIONAL)
endif()
