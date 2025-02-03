#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

add_library(SWBProjectModel
  IDE/IDEPIFGenerating.swift
  IDE/IDEPIFGUID.swift
  IDE/IDEPIFObject.swift
  IDE/IDEPIFObjectInfo.swift
  IDE/IDEPIFSerializer.swift
  IDE/IDESwiftPackageExtensions.swift
  PIFGenerationModel.swift)
set_target_properties(SWBProjectModel PROPERTIES
  Swift_LANGUAGE_VERSION 6)
target_link_libraries(SWBProjectModel PUBLIC
  SWBProtocol)
