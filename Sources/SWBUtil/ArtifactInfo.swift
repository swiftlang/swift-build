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

///. Describes high-level information about an artifact produced by a particular ConfiguredTarget, suitable for consumption by build tools like SwiftPM command plugins.
public struct ArtifactInfo: Equatable, Hashable, Sendable, SerializableCodable {
    public enum Kind: Equatable, Hashable, Sendable, SerializableCodable {
        case executable
        case staticLibrary
        case dynamicLibrary
        case framework
    }

    public let kind: Kind
    public let path: Path

    public init(kind: Kind, path: Path) {
        self.kind = kind
        self.path = path
    }
}
