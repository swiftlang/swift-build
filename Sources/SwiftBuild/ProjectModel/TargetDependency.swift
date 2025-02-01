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
    /// Represents a dependency on another target (identified by its PIF ID).
    public struct TargetDependency: Sendable, Hashable {
        /// Identifier of depended-upon target.
        public let targetId: GUID
        /// The platform filters for this target dependency.
        public let platformFilters: Set<PlatformFilter>

        public init(targetId: ProjectModel.GUID, platformFilters: Set<ProjectModel.PlatformFilter> = []) {
            self.targetId = targetId
            self.platformFilters = platformFilters
        }
    }
}

extension ProjectModel.TargetDependency: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.targetId = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        self.platformFilters = try container.decode(Set<ProjectModel.PlatformFilter>.self, forKey: .platformFilters)
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.targetId, forKey: .guid)
        try container.encode(self.platformFilters, forKey: .platformFilters)
    }

    enum CodingKeys: String, CodingKey {
        case guid
        case platformFilters
    }
}

