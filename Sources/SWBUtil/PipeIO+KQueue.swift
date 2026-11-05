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

#if canImport(Darwin) || os(FreeBSD) || os(OpenBSD)

#if canImport(System)
import System
#else
import SystemPackage
#endif

import Foundation
import SWBLibc
import Synchronization

private let _kqueueEventSize = 256
private let _registration = SWBMutex(PipeIORegistration<CInt, Bool>())

// `kevent` is both a struct and a function, which makes calling the function ambiguous.
private let _kevent: @Sendable (CInt, UnsafePointer<kevent>?, CInt, UnsafeMutablePointer<kevent>?, CInt, UnsafePointer<timespec>?) -> CInt = kevent

private func _makeKevent(ident: UInt, filter: Int16, flags: UInt16) -> kevent {
    #if canImport(Darwin) || os(OpenBSD)
    return kevent(ident: ident, filter: filter, flags: flags, fflags: 0, data: 0, udata: nil)
    #else
    return kevent(ident: ident, filter: filter, flags: flags, fflags: 0, data: 0, udata: nil, ext: (0, 0, 0, 0))
    #endif
}

final class PipeIOBackend: Sendable {
    private struct State: Sendable {
        let kqueueFileDescriptor: CInt
    }

    static let shared = PipeIOBackend()

    private let state: Result<State, PipeIOError>

    private init() {
        #if os(FreeBSD) || os(OpenBSD)
        let kqueueFileDescriptor = kqueue1(O_CLOEXEC)
        #else
        let kqueueFileDescriptor = kqueue()
        #endif
        guard kqueueFileDescriptor >= 0 else {
            self.state = .failure(PipeIOError("kqueue failed", underlyingError: Errno(rawValue: errno)))
            return
        }

        let thread = Thread {
            func reportError(_ error: PipeIOError) {
                let continuations = _registration.withLock { store in
                    return store.allContinuations()
                }
                for continuation in continuations {
                    continuation.finish(throwing: error)
                }
            }

            var events: [kevent] = Array(repeating: _makeKevent(ident: 0, filter: 0, flags: 0), count: _kqueueEventSize)

            monitorLoop: while true {
                let eventCount = _kevent(kqueueFileDescriptor, nil, 0, &events, Int32(events.count), nil)
                if eventCount < 0 {
                    if errno == EINTR || errno == EAGAIN {
                        continue
                    }
                    reportError(PipeIOError("kevent wait failed", underlyingError: Errno(rawValue: errno)))
                    break monitorLoop
                }

                for index in 0..<Int(eventCount) {
                    let targetFileDescriptor = Int32(events[index].ident)
                    let continuation = _registration.withLock { store in
                        return store.continuation(for: targetFileDescriptor)
                    }
                    continuation?.yield(true)
                }
            }
        }
        thread.name = "org.swift.swift-build.PipeIO"
        thread.start()

        self.state = .success(State(kqueueFileDescriptor: kqueueFileDescriptor))
    }

    func registerFileDescriptor(_ fileDescriptor: FileDescriptor, for event: Event) -> (stream: PipeIOSignalStream, outcome: RegistrationOutcome) {
        // `.bufferingNewest(1)` latches a readiness edge that fires while no consumer is awaiting, so a wakeup is never dropped between a read's `EAGAIN` and its `await`.
        let (stream, continuation) = PipeIOSignalStream.makeStream(bufferingPolicy: .bufferingNewest(1))

        switch self.state {
        case .failure(let setupError):
            continuation.finish(throwing: setupError)
            return (stream, .failed(setupError))
        case .success(let state):
            if let error = self.prepare(fileDescriptor, for: event) {
                continuation.finish(throwing: error)
                return (stream, .failed(error))
            }
            let filter: Int16
            switch event {
            case .read:
                filter = Int16(EVFILT_READ)
            case .write:
                filter = Int16(EVFILT_WRITE)
            }

            // Hold the lock across the map insert and `kevent` so that the monitor thread cannot observe a half-registered descriptor.
            let outcome: RegistrationOutcome = _registration.withLock { storage in
                switch storage.register(fileDescriptor.rawValue, continuation: continuation) {
                case .updated:
                    // Already attached to kqueue by a previous read or write; reuse the existing registration and skip the syscall.
                    return .registered
                case .registered:
                    // `EV_CLEAR` makes the filter edge-triggered: an event is delivered only when new data arrives, so a persistent registration doesn't spin the monitor thread while buffered bytes sit unread between reads.
                    var kev = _makeKevent(ident: UInt(fileDescriptor.rawValue), filter: filter, flags: UInt16(EV_ADD | EV_CLEAR))
                    let rc = _kevent(state.kqueueFileDescriptor, &kev, 1, nil, 0, nil)
                    if rc != 0 {
                        let capturedError = errno
                        _ = storage.removeRegistration(for: fileDescriptor.rawValue)
                        return .failed(PipeIOError("failed to add \(fileDescriptor.rawValue) to kqueue", underlyingError: Errno(rawValue: capturedError)))
                    }
                    return .registered
                }
            }

            if case .failed(let error) = outcome {
                continuation.finish(throwing: error)
            }
            return (stream, outcome)
        }
    }

    func removeRegistration(for fileDescriptor: FileDescriptor) {
        let continuation = _registration.withLock { store -> PipeIORegistration<CInt, Bool>.Continuation? in
            guard let continuation = store.removeRegistration(for: fileDescriptor.rawValue) else {
                return nil
            }

            if case .success(let state) = self.state {
                for filter in [EVFILT_READ, EVFILT_WRITE] {
                    var kev = _makeKevent(ident: UInt(fileDescriptor.rawValue), filter: Int16(filter), flags: UInt16(EV_DELETE))
                    _ = _kevent(state.kqueueFileDescriptor, &kev, 1, nil, 0, nil)
                }
            }
            return continuation
        }
        continuation?.finish()
    }
}

#endif
