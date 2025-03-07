#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

include(CMakeParseArguments)
function(SwiftBuild_Bundle)
  set(Options)
  set(OneValueArguments MODULE)
  set(MultiValueArguments FILES)
  cmake_parse_arguments(PARSE_ARGV 0 BundleXCSpecs
    "${Options}" "${OneValueArguments}" "${MultiValueArguments}")

  add_custom_command(TARGET ${BundleXCSpecs_MODULE} POST_BUILD
    COMMAND
      ${CMAKE_COMMAND} -E make_directory "$<TARGET_PROPERTY:${BundleXCSpecs_MODULE},LOCATION>/SwiftBuild_${BundleXCSpecs_MODULE}.resources"
    COMMAND
      ${CMAKE_COMMAND} -E copy_if_different ${BundleXCSpecs_FILES} "$<TARGET_PROPERTY:${BundleXCSpecs_MODULE},LOCATION>/SwiftBuild_${BundleXCSpecs_MODULE}.resources/")
endfunction()

add_subdirectory(SWBCSupport)
add_subdirectory(SWBCLibc)
add_subdirectory(SWBLibc)
add_subdirectory(SWBUtil)
add_subdirectory(SWBMacro)
add_subdirectory(SWBProtocol)
add_subdirectory(SWBServiceCore)
add_subdirectory(SWBCAS)
add_subdirectory(SWBLLBuild)
add_subdirectory(SWBCore)
add_subdirectory(SWBTaskConstruction)
add_subdirectory(SWBAndroidPlatform)
add_subdirectory(SWBApplePlatform)
add_subdirectory(SWBGenericUnixPlatform)
add_subdirectory(SWBQNXPlatform)
add_subdirectory(SWBUniversalPlatform)
add_subdirectory(SWBWebAssemblyPlatform)
add_subdirectory(SWBWindowsPlatform)
add_subdirectory(SWBTaskExecution)
add_subdirectory(SWBBuildSystem)
add_subdirectory(SWBBuildService)
add_subdirectory(SWBProjectModel)
add_subdirectory(SwiftBuild)

add_subdirectory(swbuild)
add_subdirectory(SWBBuildServiceBundle)
