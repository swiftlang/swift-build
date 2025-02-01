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

public import SWBUtil

public enum BuildAction: String, Serializable, Codable, CaseIterable, Comparable, Sendable {
    case analyze = "analyze" // used by legacy target-based builds using xcodebuild
    case archive = "archive" // used by legacy target-based builds using xcodebuild
    case clean = "clean"
    case build = "build"
    case exportLoc = "exportloc"
    case indexBuild = "indexbuild"
    case install = "install"
    case installAPI = "installapi"
    case installHeaders = "installhdrs"
    case installLoc = "installloc"
    case installSource = "installsrc"
    case docBuild = "docbuild"

    public static let actions = BuildAction.allCases

    public init?(actionName: String) {
        self.init(rawValue: actionName)
    }

    public var actionName: String {
        return self.rawValue
    }

    public var isInstallAction: Bool {
        switch self {
        case .install, .installAPI, .installHeaders, .installLoc, .installSource, .archive:
            return true
        default:
            return false
        }
    }

    public var buildComponents: [String] {
        switch self {
        case .clean:
            return ["clean"]
        case .build, .indexBuild:
            return ["headers", "build"]
        case .exportLoc:
            return ["headers", "exportLoc"]
        case .install:
            return ["headers", "build"]
        case .installAPI:
            return ["headers", "api"]
        case .installHeaders:
            return ["headers"]
        case .installLoc:
            return ["installLoc"]
        case .installSource:
            return ["source"]
        case .analyze:
            return ["headers", "build"]
        case .archive:
            return ["headers", "build"]
        case .docBuild:
            return ["headers", "build", "documentation"]
        }
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serialize(rawValue)
    }

    public init(from deserializer: any Deserializer) throws {
        let rawValue = try deserializer.deserialize() as String
        guard let buildAction = Self(rawValue: rawValue) else {
            throw DeserializerError.unexpectedValue(rawValue)
        }
        self = buildAction
    }
}

/// Opaque token used to uniquely identify a build description.
public struct BuildDescriptionID: Hashable, Sendable {
    public let rawValue: String

    public init(_ value: String) {
        self.rawValue = value
    }
}
