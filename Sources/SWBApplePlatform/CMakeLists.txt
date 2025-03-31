#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

file(TO_NATIVE_PATH "${CMAKE_CURRENT_BINARY_DIR}"
  _SWBApplePlatform_NATIVE_CMAKE_CURRENT_BINARY_DIR)
file(CONFIGURE
  OUTPUT resource_bundle_accessor.swift
  CONTENT [[
  import Foundation
  extension Foundation.Bundle {
    static let module: Bundle = {
      let mainPath = Bundle.main.bundleURL.appendingPathComponent("SwiftBuild_SWBApplePlatform.resources").path
      let buildPath = #"@_SWBApplePlatform_NATIVE_CMAKE_CURRENT_BINARY_DIR@\SwiftBuild_SWBApplePlatform.resources"#
      let preferredBundle = Bundle(path: mainPath)
      guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
        Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
      }
      return bundle
    }()
  }
  ]]
  ESCAPE_QUOTES @ONLY NEWLINE_STYLE LF)

add_library(SWBApplePlatform STATIC
  AppIntentsMetadataCompiler.swift
  AppIntentsMetadataTaskProducer.swift
  AppIntentsSSUTrainingCompiler.swift
  AssetCatalogCompiler.swift
  CopyTiffFile.swift
  CoreDataCompiler.swift
  CoreMLCompiler.swift
  DittoTool.swift
  ExtensionPointsCompiler.swift
  IIGCompiler.swift
  InstrumentsPackageBuilderSpec.swift
  IntentsCompiler.swift
  InterfaceBuilderCompiler.swift
  InterfaceBuilderShared.swift
  MetalCompiler.swift
  MiGCompiler.swift
  OpenCLCompiler.swift
  RealityAssetsCompilerSpec.swift
  ReferenceObjectCompiler.swift
  ResMergerLinkerSpec.swift
  SceneKitToolSpec.swift
  StoryboardLinker.swift
  XCStringsCompiler.swift
  ActoolInputFileGroupingStrategy.swift
  AssetCatalogCompilerOutputParser.swift
  CMakeLists.txt
  DevelopmentAssetsTaskProducer.swift
  ImageScaleFactorsInputFileGroupingStrategy.swift
  InterfaceBuilderCompilerOutputParser.swift
  LocalizationInputFileGroupingStrategy.swift
  MacCatalystInfoExtension.swift
  Plugin.swift
  RealityAssetsTaskProducer.swift
  StringCatalogCompilerOutputParser.swift
  StubBinaryTaskProducer.swift
  XCStringsInputFileGroupingStrategy.swift)
set_target_properties(SWBApplePlatform PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_link_libraries(SWBApplePlatform PUBLIC
  SWBCore
  SWBMacro
  SWBUtil
  SWBProtocol
  SWBTaskConstruction)
target_sources(SWBApplePlatform PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}/resource_bundle_accessor.swift")
