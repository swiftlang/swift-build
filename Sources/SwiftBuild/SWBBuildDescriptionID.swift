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

/// Opaque token used to uniquely identify a build description.
public struct SWBBuildDescriptionID: Hashable, Sendable {
    public let rawValue: String

    public init(_ value: String) {
        self.rawValue = value
    }

    init(_ buildDescriptionID: BuildDescriptionID) {
        self.rawValue = buildDescriptionID.rawValue
    }
}

extension BuildDescriptionID {
    init(_ buildDescriptionID: SWBBuildDescriptionID) {
        self.init(buildDescriptionID.rawValue)
    }
}
