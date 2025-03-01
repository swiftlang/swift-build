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

private import Foundation

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

extension AsyncThrowingStream where Element == UInt8, Failure == any Error {
    /// Returns an async stream which reads bytes from the specified file descriptor. Unlike `FileHandle.bytes`, it does not block the caller.
    @available(macOS, deprecated: 15.0, message: "Use the AsyncSequence-returning overload.")
    @available(iOS, deprecated: 18.0, message: "Use the AsyncSequence-returning overload.")
    @available(tvOS, deprecated: 18.0, message: "Use the AsyncSequence-returning overload.")
    @available(watchOS, deprecated: 11.0, message: "Use the AsyncSequence-returning overload.")
    @available(visionOS, deprecated: 2.0, message: "Use the AsyncSequence-returning overload.")
    public static func _dataStream(reading fileDescriptor: DispatchFD, on queue: SWBQueue) -> AsyncThrowingStream<Element, any Error> {
        AsyncThrowingStream { continuation in
            let newFD: DispatchFD
            do {
                newFD = try fileDescriptor._duplicate()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let io = SWBDispatchIO.stream(fileDescriptor: newFD, queue: queue) { error in
                do {
                    try newFD._close()
                    if error != 0 {
                        continuation.finish(throwing: POSIXError(error, context: "dataStream(reading: \(fileDescriptor))#1"))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            io.setLimit(lowWater: 0)
            io.setLimit(highWater: 4096)

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    io.close(flags: .stop)
                } else {
                    io.close()
                }
            }

            io.read(offset: 0, length: .max, queue: queue) { done, data, error in
                guard error == 0 else {
                    continuation.finish(throwing: POSIXError(error, context: "dataStream(reading: \(fileDescriptor))#2"))
                    return
                }

                let data = data ?? .empty
                for element in data {
                    continuation.yield(element)
                }

                if done {
                    continuation.finish()
                }
            }
        }
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension AsyncSequence where Element == UInt8, Failure == any Error {
    /// Returns an async stream which reads bytes from the specified file descriptor. Unlike `FileHandle.bytes`, it does not block the caller.
    public static func dataStream(reading fileDescriptor: DispatchFD, on queue: SWBQueue) -> any AsyncSequence<Element, any Error> {
        AsyncThrowingStream<SWBDispatchData, any Error> { continuation in
            let newFD: DispatchFD
            do {
                newFD = try fileDescriptor._duplicate()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            let io = SWBDispatchIO.stream(fileDescriptor: newFD, queue: queue) { error in
                do {
                    try newFD._close()
                    if error != 0 {
                        let context = "dataStream(reading: \(fileDescriptor) \"\(Result { try fileDescriptor._filePath() })\")#1"
                        continuation.finish(throwing: POSIXError(error, context: context))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            io.setLimit(lowWater: 0)
            io.setLimit(highWater: 4096)

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    io.close(flags: .stop)
                } else {
                    io.close()
                }
            }

            io.read(offset: 0, length: .max, queue: queue) { done, data, error in
                guard error == 0 else {
                    let context = "dataStream(reading: \(fileDescriptor) \"\(Result { try fileDescriptor._filePath() })\")#2"
                    continuation.finish(throwing: POSIXError(error, context: context))
                    return
                }

                let data = data ?? .empty
                continuation.yield(data)

                if done {
                    continuation.finish()
                }
            }
        }.flattened
    }
}
