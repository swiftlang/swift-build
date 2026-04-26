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
    public struct BuildConfigurationFilter: Hashable, Sendable, Comparable {
        public var buildConfiguration: String

        public init(buildConfiguration: String) {
            self.buildConfiguration = buildConfiguration
        }

        public static func < (lhs: ProjectModel.BuildConfigurationFilter, rhs: ProjectModel.BuildConfigurationFilter) -> Bool {
            return lhs.buildConfiguration < rhs.buildConfiguration
        }
    }
}

extension ProjectModel.BuildConfigurationFilter: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.buildConfiguration = try container.decode(String.self, forKey: .buildConfiguration)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.buildConfiguration, forKey: .buildConfiguration)
    }

    enum CodingKeys: String, CodingKey {
        case buildConfiguration
    }
}
