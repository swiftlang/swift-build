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

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

public struct IOPipe: Sendable {
    public let readEnd: FileDescriptor
    public let writeEnd: FileDescriptor

    public init() throws {
        let (readEnd, writeEnd) = try FileDescriptor.pipe()
        self.readEnd = readEnd
        self.writeEnd = writeEnd
    }
}

extension FileDescriptor {
    public func setBinaryMode() throws {
        #if os(Windows)
        if _setmode(rawValue, _O_BINARY) == -1 {
            throw Errno(rawValue: errno)
        }
        #endif
    }
}
