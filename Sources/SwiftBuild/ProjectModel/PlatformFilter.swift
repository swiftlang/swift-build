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
    public struct PlatformFilter: Hashable, Sendable, Comparable {
        public var platform: String
        public var exclude: Bool?
        public var environment: String

        public init(platform: String, exclude: Bool? = nil, environment: String = "") {
            self.platform = platform
            self.exclude = exclude
            self.environment = environment
        }

        public static func < (lhs: ProjectModel.PlatformFilter, rhs: ProjectModel.PlatformFilter) -> Bool {
            return (lhs.platform, lhs.environment) < (rhs.platform, rhs.environment)
        }
    }
}

extension ProjectModel.PlatformFilter: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.platform = try container.decode(String.self, forKey: .platform)
        self.exclude = try container.decodeIfPresent(Bool.self, forKey: .exclude) ?? false
        self.environment = try container.decodeIfPresent(String.self, forKey: .environment) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.platform, forKey: .platform)
        if let exclude {
            try container.encode(exclude ? "true" : "false", forKey: .exclude)
        }
        if !self.environment.isEmpty {
            try container.encode(self.environment, forKey: .environment)
        }
    }

    enum CodingKeys: String, CodingKey {
        case platform
        case exclude
        case environment
    }
}
