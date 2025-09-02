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

import SWBProtocol

public struct SWBConfiguredTargetGUID: RawRepresentable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ guid: ConfiguredTargetGUID) {
        self.init(rawValue: guid.rawValue)
    }
}

extension ConfiguredTargetGUID {
    init(_ guid: SWBConfiguredTargetGUID) {
        self.init(guid.rawValue)
    }
}
