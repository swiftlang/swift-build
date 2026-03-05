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

public struct SWBConfiguredTargetIdentifier: Hashable, Sendable {
    public var rawGUID: String
    public var targetGUID: SWBTargetGUID

    public init(rawGUID: String, targetGUID: SWBTargetGUID) {
        self.rawGUID = rawGUID
        self.targetGUID = targetGUID
    }

    init(configuredTargetIdentifier: ConfiguredTargetIdentifier) {
        self.init(rawGUID: configuredTargetIdentifier.rawGUID, targetGUID: SWBTargetGUID(configuredTargetIdentifier.targetGUID))
    }
}

extension ConfiguredTargetIdentifier {
    init(_ identifier: SWBConfiguredTargetIdentifier) {
        self.init(rawGUID: identifier.rawGUID, targetGUID: TargetGUID(rawValue: identifier.targetGUID.rawValue))
    }
}
