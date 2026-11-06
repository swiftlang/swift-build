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

#if os(Windows)

#if canImport(System)
import System
#else
import SystemPackage
#endif

import Foundation
import Synchronization
@preconcurrency import WinSDK

private typealias SignalStream = AsyncThrowingStream<DWORD, any Error>
private typealias CompletionKey = UInt64
private let _registration = SWBMutex(PipeIORegistration<CompletionKey, DWORD>())
private let _pipeNameCounter = SWBMutex<UInt64>(0)

private func handle(for fileDescriptor: FileDescriptor) -> HANDLE? {
    return HANDLE(bitPattern: _get_osfhandle(fileDescriptor.rawValue))
}

extension PipeIO {
    static func makeOverlappedPipe() throws -> (readEnd: FileDescriptor, writeEnd: FileDescriptor) {
        // Overlapped I/O is not supported by anonymous pipes, so create a named pipe. See https://learn.microsoft.com/en-us/windows/win32/ipc/anonymous-pipe-operations
        while true {
            // Named pipes are system-wide. To avoid two pipes with the same name, create the pipe with `FILE_FLAG_FIRST_PIPE_INSTANCE`, which reports `ERROR_ACCESS_DENIED` if a pipe with the same name already exists.
            let counter = _pipeNameCounter.withLock { value in
                value += 1
                return value
            }
            let pipeName = "\\\\.\\pipe\\LOCAL\\swift-build-\(GetCurrentProcessId())-\(counter)"

            let readHandle = pipeName.withCString(encodedAs: UTF16.self) { pipeNameW in
                CreateNamedPipeW(
                    pipeNameW,
                    DWORD(PIPE_ACCESS_INBOUND) | DWORD(FILE_FLAG_OVERLAPPED) | DWORD(FILE_FLAG_FIRST_PIPE_INSTANCE),
                    DWORD(PIPE_TYPE_BYTE) | DWORD(PIPE_READMODE_BYTE) | DWORD(PIPE_WAIT) | DWORD(PIPE_REJECT_REMOTE_CLIENTS),
                    1, // Max instances
                    // Both libuv (Node) and Rust std::process use this value
                    DWORD(64 * 1024),
                    DWORD(64 * 1024),
                    0,
                    nil
                )
            }
            guard let readHandle, readHandle != INVALID_HANDLE_VALUE else {
                let errorCode = GetLastError()
                if errorCode == ERROR_ACCESS_DENIED {
                    continue
                }
                throw PipeIOError("CreateNamedPipeW failed", underlyingError: Win32Error(errorCode))
            }

            let writeHandle = pipeName.withCString(encodedAs: UTF16.self) { pipeNameW in
                CreateFileW(pipeNameW, DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL) | DWORD(FILE_FLAG_OVERLAPPED), nil)
            }
            guard let writeHandle, writeHandle != INVALID_HANDLE_VALUE else {
                let errorCode = GetLastError()
                CloseHandle(readHandle)
                throw PipeIOError("CreateFileW failed", underlyingError: Win32Error(errorCode))
            }

            // Wrap the handles in C runtime file descriptors, which take ownership of the handles.
            let readEnd = _open_osfhandle(intptr_t(bitPattern: readHandle), _O_BINARY)
            guard readEnd != -1 else {
                CloseHandle(readHandle)
                CloseHandle(writeHandle)
                throw PipeIOError("_open_osfhandle failed", underlyingError: Errno(rawValue: errno))
            }
            let writeEnd = _open_osfhandle(intptr_t(bitPattern: writeHandle), _O_BINARY)
            guard writeEnd != -1 else {
                _close(readEnd)
                CloseHandle(writeHandle)
                throw PipeIOError("_open_osfhandle failed", underlyingError: Errno(rawValue: errno))
            }
            return (FileDescriptor(rawValue: readEnd), FileDescriptor(rawValue: writeEnd))
        }
    }
}

final class PipeIOBackend: @unchecked Sendable {
    static let shared = PipeIOBackend()

    private let ioCompletionPort: Result<HANDLE, PipeIOError>

    private init() {
        guard let ioCompletionPort = CreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, 0), ioCompletionPort != INVALID_HANDLE_VALUE else {
            self.ioCompletionPort = .failure(PipeIOError("CreateIoCompletionPort failed", underlyingError: Win32Error(GetLastError())))
            return
        }
        self.ioCompletionPort = .success(ioCompletionPort)

        nonisolated(unsafe) let port = ioCompletionPort
        let thread = Thread {
            func reportError(_ error: PipeIOError) {
                let continuations = _registration.withLock { store in
                    return store.allContinuations()
                }
                for continuation in continuations {
                    continuation.finish(throwing: error)
                }
            }

            while true {
                var bytesTransferred: DWORD = 0
                var completionKey: CompletionKey = 0
                var overlapped: LPOVERLAPPED? = nil

                let monitorResult = GetQueuedCompletionStatus(port, &bytesTransferred, &completionKey, &overlapped, INFINITE)
                if !monitorResult {
                    let lastError = GetLastError()
                    // `ERROR_BROKEN_PIPE`: end of file.
                    // `ERROR_OPERATION_ABORTED`: the I/O was cancelled by `CancelIoEx`, because the awaiting task was cancelled.
                    // In both cases finish the per-handle stream so the awaiting read or write returns to its caller. Leave the registration in place because Windows can't remove a HANDLE from the IOCP, so the entry doubles as a marker that the handle is registered until it's closed.
                    if lastError == ERROR_BROKEN_PIPE || lastError == ERROR_OPERATION_ABORTED {
                        let continuation = _registration.withLock { store in
                            return store.continuation(for: completionKey)
                        }
                        continuation?.finish()
                        continue
                    } else {
                        reportError(PipeIOError("GetQueuedCompletionStatus failed", underlyingError: Win32Error(lastError)))
                        break
                    }
                }

                let continuation = _registration.withLock { store in
                    return store.continuation(for: completionKey)
                }
                continuation?.yield(bytesTransferred)
            }
        }
        thread.name = "org.swift.swift-build.PipeIO"
        thread.start()
    }

    private func registerHandle(_ handle: HANDLE) -> (stream: SignalStream, error: PipeIOError?) {
        let (stream, continuation) = SignalStream.makeStream()

        let ioPort: HANDLE
        switch self.ioCompletionPort {
        case .success(let port):
            ioPort = port
        case .failure(let error):
            continuation.finish(throwing: error)
            return (stream, error)
        }

        let completionKey = CompletionKey(UInt(bitPattern: handle))

        let error: PipeIOError? = _registration.withLock { storage in
            switch storage.register(completionKey, continuation: continuation) {
            case .updated:
                // The handle was already attached to the IOCP by a previous read or write; the new continuation replaces the previous one in the map.
                return nil
            case .registered:
                // Per the Windows documentation, the function returns the handle of the existing I/O completion port on success.
                guard CreateIoCompletionPort(handle, ioPort, completionKey, 0) == ioPort else {
                    let capturedError = GetLastError()
                    // Roll back the registration so a future attempt gets a clean slate rather than seeing a stale entry.
                    _ = storage.removeRegistration(for: completionKey)
                    return PipeIOError("CreateIoCompletionPort failed", underlyingError: Win32Error(capturedError))
                }
                return nil
            }
        }

        if let error {
            continuation.finish(throwing: error)
        }
        return (stream, error)
    }

    private enum OverlappedReadOutcome {
        /// The read placed `count` bytes at the front of the buffer.
        case read(Int)
        /// The signal stream finished before delivering data: EOF, a broken pipe, or an operation aborted by cancellation.
        case finished
    }

    /// Issues a single overlapped `ReadFile` on `handle` and awaits its completion through `stream`.
    private func issueAndAwaitRead(on handle: HANDLE, stream: SignalStream, into resultBuffer: inout [UInt8]) async throws(PipeIOError) -> OverlappedReadOutcome {
        var iterator = stream.makeAsyncIterator()

        // Empty `_OVERLAPPED()` because `ReadFile` only reads pipes here.
        var overlapped = _OVERLAPPED()
        let succeed = resultBuffer.withUnsafeMutableBufferPointer { bufferPointer in
            let targetCount: DWORD = self.calculateRemainingCount(totalCount: bufferPointer.count, readCount: 0)
            return ReadFile(handle, bufferPointer.baseAddress!, targetCount, nil, &overlapped)
        }

        if !succeed {
            let lastError = GetLastError()
            if lastError == ERROR_BROKEN_PIPE {
                return .finished
            }
            guard lastError == ERROR_IO_PENDING else {
                throw PipeIOError("ReadFile failed", underlyingError: Win32Error(lastError))
            }
        }

        let bytesRead: DWORD
        do {
            guard let next = try await iterator.next() else {
                // `next()` resolved to `nil` because the awaiting task was cancelled, not because the read failed. The `ReadFile` issued above may have already completed, with its bytes sitting in `resultBuffer`. Those bytes have been pulled out of the pipe, so the post-cancellation drain cannot recover them: dropping them here loses exactly one buffer.
                //
                // Settle the operation and surface any recovered bytes. On a byte-mode pipe, a cancelled pending read almost always reports zero, so the `.read` arm fires only when bytes land in the narrow window between issue and cancel.
                let transferred = self.settlePendingOverlapped(handle: handle, overlapped: &overlapped)
                return transferred > 0 ? .read(Int(truncatingIfNeeded: transferred)) : .finished
            }
            bytesRead = next
        } catch {
            // The signal stream threw, which happens only when the IOCP monitor hits a fatal `GetQueuedCompletionStatus` error and finishes every continuation. The `ReadFile` issued above may still be pending against `resultBuffer`; settle it before the buffer goes out of scope.
            self.settlePendingOverlapped(handle: handle, overlapped: &overlapped)
            throw PipeIOError("ReadFile failed", underlyingError: error)
        }

        if bytesRead == 0 {
            return .finished
        }
        return .read(Int(truncatingIfNeeded: bytesRead))
    }

    /// Drives an overlapped operation to a terminal state and reports the bytes it transferred.
    ///
    /// This is called when the signal stream stops delivering this operation's completion, either because the awaiting task was cancelled, or because the IOCP monitor finished every continuation while reporting a fatal error. The `ReadFile`/`WriteFile` being reconciled is then in one of three states:
    ///
    /// - Already completed: `GetOverlappedResult` reports the outcome immediately, and the returned count reflects what it transferred.
    /// - Still pending: the kernel is mid-operation against the caller's buffer and `overlapped`. Returning now would let both go out of scope while the kernel still holds them (use-after-free), so this cancels the specific operation and blocks until it has fully unwound.
    /// - Any other terminal status: the operation is already done and nothing was recovered, so the returned count is zero.
    ///
    /// The blocking wait uses a `NULL` `hEvent`, so `GetOverlappedResult` falls back to signaling on `handle` itself. Microsoft discourages that only because a handle carrying several concurrent overlapped operations can't disambiguate which one completed. `PipeIO` requires that at most one operation is ever in flight per handle, and `ReadFile`/`WriteFile` reset the handle to nonsignaled at issue, so no earlier operation's signal can satisfy this wait early.
    ///
    /// - Important: `overlapped` must reference the same storage passed to the originating `ReadFile`/`WriteFile`, and the buffer from which that call read or wrote into must remain alive until this returns.
    @discardableResult
    private func settlePendingOverlapped(handle: HANDLE, overlapped: inout _OVERLAPPED) -> DWORD {
        var transferred: DWORD = 0
        if GetOverlappedResult(handle, &overlapped, &transferred, false) {
            return transferred
        }
        guard GetLastError() == ERROR_IO_INCOMPLETE else {
            return 0
        }
        _ = CancelIoEx(handle, &overlapped)
        if GetOverlappedResult(handle, &overlapped, &transferred, true) {
            return transferred
        }
        return 0
    }

    /// Reads bytes already buffered in the pipe after a read finished without data, without routing through the completion port.
    ///
    /// `PeekNamedPipe` neither consumes data nor blocks, so it gates the read; `ReadFile` is issued only when bytes are present, which then completes promptly.
    ///
    /// The read is overlapped (the handle is `FILE_FLAG_OVERLAPPED`), so it's synchronized on a private event rather than the completion port. The low bit of `OVERLAPPED.hEvent` is set so that, on a handle a prior read already bound to the port, this completion is not enqueued there for the monitor to pick up against an `OVERLAPPED` this call has freed.
    ///
    /// Returns the drained bytes, or `nil` once the buffer is empty or the pipe has reached EOF.
    private func drainBufferedData(from handle: HANDLE, capacity: Int) throws(PipeIOError) -> [UInt8]? {
        var bytesAvailable: DWORD = 0
        guard PeekNamedPipe(handle, nil, 0, nil, &bytesAvailable, nil) else {
            let lastError = GetLastError()
            // Empty pipe, write end closed: EOF, nothing left to drain.
            if lastError == ERROR_BROKEN_PIPE {
                return nil
            }
            throw PipeIOError("PeekNamedPipe failed", underlyingError: Win32Error(lastError))
        }
        guard bytesAvailable > 0 else {
            return nil
        }

        guard let event = CreateEventW(nil, true, false, nil) else {
            throw PipeIOError("CreateEventW failed", underlyingError: Win32Error(GetLastError()))
        }
        defer { CloseHandle(event) }

        var resultBuffer = [UInt8](repeating: 0, count: capacity)
        var overlapped = _OVERLAPPED()
        overlapped.hEvent = HANDLE(bitPattern: UInt(bitPattern: event) | 1)

        let started = resultBuffer.withUnsafeMutableBufferPointer { bufferPointer in
            let targetCount = self.calculateRemainingCount(totalCount: bufferPointer.count, readCount: 0)
            return ReadFile(handle, bufferPointer.baseAddress!, targetCount, nil, &overlapped)
        }
        if !started {
            let lastError = GetLastError()
            if lastError == ERROR_BROKEN_PIPE {
                return nil
            }
            guard lastError == ERROR_IO_PENDING else {
                throw PipeIOError("ReadFile failed", underlyingError: Win32Error(lastError))
            }
            // `PeekNamedPipe` already saw the bytes, so this returns promptly.
            WaitForSingleObject(event, INFINITE)
        }

        var bytesRead: DWORD = 0
        guard GetOverlappedResult(handle, &overlapped, &bytesRead, false) else {
            let lastError = GetLastError()
            if lastError == ERROR_BROKEN_PIPE {
                return nil
            }
            throw PipeIOError("ReadFile failed", underlyingError: Win32Error(lastError))
        }
        guard bytesRead > 0 else {
            return nil
        }
        resultBuffer.removeLast(resultBuffer.count - Int(truncatingIfNeeded: bytesRead))
        return resultBuffer
    }

    func removeRegistration(for fileDescriptor: FileDescriptor) {
        guard let handle = handle(for: fileDescriptor) else {
            return
        }
        // Windows does not provide a "deregistration" API (the reverse of `CreateIoCompletionPort`) for handles, and it reuses HANDLE values once they are closed. Since the handle value is used as the completion key, remove the registration when the handle is closed to allow a new registration to proceed if the handle value is reused.
        let continuation = _registration.withLock { storage in
            storage.removeRegistration(for: CompletionKey(UInt(bitPattern: handle)))
        }
        continuation?.finish()
    }

    func read(from fileDescriptor: FileDescriptor, upTo maxLength: Int) async throws(PipeIOError) -> [UInt8]? {
        guard let handle = handle(for: fileDescriptor) else {
            throw PipeIOError("invalid file descriptor \(fileDescriptor.rawValue)")
        }

        let (stream, error) = self.registerHandle(handle)
        if let error {
            throw error
        }

        var resultBuffer = [UInt8](repeating: 0, count: maxLength)
        switch try await self.issueAndAwaitRead(on: handle, stream: stream, into: &resultBuffer) {
        case .read(let count):
            resultBuffer.removeLast(resultBuffer.count - count)
            return resultBuffer
        case .finished:
            // EOF, or the read was aborted in flight. If a write landed in the buffer with no read pending to receive it, drain it now.
            return try self.drainBufferedData(from: handle, capacity: maxLength)
        }
    }

    func write(_ bytes: [UInt8], to fileDescriptor: FileDescriptor) async throws(PipeIOError) -> Int {
        guard let handle = handle(for: fileDescriptor) else {
            throw PipeIOError("invalid file descriptor \(fileDescriptor.rawValue)")
        }

        let (stream, error) = self.registerHandle(handle)
        if let error {
            throw error
        }
        var signalStream = stream.makeAsyncIterator()

        var writtenLength: Int = 0
        while true {
            // Use an empty `_OVERLAPPED()` here because `WriteFile` below only writes to non-seekable files (pipes).
            var overlapped = _OVERLAPPED()
            let succeed = bytes.withUnsafeBytes { ptr in
                // Windows `WriteFile` uses `DWORD` for target count, which means the call can write at most `DWORD.max` bytes.
                let remainingLength: DWORD = self.calculateRemainingCount(totalCount: ptr.count, readCount: writtenLength)
                let startPtr = ptr.baseAddress!.advanced(by: writtenLength)
                return WriteFile(handle, startPtr, remainingLength, nil, &overlapped)
            }
            if !succeed {
                // `WriteFile` is expected to return `false` in async mode. Confirm the call returned `ERROR_IO_PENDING`.
                let lastError = GetLastError()
                guard lastError == ERROR_IO_PENDING else {
                    throw PipeIOError("WriteFile failed", underlyingError: Win32Error(lastError))
                }
            }

            // Wait for the write to finish.
            let bytesWritten: DWORD
            do {
                guard let next = try await signalStream.next() else {
                    // `next()` resolved to `nil` because the awaiting task was cancelled, not because the write failed. The `WriteFile` issued above may still be pending, with the kernel reading from `bytes` and poised to write into `overlapped`; settle it first so neither is freed while the kernel is still using it.
                    self.settlePendingOverlapped(handle: handle, overlapped: &overlapped)
                    return writtenLength
                }
                bytesWritten = next
            } catch {
                // The signal stream threw, which happens only when the IOCP monitor hits a fatal `GetQueuedCompletionStatus` error and finishes every continuation. The `WriteFile` issued above may still be pending; settle it before `bytes` is released.
                self.settlePendingOverlapped(handle: handle, overlapped: &overlapped)
                throw PipeIOError("WriteFile failed", underlyingError: error)
            }

            writtenLength += Int(truncatingIfNeeded: bytesWritten)
            if writtenLength >= bytes.count {
                return writtenLength
            }
        }
    }

    // Windows `ReadFile` uses `DWORD` for target count, which means the call can read at most `DWORD.max` (`UInt32.max`) bytes.
    private func calculateRemainingCount(totalCount: Int, readCount: Int) -> DWORD {
        if MemoryLayout<Int>.size == MemoryLayout<Int32>.size {
            // 32-bit systems can't overflow the count.
            return DWORD(truncatingIfNeeded: totalCount - readCount)
        } else {
            // On 64-bit systems, cap the count at `DWORD.max`.
            return DWORD(truncatingIfNeeded: min(totalCount - readCount, Int(DWORD.max)))
        }
    }
}

#endif
