#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

file(TO_NATIVE_PATH "${CMAKE_CURRENT_BINARY_DIR}"
  _SWBUniversalPlatform_NATIVE_CMAKE_CURRENT_BINARY_DIR)
file(CONFIGURE
  OUTPUT resource_bundle_accessor.swift
  CONTENT [[
  import Foundation
  extension Foundation.Bundle {
    static let module: Bundle = {
      let mainPath = Bundle.main.bundleURL.appendingPathComponent("SwiftBuild_SWBUniversalPlatform.resources").path
      let buildPath = #"@_SWBUniversalPlatform_NATIVE_CMAKE_CURRENT_BINARY_DIR@\SwiftBuild_SWBUniversalPlatform.resources"#
      let preferredBundle = Bundle(path: mainPath)
      guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
        Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
      }
      return bundle
    }()
  }
  ]]
  ESCAPE_QUOTES @ONLY NEWLINE_STYLE LF)

add_library(SWBUniversalPlatform STATIC
  CopyPlistFile.swift
  CopyStringsFile.swift
  CppTool.swift
  DiffTool.swift
  LexCompiler.swift
  TestEntryPointGenerationTaskAction.swift
  TestEntryPointGenerationTool.swift
  TestEntryPointTaskProducer.swift
  YaccCompiler.swift
  Plugin.swift)
target_link_libraries(SWBUniversalPlatform PUBLIC
  SWBCore
  SWBMacro
  SWBUtil
  SWBTaskConstruction
  SWBTaskExecution
  ArgumentParser)
target_sources(SWBUniversalPlatform PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}/resource_bundle_accessor.swift")
