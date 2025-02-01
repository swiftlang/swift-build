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
    /// A build file, representing the membership of either a file or target product reference in a build phase.
    public struct BuildFile: Sendable, Hashable, Identifiable {
        public enum Ref: Sendable, Hashable {
            case reference(id: GUID)
            case targetProduct(id: GUID)
        }
        public enum HeaderVisibility: String, Sendable, Hashable {
            case `public` = "public"
            case `private` = "private"
        }
        public enum GeneratedCodeVisibility: String, Sendable, Hashable, Codable {
            case `public`
            case `private`
            case project
            case noCodegen = "no_codegen"
        }
        public enum ResourceRule: String, Sendable, Hashable, Codable {
            case process
            case copy
            case embedInCode
        }

        public let id: GUID
        public var ref: Ref
        public var headerVisibility: HeaderVisibility? = nil
        public var generatedCodeVisibility: GeneratedCodeVisibility? = nil
        public var platformFilters: Set<PlatformFilter> = []
        public var codeSignOnCopy: Bool = false
        public var removeHeadersOnCopy: Bool = false
        public var resourceRule: ResourceRule? = nil

        public init(
            id: GUID,
            ref: Ref,
            headerVisibility: HeaderVisibility? = nil,
            generatedCodeVisibility: GeneratedCodeVisibility? = nil,
            platformFilters: Set<PlatformFilter> = [],
            codeSignOnCopy: Bool = false,
            removeHeadersOnCopy: Bool = false,
            resourceRule: ResourceRule? = nil
        ) {
            self.id = id
            self.ref = ref
            self.headerVisibility = headerVisibility
            self.generatedCodeVisibility = generatedCodeVisibility
            self.platformFilters = platformFilters
            self.codeSignOnCopy = codeSignOnCopy
            self.removeHeadersOnCopy = removeHeadersOnCopy
        }

        public init(
            id: GUID,
            fileRef: FileReference,
            headerVisibility: HeaderVisibility? = nil,
            generatedCodeVisibility: GeneratedCodeVisibility? = nil,
            platformFilters: Set<PlatformFilter> = [],
            codeSignOnCopy: Bool = false,
            removeHeadersOnCopy: Bool = false,
            resourceRule: ResourceRule? = nil
        ) {
            self.init(id: id, ref: .reference(id: fileRef.id), headerVisibility: headerVisibility, generatedCodeVisibility: generatedCodeVisibility, platformFilters: platformFilters, codeSignOnCopy: codeSignOnCopy, removeHeadersOnCopy: removeHeadersOnCopy, resourceRule: resourceRule)
        }
    }
}


extension ProjectModel.BuildFile: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        self.platformFilters = try container.decode(Set<ProjectModel.PlatformFilter>.self, forKey: .platformFilters)

        if let refId = try container.decodeIfPresent(ProjectModel.GUID.self, forKey: .fileReference) {
            self.ref = .reference(id: refId)
        } else if let refId = try container.decodeIfPresent(ProjectModel.GUID.self, forKey: .targetReference) {
            self.ref = .targetProduct(id: refId)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .fileReference, in: container, debugDescription: "Missing file or target reference")
        }

    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.platformFilters, forKey: .platformFilters)

        switch self.ref {
        case .reference(id: let refId):
            try container.encode(refId, forKey: .fileReference)
            try container.encodeIfPresent(self.headerVisibility?.rawValue, forKey: .headerVisibility)
            try container.encode(self.codeSignOnCopy ? "true" : "false", forKey: .codeSignOnCopy)
            try container.encode(self.removeHeadersOnCopy ? "true" : "false", forKey: .removeHeadersOnCopy)
            try container.encodeIfPresent(self.generatedCodeVisibility, forKey: .intentsCodegenVisibility)
            try container.encodeIfPresent(self.resourceRule, forKey: .resourceRule)

        case .targetProduct(id: let refId):
            try container.encode(refId, forKey: .targetReference)
        }
    }

    enum CodingKeys: String, CodingKey {
        case guid
        case fileReference
        case headerVisibility
        case platformFilters
        case codeSignOnCopy
        case removeHeadersOnCopy
        case intentsCodegenVisibility
        case resourceRule
        case targetReference
    }
}


