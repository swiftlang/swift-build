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

#if !os(Windows)

#if canImport(System)
import System
#else
import SystemPackage
#endif

import SWBLibc

/// Signals that a file descriptor may be ready for reading or writing.
typealias PipeIOSignalStream = AsyncThrowingStream<Bool, any Error>

extension PipeIOBackend {
    enum Event {
        case read
        case write
    }

    /// The outcome of registering a file descriptor with the kqueue or epoll instance.
    enum RegistrationOutcome {
        case registered
        case failed(PipeIOError)
    }

    func prepare(_ fileDescriptor: FileDescriptor, for event: Event) -> PipeIOError? {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags != -1 else {
            return PipeIOError("failed to get flags for \(fileDescriptor.rawValue)", underlyingError: Errno(rawValue: errno))
        }
        guard fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK) != -1 else {
            return PipeIOError("failed to set \(fileDescriptor.rawValue) to be non-blocking", underlyingError: Errno(rawValue: errno))
        }
        #if canImport(Darwin)
        // Report EPIPE instead of raising SIGPIPE when the read end has been closed, like DispatchIO does.
        if event == .write && fcntl(fileDescriptor.rawValue, F_SETNOSIGPIPE, 1) == -1 {
            return PipeIOError("failed to disable SIGPIPE for \(fileDescriptor.rawValue)", underlyingError: Errno(rawValue: errno))
        }
        #endif
        return nil
    }

    func read(from fileDescriptor: FileDescriptor, upTo maxLength: Int) async throws(PipeIOError) -> [UInt8]? {
        var resultBuffer: [UInt8] = Array(repeating: 0, count: maxLength)
        // Register the descriptor with the kqueue/epoll. It stays registered across reads and is only detached when the caller closes it (or on EOF/error), so sustained streaming costs one `epoll_ctl`/`kevent` registration per descriptor instead of one per buffer.
        let (signalStream, outcome) = self.registerFileDescriptor(fileDescriptor, for: .read)
        switch outcome {
        case .registered:
            break
        case .failed(let error):
            throw error
        }
        var iterator = signalStream.makeAsyncIterator()

        // Each iteration first attempts a non-blocking read, draining bytes that are already buffered, and only awaits a readiness signal when the read reports `EAGAIN`. Because the descriptor is registered edge-triggered, this "try first" step is what keeps a persistent registration correct: we never park while data is buffered, so a missed edge can't strand bytes.
        readLoop: while true {
            do {
                let bytesRead = try resultBuffer.withUnsafeMutableBytes { bufferPointer in
                    return try fileDescriptor.read(into: bufferPointer, retryOnInterrupt: true)
                }
                if bytesRead > 0 {
                    // Read some data. Return immediately so the caller can process it without waiting for the buffer to fill. The descriptor stays registered for the next read.
                    resultBuffer.removeLast(resultBuffer.count - bytesRead)
                    return resultBuffer
                } else {
                    // EOF: no more data will ever arrive. Detach now.
                    self.removeRegistration(for: fileDescriptor)
                    return nil
                }
            } catch {
                // FileDescriptor.read only throws Errno
                let _errno = error as! Errno
                guard self.shouldWaitForNextSignal(with: _errno.rawValue) else {
                    // Throw all other errors.
                    self.removeRegistration(for: fileDescriptor)
                    throw PipeIOError("failed to read from \(fileDescriptor.rawValue)", underlyingError: _errno)
                }
                // No data available right now. Fall through to await the next signal
            }

            do {
                if try await iterator.next() == nil {
                    // The signal stream finished without delivering more data, because the calling task was cancelled. Fall through to a final drain.
                    break readLoop
                }
            } catch {
                self.removeRegistration(for: fileDescriptor)
                throw PipeIOError("failed to read from \(fileDescriptor.rawValue)", underlyingError: error)
            }
        }

        // Cancellation drain: try one last non-blocking read to surface bytes that were in the kernel buffer when cancellation arrived.
        let drainedLength = resultBuffer.withUnsafeMutableBytes { bufferPtr -> Int in
            // The descriptor was set to non-blocking in `prepare`, so this `read` returns immediately even if no data is ready.
            do {
                return try fileDescriptor.read(into: bufferPtr, retryOnInterrupt: true)
            } catch {
                // EAGAIN, EWOULDBLOCK, or another error: no more data right now.
                return 0
            }
        }
        if drainedLength > 0 {
            resultBuffer.removeLast(resultBuffer.count - drainedLength)
            return resultBuffer
        }
        return nil
    }

    func write(_ bytes: [UInt8], to fileDescriptor: FileDescriptor) async throws(PipeIOError) -> Int {
        // Register the descriptor once. It stays registered for reuse across writes and is detached when the descriptor is closed, or on error.
        let (signalStream, outcome) = self.registerFileDescriptor(fileDescriptor, for: .write)
        switch outcome {
        case .registered:
            break
        case .failed(let error):
            throw error
        }
        var iterator = signalStream.makeAsyncIterator()

        var writtenLength: Int = 0
        // Each iteration first attempts a non-blocking write and only awaits a writability signal when the pipe is full (`EAGAIN`). The descriptor is registered edge-triggered, so we must never park while the pipe still has space.
        writeLoop: while true {
            do {
                let written = try bytes.withUnsafeBytes { buffer in
                    return try fileDescriptor.write(UnsafeRawBufferPointer(rebasing: buffer[writtenLength...]), retryOnInterrupt: true)
                }
                writtenLength += written
                if writtenLength >= bytes.count {
                    // Wrote all data. The descriptor stays registered for reuse.
                    return writtenLength
                }
                // Wrote a partial chunk: the pipe is full now. Retry, which either writes more or reports `EAGAIN` and waits below.
                continue writeLoop
            } catch {
                // FileDescriptor.write only throws Errno
                let _errno = error as! Errno
                guard self.shouldWaitForNextSignal(with: _errno.rawValue) else {
                    // Throw all other errors.
                    self.removeRegistration(for: fileDescriptor)
                    throw PipeIOError("failed to write to \(fileDescriptor.rawValue)", underlyingError: _errno)
                }
                // The pipe is full right now. Fall through to await the next ready signal.
            }

            do {
                if try await iterator.next() == nil {
                    // The signal stream finished while data remained to write, because the calling task was cancelled. Return whatever bytes the call already pushed so the caller observes a partial write.
                    return writtenLength
                }
            } catch {
                self.removeRegistration(for: fileDescriptor)
                throw PipeIOError("failed to write to \(fileDescriptor.rawValue)", underlyingError: error)
            }
        }
    }

    @inline(__always)
    private func shouldWaitForNextSignal(with error: CInt) -> Bool {
        return error == EAGAIN || error == EWOULDBLOCK
    }
}

#endif
