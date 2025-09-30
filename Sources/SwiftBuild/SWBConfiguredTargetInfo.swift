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
import SWBUtil

public struct SWBArtifactInfo: Sendable {
    public enum Kind: Sendable {
        case executable
        case staticLibrary
        case dynamicLibrary
        case framework
    }
    public var kind: Kind
    public var path: String

    init(_ info: ArtifactInfo) {
        switch info.kind {
        case .executable:
            self.kind = .executable
        case .staticLibrary:
            self.kind = .staticLibrary
        case .dynamicLibrary:
            self.kind = .dynamicLibrary
        case .framework:
            self.kind = .framework
        }
        self.path = info.path.str
    }
}

public struct SWBConfiguredTargetInfo: Sendable {
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

    public let artifactInfo: SWBArtifactInfo?

    public init(identifier: SWBConfiguredTargetIdentifier, name: String, dependencies: Set<SWBConfiguredTargetIdentifier>, toolchain: AbsolutePath?, artifactInfo: SWBArtifactInfo?) {
        self.identifier = identifier
        self.name = name
        self.dependencies = dependencies
        self.toolchain = toolchain
        self.artifactInfo = artifactInfo
    }

    init(_ configuredTargetInfo: BuildDescriptionConfiguredTargetsResponse.ConfiguredTargetInfo) {
        self.init(
            identifier: SWBConfiguredTargetIdentifier(configuredTargetIdentifier: configuredTargetInfo.identifier),
            name: configuredTargetInfo.name,
            dependencies: Set(configuredTargetInfo.dependencies.map { SWBConfiguredTargetIdentifier(configuredTargetIdentifier: $0) }),
            toolchain: AbsolutePath(configuredTargetInfo.toolchain),
            artifactInfo: configuredTargetInfo.artifactInfo.map { SWBArtifactInfo($0) }
        )
    }
}
