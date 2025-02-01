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
    @available(macOS, deprecated: 15.0, message: "Use the AsyncSequence-returning overload.")
    @available(iOS, deprecated: 18.0, message: "Use the AsyncSequence-returning overload.")
    @available(tvOS, deprecated: 18.0, message: "Use the AsyncSequence-returning overload.")
    @available(watchOS, deprecated: 11.0, message: "Use the AsyncSequence-returning overload.")
    @available(visionOS, deprecated: 2.0, message: "Use the AsyncSequence-returning overload.")
    public func _bytes(on queue: SWBQueue) -> AsyncThrowingStream<UInt8, any Error> {
        ._dataStream(reading: DispatchFD(fileHandle: self), on: queue)
    }

    /// Replacement for `bytes` which uses DispatchIO to avoid blocking the caller.
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public func bytes(on queue: SWBQueue) -> any AsyncSequence<UInt8, any Error> {
        AsyncThrowingStream.dataStream(reading: DispatchFD(fileHandle: self), on: queue)
    }
}
