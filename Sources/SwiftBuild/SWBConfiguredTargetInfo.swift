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

public struct SWBConfiguredTargetInfo {
    /// The GUID of this configured target
    public let identifier: SWBConfiguredTargetIdentifier

    /// A name of the target that may be displayed to the user
    public let name: String

    /// The configured targets that this target depends on
    public let dependencies: Set<SWBConfiguredTargetIdentifier>

    /// The path of the toolchain that should be used to build this target.
    ///
    /// `nil` if the toolchain for this target could not be determined due to an error.
    public let toolchain: AbsolutePath?

    public init(identifier: SWBConfiguredTargetIdentifier, name: String, dependencies: Set<SWBConfiguredTargetIdentifier>, toolchain: AbsolutePath?) {
        self.identifier = identifier
        self.name = name
        self.dependencies = dependencies
        self.toolchain = toolchain
    }

    init(_ configuredTargetInfo: BuildDescriptionConfiguredTargetsResponse.ConfiguredTargetInfo) {
        self.init(
            identifier: SWBConfiguredTargetIdentifier(configuredTargetIdentifier: configuredTargetInfo.identifier),
            name: configuredTargetInfo.name,
            dependencies: Set(configuredTargetInfo.dependencies.map { SWBConfiguredTargetIdentifier(configuredTargetIdentifier: $0) }),
            toolchain: AbsolutePath(configuredTargetInfo.toolchain)
        )
    }
}
