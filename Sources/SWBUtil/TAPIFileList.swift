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

public import struct Foundation.Data
public import class Foundation.JSONEncoder

public struct TAPIFileList: Sendable {
    public enum FormatVersion: UInt, Comparable, CaseIterable, Sendable {
        case v1 = 1
        case v2 = 2
        case v3 = 3
    }

    public enum HeaderVisibility: String, Comparable, Sendable {
        case `public`
        case `private`
        case `project`
    }

    public let version: FormatVersion
    public var headers: [(headerVisibility: HeaderVisibility, path: String)] {
        return headerInfos.map { ($0.visibility, $0.path.str) }
    }
    public let headerInfos: [HeaderInfo]

    public struct HeaderInfo: Encodable, Sendable {
        public let visibility: HeaderVisibility
        public let path: Path
        public let language: String?
        public let isSwiftCompatibilityHeader: Bool?

        public init(visibility: TAPIFileList.HeaderVisibility, path: Path, language: String?, isSwiftCompatibilityHeader: Bool?) {
            self.visibility = visibility
            self.path = path
            self.language = language
            self.isSwiftCompatibilityHeader = isSwiftCompatibilityHeader
        }

        enum CodingKeys: String, CodingKey {
            case visibility = "type"
            case path
            case language
            case isSwiftCompatibilityHeader = "swiftCompatibilityHeader"
        }

        public func encode(to encoder: any Swift.Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(visibility.rawValue, forKey: .visibility)
            try container.encode(path.str, forKey: .path)
            try container.encodeIfPresent(language, forKey: .language)
            if isSwiftCompatibilityHeader == true {
                try container.encode(true, forKey: .isSwiftCompatibilityHeader)
            }
        }
    }

    public init(version: FormatVersion, headers: [(headerVisibility: HeaderVisibility, path: String)]) throws {
        try self.init(version: version, headerInfos: headers.map {
            HeaderInfo(visibility: $0.headerVisibility, path: Path($0.path), language: nil, isSwiftCompatibilityHeader: nil)
        })
    }

    public init(version: FormatVersion, headerInfos: [HeaderInfo]) throws {
        self.version = version
        self.headerInfos = headerInfos

        // Validate that there are no duplicates, or project-level headers in the v1 format
        // Note that order is important for file lists, and must be preserved. We only sort
        // here in order to guarantee that any errors are displayed consistently given the same input.
        for (_, pair) in Dictionary(grouping: headerInfos, by: { $0.path.str }).sorted(byKey: <) {
            assert(!pair.isEmpty) // impossible
            let visibilities = Set(pair.map { $0.visibility })
            guard let headerVisibility = visibilities.only else {
                throw TAPIFileListError.duplicateEntry(path: pair[0].path.str, visibilities: visibilities)
            }
            if version < .v2 && headerVisibility == .project {
                throw TAPIFileListError.unsupportedHeaderVisibility
            }
            if version < .v3 && pair.contains(where: { $0.language != nil || $0.isSwiftCompatibilityHeader != nil }) {
                throw TAPIFileListError.unsupportedHeaderVisibility
            }
        }
    }
}

extension TAPIFileList: Encodable {
    enum CodingKeys: String, CodingKey {
        case version
        case headers
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(String(version.rawValue), forKey: .version) // required to be a string, not integer
        try container.encode(headerInfos, forKey: .headers)
    }
}

extension TAPIFileList {
    /// Returns the `TAPIFileList` object in its canonical on-disk representation.
    public func asBytes() throws -> Data {
        return try JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).encode(self)
    }
}

extension TAPIFileList.FormatVersion {
    public var requiredTAPIVersion: FuzzyVersion {
        switch self {
        case .v1:
            return try! FuzzyVersion("0")
        case .v2:
            return try! FuzzyVersion("1100.*.2.1")
        case .v3:
            return try! FuzzyVersion("1400.0.6.1")
        }
    }

    public static func latestSupported(forTAPIVersion tapiVersion: Version) -> TAPIFileList.FormatVersion {
        if tapiVersion >= v3.requiredTAPIVersion {
            return .v3
        }
        if tapiVersion >= v2.requiredTAPIVersion {
            return .v2
        }
        return .v1
    }
}

public enum TAPIFileListError: Error, Equatable {
    case duplicateEntry(path: String, visibilities: Set<TAPIFileList.HeaderVisibility>)
    case unsupportedHeaderVisibility
    case unsupportedLanguageOrSwiftCompatibilityInfo
}

extension TAPIFileListError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .duplicateEntry(let path, let visibilities):
            return "Ambiguous visibility for TAPI file list header at '\(path)': \(visibilities.sorted().map { $0.rawValue }.joined(separator: ", "))"
        case .unsupportedHeaderVisibility:
            return "Project headers are not supported in this version of TAPI"
        case .unsupportedLanguageOrSwiftCompatibilityInfo:
            return "Header source language and Swift compatibility header information is not supported in this version of TAPI"
        }
    }
}

// rdar://48096527
extension RawRepresentable where Self.RawValue: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
