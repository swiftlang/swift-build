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
    public struct ImpartedBuildProperties: Sendable, Hashable {
        public let settings: BuildSettings

        public init(settings: BuildSettings) {
            self.settings = settings
        }
    }
}

extension ProjectModel.ImpartedBuildProperties: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.settings = try container.decode(ProjectModel.BuildSettings.self, forKey: .buildSettings)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(settings, forKey: .buildSettings)
    }

    enum CodingKeys: String, CodingKey {
        case buildSettings
    }
}
