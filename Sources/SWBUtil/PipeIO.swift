//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// Adapted from AsyncIO in swift-subprocess

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

#if !(canImport(Darwin) || os(FreeBSD) || os(OpenBSD) || os(Linux) || os(Android) || os(Windows))
#error("PipeIO is not implemented for this platform")
#endif

public enum PipeIO {
    public static func makePipe() throws -> (readEnd: FileDescriptor, writeEnd: FileDescriptor) {
        #if os(Windows)
        return try makeOverlappedPipe()
        #else
        return try FileDescriptor.safePipe()
        #endif
    }

    /// Reads up to `maxLength` bytes from `fileDescriptor`, returning as soon as any data is available.
    ///
    /// - returns: The bytes read, or `nil` at end-of-file or if the calling task was cancelled.
    public static func read(from fileDescriptor: FileDescriptor, upTo maxLength: Int) async throws -> [UInt8]? {
        precondition(maxLength > 0)
        return try await PipeIOBackend.shared.read(from: fileDescriptor, upTo: maxLength)
    }

    /// Writes all of `bytes` to `fileDescriptor`.
    ///
    /// - returns: The number of bytes written, which is less than `bytes.count` only if the calling task was cancelled.
    @discardableResult
    public static func write(_ bytes: [UInt8], to fileDescriptor: FileDescriptor) async throws -> Int {
        guard !bytes.isEmpty else {
            return 0
        }
        return try await PipeIOBackend.shared.write(bytes, to: fileDescriptor)
    }

    /// Closes `fileDescriptor`, which must not have a read or write in flight.
    public static func close(_ fileDescriptor: FileDescriptor) throws {
        PipeIOBackend.shared.removeRegistration(for: fileDescriptor)
        try fileDescriptor.close()
    }
}

public struct PipeIOError: Error, CustomStringConvertible {
    public let reason: String
    public let underlyingError: (any Error)?

    init(_ reason: String, underlyingError: (any Error)? = nil) {
        self.reason = reason
        self.underlyingError = underlyingError
    }

    public var description: String {
        if let underlyingError {
            return "\(reason): \(underlyingError)"
        }
        return reason
    }
}

/// Maps the file descriptors (or on Windows, the I/O completion port keys) of pipes that have a read or write in flight to the continuations that are resumed by the monitor thread.
struct PipeIORegistration<Key: Hashable, Signal: Sendable> {
    typealias Continuation = AsyncThrowingStream<Signal, any Error>.Continuation

    enum RegisterResult {
        /// The first time this key was seen. The caller still needs to attach it to the kqueue, epoll instance, or I/O completion port.
        case registered
        /// The key was already attached by a previous read or write. The existing attachment is reused, and only the continuation is replaced.
        case updated
    }

    private var continuations: [Key: Continuation] = [:]

    mutating func register(_ key: Key, continuation: Continuation) -> RegisterResult {
        if let existing = continuations.updateValue(continuation, forKey: key) {
            // Finish the previous continuation so that any stale awaiter unblocks.
            existing.finish()
            return .updated
        }
        return .registered
    }

    mutating func removeRegistration(for key: Key) -> Continuation? {
        return continuations.removeValue(forKey: key)
    }

    func continuation(for key: Key) -> Continuation? {
        return continuations[key]
    }

    /// Returns every registered continuation, for when the monitor thread fails and needs to surface the error to every awaiting reader and writer.
    func allContinuations() -> [Continuation] {
        return Array(continuations.values)
    }
}
