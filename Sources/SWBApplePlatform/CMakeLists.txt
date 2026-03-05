#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBApplePlatform
  AppIntentsMetadataCompiler.swift
  AppIntentsMetadataTaskProducer.swift
  AppIntentsSSUTrainingCompiler.swift
  AssetCatalogCompiler.swift
  CopyTiffFile.swift
  CoreDataCompiler.swift
  CoreMLCompiler.swift
  DittoTool.swift
  ExtensionPointExtractorTaskProducer.swift
  ExtensionPointsCompiler.swift
  EXUtil.swift
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
  PluginDCLT.swift
  RealityAssetsTaskProducer.swift
  RegisterExecutionPolicyException.swift
  StringCatalogCompilerOutputParser.swift
  StubBinaryTaskProducer.swift
  XCStringsInputFileGroupingStrategy.swift)
SwiftBuild_Bundle(MODULE SWBApplePlatform FILES
  Specs/AppIntentsMetadata.xcspec
  Specs/AppIntentsNLTraining.xcspec
  Specs/AppleFileTypes.xcspec
  Specs/AppShortcutStringsMetadata.xcspec
  Specs/AssetCatalogCompiler.xcspec
  Specs/CompileSkybox.xcspec
  Specs/CopyPNGFile.xcspec
  Specs/CopyTiffFile.xcspec
  Specs/CoreData.xcspec
  Specs/CoreML.xcspec
  Specs/DarwinPackageTypes.xcspec
  Specs/DarwinProductTypes.xcspec
  Specs/DriverKit.xcspec
  Specs/DTrace.xcspec
  Specs/Embedded-Device.xcspec
  Specs/Embedded-Shared.xcspec
  Specs/Embedded-Simulator.xcspec
  Specs/EmbeddedBinaryValidationUtility.xcspec
  Specs/EXUtil.xcspec
  Specs/GenerateAppPlaygroundAssetCatalog.xcspec
  Specs/GenerateTextureAtlas.xcspec
  Specs/IBCompiler.xcspec
  Specs/IBPostprocessor.xcspec
  Specs/IBStoryboardCompiler.xcspec
  Specs/IBStoryboardLinker.xcspec
  Specs/IBStoryboardPostprocessor.xcspec
  Specs/Iconutil.xcspec
  Specs/Iig.xcspec
  Specs/InfoPlistUtility.xcspec
  Specs/InstrumentsPackage.xcspec
  Specs/Intents.xcspec
  Specs/InterfaceBuilderFileTypes.xcspec
  Specs/iOSDevice.xcspec
  Specs/iOSShared.xcspec
  Specs/iOSSimulator.xcspec
  Specs/KernelExtension.xcspec
  Specs/Lipo.xcspec
  Specs/LSRegisterURL.xcspec
  Specs/macOSArchitectures.xcspec
  Specs/macOSCoreBuildSystem.xcspec
  Specs/macOSNativeBuildSystem.xcspec
  Specs/macOSPackageTypes.xcspec
  Specs/macOSProductTypes.xcspec
  Specs/MetalCompiler.xcspec
  Specs/MetalFileTypes.xcspec
  Specs/MetalLinker.xcspec
  Specs/MetalPackageTypes.xcspec
  Specs/MetalProductTypes.xcspec
  Specs/MiG.xcspec
  Specs/OpenCL.xcspec
  Specs/OSACompile.xcspec
  Specs/RCFileTypes.xcspec
  Specs/RealityAssets.xcspec
  Specs/ReferenceObject.xcspec
  Specs/ResMerger.xcspec
  Specs/Rez.xcspec
  Specs/SceneKitFileTypes.xcspec
  Specs/SceneKitTools.xcspec
  Specs/SpriteKitFileTypes.xcspec
  Specs/StripSymbolsDarwin.xcspec
  Specs/TiffUtil.xcspec
  Specs/tvOSDevice.xcspec
  Specs/tvOSShared.xcspec
  Specs/tvOSSimulator.xcspec
  Specs/WatchKit1ProductTypes.xcspec
  Specs/watchOSDevice.xcspec
  Specs/watchOSShared.xcspec
  Specs/watchOSSimulator.xcspec
  Specs/XCAppExtensionPoints.xcspec
  Specs/XCStrings.xcspec
  Specs/xrOSDevice.xcspec
  Specs/xrOSShared.xcspec
  Specs/xrOSSimulator.xcspec)
set_target_properties(SWBApplePlatform PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_link_libraries(SWBApplePlatform PUBLIC
  SWBCore
  SWBMacro
  SWBUtil
  SWBProtocol
  SWBTaskConstruction)

set_target_properties(SWBApplePlatform PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBApplePlatform)

install(TARGETS SWBApplePlatform
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
