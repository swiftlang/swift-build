//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

class ApplicationWrapperFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXApplicationWrapperFileType"
}

class CFBundleWrapperFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXCFBundleWrapperFileType"
}

class FrameworkWrapperFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXFrameworkWrapperFileType"
}

class HTMLFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXHTMLFileType"
}

class MachOFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXMachOFileType"
}

class PlistFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXPlistFileType"
}

class PlugInKitPluginWrapperFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXPlugInKitPluginWrapperFileType"
}

class SpotlightImporternWrapperFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXSpotlightImporternWrapperFileType"
}

class StaticFrameworkWrapperFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "XCStaticFrameworkWrapperFileType"
}

class XPCServiceWrapperFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXXPCServiceWrapperFileType"
}

class XCFrameworkWrapperFileTypeSpec : FileTypeSpec, SpecClassType {
    static let className = "PBXXCFrameworkWrapperFileType"
}
