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

import Foundation

/// Runs an async function and synchronously waits for the response.
/// - warning: This function is extremely dangerous because it blocks the calling thread and may lead to deadlock, and should only be used as a temporary transitional aid.
@available(*, noasync)
public func runAsyncAndBlock<T: Sendable, E>(_ block: @Sendable @escaping () async throws(E) -> T) throws(E) -> T {
    withUnsafeCurrentTask { task in
        if task != nil {
            assertionFailure("This function should not be invoked from the Swift Concurrency thread pool as it may lead to deadlock via thread starvation.")
        }
    }
    let result: LockedValue<Result<T, E>?> = .init(nil)
    let sema: SWBDispatchSemaphore? = Thread.isMainThread ? nil : SWBDispatchSemaphore(value: 0)
    Task<Void, Never> {
        let value = await Result.catching { () throws(E) -> T in try await block() }
        result.withLock { $0 = value }
        sema?.signal()
    }
    if let sema {
        sema.blocking_wait()
    } else {
        while result.withLock({ $0 }) == nil {
            RunLoop.current.run(until: Date())
        }
    }
    return try result.value!.get()
}

extension DispatchFD {
    public func readChunk(upToLength maxLength: Int) async throws -> SWBDispatchData {
        return try await withCheckedThrowingContinuation { continuation in
            SWBDispatchIO.read(
                fromFileDescriptor: self,
                maxLength: maxLength,
                runningHandlerOn: .global()
            ) { data, error in
                if error != 0 {
                    continuation.resume(throwing: POSIXError(error))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    /// Returns an async stream which reads bytes from the specified file descriptor. Unlike `FileHandle.bytes`, it does not block the caller.
    @available(macOS, deprecated: 15.0, message: "Use the AsyncSequence-returning overload.")
    @available(iOS, deprecated: 18.0, message: "Use the AsyncSequence-returning overload.")
    @available(tvOS, deprecated: 18.0, message: "Use the AsyncSequence-returning overload.")
    @available(watchOS, deprecated: 11.0, message: "Use the AsyncSequence-returning overload.")
    @available(visionOS, deprecated: 2.0, message: "Use the AsyncSequence-returning overload.")
    public func _dataStream() -> AsyncThrowingStream<SWBDispatchData, any Error> {
        AsyncThrowingStream<SWBDispatchData, any Error> {
            while !Task.isCancelled {
                let chunk = try await readChunk(upToLength: 4096)
                if chunk.isEmpty {
                    return nil
                }
                return chunk
            }
            throw CancellationError()
        }
    }

    /// Returns an async stream which reads bytes from the specified file descriptor. Unlike `FileHandle.bytes`, it does not block the caller.
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public func dataStream() -> some AsyncSequence<SWBDispatchData, any Error> {
        AsyncThrowingStream<SWBDispatchData, any Error> {
            while !Task.isCancelled {
                let chunk = try await readChunk(upToLength: 4096)
                if chunk.isEmpty {
                    return nil
                }
                return chunk
            }
            throw CancellationError()
        }
    }
}
