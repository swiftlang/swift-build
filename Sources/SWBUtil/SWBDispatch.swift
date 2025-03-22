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

// This file contains helpers used to bridge GCD and Swift Concurrency.
// In the long term, these ideally all go away.

private import Dispatch
public import SWBLibc
import Foundation

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

/// Represents a `dispatch_fd_t` which is a POSIX file descriptor on Unix-like platforms, or a HANDLE on Windows.
///
/// It performs non-owning conversions from FileDescriptors and FileHandles, but not the reverse. The raw fd/HANDLE value is inaccessible to callers and privately forwarded to relevant Dispatch APIs.
public struct DispatchFD {
    #if os(Windows)
    fileprivate let rawValue: Int
    #else
    fileprivate let rawValue: Int32
    #endif

    public init(fileDescriptor: FileDescriptor) {
        #if os(Windows)
        rawValue = _get_osfhandle(fileDescriptor.rawValue)
        #else
        rawValue = fileDescriptor.rawValue
        #endif
    }

    init(fileHandle: FileHandle) {
        #if os(Windows)
        // This may look unsafe, but is how swift-corelibs-dispatch works. Basically, dispatch_fd_t directly represents either a POSIX file descriptor OR a Windows HANDLE pointer address, meaning that the fileDescriptor parameter of various Dispatch APIs is actually NOT a file descriptor on Windows but rather a HANDLE. This means that the handle should NOT be converted using _open_osfhandle, and the return value of this function should ONLY be passed to Dispatch functions where the fileDescriptor parameter is masquerading as a HANDLE in this manner. Use with extreme caution.
        rawValue = .init(bitPattern: fileHandle._handle)
        #else
        rawValue = fileHandle.fileDescriptor
        #endif
    }

    internal func _duplicate() throws -> DispatchFD {
        #if os(Windows)
        return self
        #else
        return try DispatchFD(fileDescriptor: FileDescriptor(rawValue: rawValue).duplicate())
        #endif
    }

    internal func _close() throws {
        #if !os(Windows)
        try FileDescriptor(rawValue: rawValue).close()
        #endif
    }

    // Only exists to help debug a rare concurrency issue where the file descriptor goes invalid
    internal func _filePath() throws -> String {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(rawValue, F_GETPATH, &buffer) == -1 {
            throw POSIXError(errno, "fcntl", String(rawValue), "F_GETPATH")
        }
        return String(cString: buffer)
        #else
        return String()
        #endif
    }
}

// @unchecked: rdar://130051790 (DispatchData should be Sendable)
public struct SWBDispatchData: @unchecked Sendable {
    fileprivate var dispatchData: DispatchData

    public init(bytes: UnsafeRawBufferPointer) {
        dispatchData = DispatchData(bytes: bytes)
    }

    fileprivate init(_ dispatchData: DispatchData) {
        self.dispatchData = dispatchData
    }

    public mutating func append(_ other: SWBDispatchData) {
        dispatchData.append(other.dispatchData)
    }

    public mutating func append(_ other: UnsafeRawBufferPointer) {
        dispatchData.append(other)
    }

    public func subdata(in range: Range<Int>) -> SWBDispatchData {
        SWBDispatchData(dispatchData.subdata(in: range))
    }

    public func withUnsafeBytes(body: (UnsafePointer<UInt8>) -> Void) {
        dispatchData.withUnsafeBytes(body: body)
    }

    public static let empty = SWBDispatchData(.empty)
}

extension SWBDispatchData: RandomAccessCollection {
    public var startIndex: Int {
        return dispatchData.startIndex
    }

    public var endIndex: Int {
        return dispatchData.endIndex
    }

    public subscript(i: Int) -> UInt8 {
        return dispatchData[i]
    }
}

/// Thin wrapper for `DispatchSemaphore` to isolate it from the rest of the codebase and help migration away from it.
internal final class SWBDispatchSemaphore: Sendable {
    private let semaphore: DispatchSemaphore

    public init(value: Int) {
        semaphore = DispatchSemaphore(value: value)
    }

    @discardableResult public func signal() -> Int {
        semaphore.signal()
    }

    @available(*, noasync)
    public func blocking_wait() {
        assertNoConcurrency {
            semaphore.wait()
        }
    }
}

/// Thin wrapper for `DispatchGroup` to isolate it from the rest of the codebase and help migration away from it.
public final class SWBDispatchGroup: Sendable {
    fileprivate let group: DispatchGroup

    public init() {
        group = DispatchGroup()
    }

    public func enter() {
        group.enter()
    }

    public func leave() {
        group.leave()
    }

    public func wait(queue: SWBQueue) async {
        await withCheckedContinuation { continuation in
            group.notify(queue: queue.queue) {
                continuation.resume()
            }
        }
    }
}

public final class SWBDispatchIO: Sendable {
    public struct CloseFlags: OptionSet, Sendable {
        public let rawValue: Int32
        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }
        public static let stop: CloseFlags = CloseFlags(rawValue: 1 << 0)
    }

    private let io: DispatchIO

    public init(fileDescriptor: Int32, queue: SWBQueue, cleanupHandler: @escaping (Int32) -> Void) {
        io = DispatchIO(type: .stream, fileDescriptor: numericCast(fileDescriptor), queue: queue.queue, cleanupHandler: cleanupHandler)
    }

    public static func stream(fileDescriptor: DispatchFD, queue: SWBQueue, cleanupHandler: @escaping (Int32) -> Void) -> SWBDispatchIO {
        // Most of the dispatch APIs take a parameter called "fileDescriptor". On Windows (except makeReadSource and makeWriteSource) it is actually a HANDLE, so convert it accordingly.
        SWBDispatchIO(fileDescriptor: numericCast(fileDescriptor.rawValue), queue: queue, cleanupHandler: cleanupHandler)
    }

    public func setLimit(lowWater: Int) {
        io.setLimit(lowWater: lowWater)
    }

    public func setLimit(highWater: Int) {
        io.setLimit(highWater: highWater)
    }

    public func read(offset: off_t, length: Int, queue: SWBQueue, ioHandler: @escaping (Bool, SWBDispatchData?, Int32) -> Void) {
        io.read(offset: offset, length: length, queue: queue.queue, ioHandler: { done, data, error in
            ioHandler(done, data.map { SWBDispatchData($0) }, error)
        })
    }

    public func write(offset: off_t, data: SWBDispatchData, queue: SWBQueue, ioHandler: @escaping (Bool, SWBDispatchData?, Int32) -> Void) {
        io.write(offset: offset, data: data.dispatchData, queue: queue.queue, ioHandler: { done, data, error in
            ioHandler(done, data.map { SWBDispatchData($0) }, error)
        })
    }

    public func write(offset: off_t, data: SWBDispatchData, queue: SWBQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            write(offset: 0, data: data, queue: queue) { done, data, error in
                guard error == 0 else {
                    continuation.resume(throwing: POSIXError(error))
                    return
                }

                if done {
                    continuation.resume()
                }
            }
        }
    }

    public func close(flags: CloseFlags = []) {
        io.close(flags: flags.contains(.stop) ? .stop : [])
    }

    public func barrier(execute block: @escaping () -> Void) {
        io.barrier(execute: block)
    }
}

/// Thin wrapper for `DispatchQueue` to isolate it from the rest of the codebase and help migration away from it.
public final class SWBQueue: Sendable {
    public struct Attributes: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
        public static let concurrent = Attributes(rawValue: 1 << 0)
    }

    public enum AutoreleaseFrequency: Sendable {
        case inherit
        case workItem
    }

    public struct DispatchWorkItemFlags: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
        public static let barrier = DispatchWorkItemFlags(rawValue: 1 << 0)
    }

    internal let queue: DispatchQueue

    public init(label: String, qos: SWBQoS = .unspecified, attributes: Attributes = [], autoreleaseFrequency: AutoreleaseFrequency = .inherit) {
        self.queue = DispatchQueue(label: label, qos: qos.dispatchQoS, attributes: attributes.contains(.concurrent) ? .concurrent : [], autoreleaseFrequency: autoreleaseFrequency.dispatchAutoreleaseFrequency)
    }

    fileprivate init(queue: DispatchQueue) {
        self.queue = queue
    }

    @available(*, noasync)
    public func blocking_sync<T>(flags: DispatchWorkItemFlags = [], execute body: () throws -> T) rethrows -> T {
        try assertNoConcurrency {
            try queue.sync(flags: flags.dispatchFlags, execute: body)
        }
    }

    /// Submits a block object for execution and returns after that block finishes executing.
    /// - note: This implementation won't block the calling thread, unlike the synchronous overload of ``sync()``.
    public func sync<T>(qos: SWBQoS = .unspecified, flags: DispatchWorkItemFlags = [], execute block: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async(qos: qos.dispatchQoS, flags: flags.dispatchFlags) {
                continuation.resume(returning: block())
            }
        }
    }

    public func async(group: SWBDispatchGroup? = nil, execute body: @escaping @Sendable () -> Void) {
        return queue.async(group: group?.group, execute: body)
    }

    // Temporary hack until rdar://98401196 (Use Swift Concurrency for low-level IO in ServiceHostConnection) lands. This should be safe because we only ever call `async` once in the place we use this.
    public func async(qos: SWBQoS = .unspecified, execute work: @Sendable @escaping () async -> Void) {
        queue.async(group: nil, qos: qos.dispatchQoS, flags: []) {
            Task {
                await work()
            }
        }
    }

    public static func global() -> Self {
        Self(queue: .global())
    }
}

extension SWBQueue {
    @available(*, noasync)
    public static func concurrentPerform(iterations: Int, _ block: @Sendable (Int) -> Void) {
        assertNoConcurrency {
            DispatchQueue.concurrentPerform(iterations: iterations, execute: block)
        }
    }
}

public enum SWBQoS: Sendable {
    case background
    case utility
    case `default`
    case userInitiated
    case userInteractive
    case unspecified
}

fileprivate extension SWBQoS {
    var dispatchQoS: DispatchQoS {
        switch self {
        case .background: return .background
        case .utility: return .utility
        case .default: return .default
        case .userInitiated: return .userInitiated
        case .userInteractive: return .userInteractive
        case .unspecified: return .unspecified
        }
    }
}

fileprivate extension SWBQueue.AutoreleaseFrequency {
    var dispatchAutoreleaseFrequency: DispatchQueue.AutoreleaseFrequency {
        switch self {
        case .inherit: return .inherit
        case .workItem: return .workItem
        }
    }
}

fileprivate extension SWBQueue.DispatchWorkItemFlags {
    var dispatchFlags: DispatchWorkItemFlags {
        var flags: DispatchWorkItemFlags = []
        if contains(.barrier) { flags.insert(.barrier) }
        return flags
    }
}

fileprivate func assertNoConcurrency<T>(_ block: () throws -> T) rethrows -> T {
    try withUnsafeCurrentTask { task in
        #if false
        assert(task == nil, "Attempted to perform blocking operation on the Swift Concurrency thread pool")
        #endif
        return try block()
    }
}
