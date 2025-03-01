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

import Foundation
import SWBProtocol

extension ProjectModel {
    // MARK: - References

    /// Base enum for all items in the group hierarchy.
    public enum Reference: Sendable, Hashable {
        /// Determines the base path for a reference's relative path.
        public enum RefPathBase: String, Sendable, Hashable, Codable {
            /// Indicates that the path is relative to the source root (i.e. the "project directory").
            case projectDir = "SOURCE_ROOT"

            /// Indicates that the path is relative to the path of the parent group.
            case groupDir = "<group>"

            /// Indicates that the path is relative to the effective build directory (which varies depending on active scheme, active run destination, or even an overridden build setting.
            case buildDir = "BUILT_PRODUCTS_DIR"

            /// Indicates that the path is an absolute path.
            case absolute = "<absolute>"

            /// The string form, suitable for use in the PIF representation.
            public var asString: String { return rawValue }
        }

        case file(FileReference)
        case group(Group)

        public var id: GUID {
            switch self {
            case let .file(fref): return fref.id
            case let .group(group): return group.common.id
            }
        }
    }

    public struct ReferenceCommon: Sendable, Hashable {
        public let id: GUID

        /// Relative path of the reference.  It is usually a literal, but may in fact contain build settings.
        public var path: String

        /// Determines the base path for the reference's relative path.
        public var pathBase: Reference.RefPathBase

        /// Name of the reference.
        public var name: String

        init(id: GUID, path: String, pathBase: Reference.RefPathBase, name: String) {
            self.id = id
            self.path = path
            self.pathBase = pathBase
            self.name = name
        }
    }

    /// A reference to a file system entity (a file, folder, etc).
    public struct FileReference: Common, Sendable, Hashable {
        public var common: ReferenceCommon
        public var fileType: String

        public init(id: GUID, path: String, pathBase: Reference.RefPathBase = .groupDir, name: String? = nil, fileType: String? = nil) {
            self.common = ReferenceCommon(id: id, path: path, pathBase: pathBase, name: name ?? path)
            self.fileType = fileType ?? Self.fileTypeIdentifier(for: path)
        }
    }

    /// A group that can contain References (FileReferences and other Groups).  The resolved path of a group is used as the base path for any child references whose source tree type is GroupRelative.
    public struct Group: Common, Sendable, Hashable {
        public var common: ReferenceCommon
        public var subitems: [Reference] = []

        public init(id: GUID, path: String, pathBase: Reference.RefPathBase = .groupDir, name: String? = nil, subitems: [Reference] = []) {
            self.common = ReferenceCommon(id: id, path: path, pathBase: pathBase, name: name ?? path)
            self.subitems = subitems
        }

        private var nextRefId: GUID {
            return "\(self.common.id.value)::REF_\(subitems.count)"
        }

        // MARK: - Reference subitems

        /// Creates and appends a new FileReference to the list of subitems.
        @discardableResult public mutating func addFileReference(_ create: CreateFn<FileReference>) -> FileReference {
            let fref = create(nextRefId)
            subitems.append(.file(fref))
            return fref
        }

        @discardableResult public mutating func addGroup(_ create: CreateFn<Group>) -> WritableKeyPath<Group, Group> {
            let group = create(nextRefId)
            subitems.append(.group(group))
            let tag = Tag<Group>(value: group.id)
            return \.[group: tag]
        }

        fileprivate subscript(group tag: Tag<Group>) -> Group {
            get {
                guard case let .group(t) = subitems.first(where: { $0.id == tag.value }) else { fatalError() }
                return t
            }
            set {
                guard let idx = subitems.firstIndex(where: { $0.id == tag.value }) else { fatalError() }
                subitems[idx] = .group(newValue)
            }
        }
    }


}


extension ProjectModel.Reference: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "file":
            self = .file(try .init(from: decoder))
        case "group":
            self = .group(try .init(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown value for key")
        }
    }
    
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case let .file(fref):
            try fref.encode(to: encoder)
        case let .group(group):
            try group.encode(to: encoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
    }
}

extension ProjectModel.FileReference: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        let pathBase = try container.decode(ProjectModel.Reference.RefPathBase.self, forKey: .sourceTree)
        let path = try container.decode(String.self, forKey: .path)
        let name = try container.decode(String.self, forKey: .name)
        self.common = .init(id: id, path: path, pathBase: pathBase, name: name)
        self.fileType = try container.decode(String.self, forKey: .fileType)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("file", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.pathBase, forKey: .sourceTree)
        try container.encode(self.path, forKey: .path)
        try container.encode(self.fileType, forKey: .fileType)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case guid
        case sourceTree
        case path
        case fileType
        case name
    }

    private static func fileTypeIdentifier(for path: String) -> String {
        // FIXME: We need real logic here.  <rdar://problem/33634352> [SwiftPM] When generating PIF, we need a standard way to determine the file type
        let pathExtension = (path as NSString).pathExtension as String
        switch pathExtension {
        case "a":
            return "archive.ar"
        case "s", "S":
            return "sourcecode.asm"
        case "c":
            return "sourcecode.c.c"
        case "cl":
            return "sourcecode.opencl"
        case "cpp", "cp", "cxx", "cc", "c++", "C", "tcc":
            return "sourcecode.cpp.cpp"
        case "d":
            return "sourcecode.dtrace"
        case "defs", "mig":
            return "sourcecode.mig"
        case "m":
            return "sourcecode.c.objc"
        case "mm", "M":
            return "sourcecode.cpp.objcpp"
        case "metal":
            return "sourcecode.metal"
        case "l", "lm", "lmm", "lpp", "lp", "lxx":
            return "sourcecode.lex"
        case "swift":
            return "sourcecode.swift"
        case "y", "ym", "ymm", "ypp", "yp", "yxx":
            return "sourcecode.yacc"


        // FIXME: This is probably now more important because of resources support.
        case "xcassets":
            return "folder.assetcatalog"
        case "xcstrings":
            return "text.json.xcstrings"
        case "storyboard":
            return "file.storyboard"
        case "xib":
            return "file.xib"

        case "xcframework":
            return "wrapper.xcframework"

        case "docc":
            return "folder.documentationcatalog"

        case "rkassets":
            return "folder.rkassets"

        default:
            return XCBuildFileType.all.first{ $0.fileTypes.contains(pathExtension) }?.fileTypeIdentifier ?? "file"
        }
    }

}

extension ProjectModel.Group: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        let pathBase = try container.decode(ProjectModel.Reference.RefPathBase.self, forKey: .sourceTree)
        let path = try container.decode(String.self, forKey: .path)
        let name = try container.decode(String.self, forKey: .name)
        self.common = .init(id: id, path: path, pathBase: pathBase, name: name)
        self.subitems = try container.decode([ProjectModel.Reference].self, forKey: .children)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("group", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.pathBase, forKey: .sourceTree)
        try container.encode(self.path, forKey: .path)
        try container.encode(self.name, forKey: .name)
        try container.encode(subitems, forKey: .children)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case guid
        case sourceTree
        case path
        case name
        case children
    }

}

