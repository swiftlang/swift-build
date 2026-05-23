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

public import Foundation

extension FileHandle {
    /// Replacement for `bytes` which uses DispatchIO to avoid blocking the caller.
    public func bytes() -> AsyncThrowingStream<SWBDispatchData, any Error> {
        DispatchFD(fileHandle: self).dataStream()
    }
}
