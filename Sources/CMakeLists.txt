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

  list(TRANSFORM BundleXCSpecs_FILES PREPEND "${CMAKE_CURRENT_SOURCE_DIR}/")
  add_custom_command(TARGET ${BundleXCSpecs_MODULE} POST_BUILD
    COMMAND
      ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/share/pm/SwiftBuild_${BundleXCSpecs_MODULE}.resources"
    COMMAND
      ${CMAKE_COMMAND} -E copy_if_different ${BundleXCSpecs_FILES} "${CMAKE_BINARY_DIR}/share/pm/SwiftBuild_${BundleXCSpecs_MODULE}.resources/")

  file(TO_NATIVE_PATH "${CMAKE_BINARY_DIR}/share/pm/SwiftBuild_${BundleXCSpecs_MODULE}.resources" _SWIFT_BUILD_RESOURCE_BUNDLE_BUILD_PATH)
  file(CONFIGURE
    OUTPUT "${CMAKE_BINARY_DIR}/resource_accessors/SwiftBuild_${BundleXCSpecs_MODULE}_resource_bundle_accessor.swift"
    CONTENT [[
    import Foundation
    extension Foundation.Bundle {
      static let module: Bundle = {
        let mainPath = Bundle.main.bundleURL.appendingPathComponent("SwiftBuild_@BundleXCSpecs_MODULE@.resources").path
        let buildPath = #"@_SWIFT_BUILD_RESOURCE_BUNDLE_BUILD_PATH@"#
        let preferredBundle = Bundle(path: mainPath)
        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
          Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }
        return bundle
      }()
    }
    ]]
    ESCAPE_QUOTES @ONLY NEWLINE_STYLE LF)

  target_sources("${BundleXCSpecs_MODULE}" PRIVATE
    "${CMAKE_BINARY_DIR}/resource_accessors/SwiftBuild_${BundleXCSpecs_MODULE}_resource_bundle_accessor.swift")

  install(DIRECTORY
    "${CMAKE_BINARY_DIR}/share/pm/SwiftBuild_${BundleXCSpecs_MODULE}.resources/"
    DESTINATION share/pm/SwiftBuild_${BundleXCSpecs_MODULE}.resources/)
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
