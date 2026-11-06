#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_executable(swblauncher
  main.swift)
set_target_properties(swblauncher PROPERTIES
  Swift_LANGUAGE_VERSION 6)
# The launcher exists to diagnose missing DLL dependencies, so it must not have
# any non-system DLL dependencies of its own.
target_compile_options(swblauncher PRIVATE
  "$<$<COMPILE_LANGUAGE:Swift>:-static>"
  "$<$<COMPILE_LANGUAGE:Swift>:-static-stdlib>")
target_link_options(swblauncher PRIVATE
  -static-stdlib)

install(TARGETS swblauncher)
