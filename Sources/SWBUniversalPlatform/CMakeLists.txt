#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBUniversalPlatform
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
SwiftBuild_Bundle(MODULE SWBUniversalPlatform FILES
  Specs/BuiltInBuildRules.xcbuildrules
  Specs/BuiltInCompilers.xcspec
  Specs/BuiltInFileTypes.xcspec
  Specs/Clang.xcspec
  Specs/ClangModuleVerifierInputGenerator.xcspec
  Specs/ClangStatCache.xcspec
  Specs/ClangSymbolExtractor.xcspec
  Specs/ClangVerifier.xcspec
  Specs/CodeSign.xcspec
  Specs/CopyPlistFile.xcspec
  Specs/CopyStringsFile.xcspec
  Specs/Cpp.xcspec
  Specs/DefaultCompiler.xcspec
  Specs/Documentation.xcspec
  Specs/Ld.xcspec
  Specs/Lex.xcspec
  Specs/Libtool.xcspec
  Specs/ObjectLibraryAssembler.xcspec
  Specs/PackageTypes.xcspec
  Specs/PBXCp.xcspec
  Specs/ProductTypes.xcspec
  Specs/ProductTypeValidationTool.xcspec
  Specs/StandardFileTypes.xcspec
  Specs/StripSymbols.xcspec
  Specs/swift-stdlib-tool.xcspec
  Specs/Swift.xcspec
  Specs/SwiftBuildSettings.xcspec
  Specs/TAPI.xcspec
  Specs/TestEntryPointGenerator.xcspec
  Specs/Unifdef.xcspec
  Specs/Yacc.xcspec)
target_link_libraries(SWBUniversalPlatform PUBLIC
  SWBCore
  SWBMacro
  SWBUtil
  SWBTaskConstruction
  SWBTaskExecution
  ArgumentParser)

set_target_properties(SWBUniversalPlatform PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_Swift_MODULE_DIRECTORY})

set_property(GLOBAL APPEND PROPERTY SWIFTBUILD_EXPORTS SWBUniversalPlatform)

install(TARGETS SWBUniversalPlatform
    ARCHIVE DESTINATION "${SwiftBuild_INSTALL_LIBDIR}")
