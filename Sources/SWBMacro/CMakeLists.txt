#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBMacro
  MacroCondition.swift
  MacroConditionExpression.swift
  MacroConditionParameter.swift
  MacroConditionSet.swift
  MacroConfigFileDiagnostic.swift
  MacroConfigFileParser.swift
  MacroDeclaration.swift
  MacroEvaluationProgram.swift
  MacroEvaluationScope.swift
  MacroExpression.swift
  MacroExpressionDiagnostic.swift
  MacroExpressionParsing.swift
  MacroNamespace.swift
  MacroType.swift
  MacroValueAssignmentTable.swift)
set_target_properties(SWBMacro PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_link_libraries(SWBMacro PUBLIC
  SWBUtil
  SwiftDriver
  TSCBasic)

target_include_directories(SWBMacro PUBLIC
  ${CMAKE_CURRENT_BINARY_DIR})
