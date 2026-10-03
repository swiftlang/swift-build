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
import Testing
import SWBLibc
import SWBUtil
import SWBTestSupport

#if canImport(System)
import System
#else
import SystemPackage
#endif

#if !os(Windows)
@Suite fileprivate struct FileDescriptorTests {
    private func isCloseOnExec(_ fd: FileDescriptor) throws -> Bool {
        let flags = fcntl(fd.rawValue, F_GETFD)
        if flags == -1 {
            throw Errno(rawValue: errno)
        }
        return (flags & FD_CLOEXEC) != 0
    }

    @Test func safePipe() throws {
        let (readEnd, writeEnd) = try FileDescriptor.safePipe()
        defer {
            try? readEnd.close()
            try? writeEnd.close()
        }
        #expect(try isCloseOnExec(readEnd))
        #expect(try isCloseOnExec(writeEnd))
    }

    @Test func safeDuplicate() throws {
        let (readEnd, writeEnd) = try FileDescriptor.safePipe()
        defer {
            try? readEnd.close()
            try? writeEnd.close()
        }
        let duplicate = try readEnd.safeDuplicate()
        defer { try? duplicate.close() }
        #expect(duplicate != readEnd)
        #expect(try isCloseOnExec(duplicate))
    }

    @Test func safeDuplicateAsTarget() throws {
        let (readEnd, writeEnd) = try FileDescriptor.safePipe()
        defer {
            try? readEnd.close()
            try? writeEnd.close()
        }
        // Obtain a free descriptor number to duplicate onto.
        let target = try readEnd.safeDuplicate()
        defer { try? target.close() }
        let duplicate = try writeEnd.safeDuplicate(as: target)
        #expect(duplicate == target)
        #expect(try isCloseOnExec(duplicate))

        // Duplicating a descriptor onto itself is rejected, as with dup3.
        #expect(throws: Errno.invalidArgument) {
            try writeEnd.safeDuplicate(as: writeEnd)
        }
    }
}
#endif
