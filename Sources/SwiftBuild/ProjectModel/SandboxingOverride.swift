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
    public enum SandboxingOverride: String, Sendable, Codable {
        case forceDisabled
        case forceEnabled
        case basedOnBuildSetting

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = try .init(rawValue: container.decode(String.self))!
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}
