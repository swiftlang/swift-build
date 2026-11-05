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

#if os(Linux) || os(Android)

#if canImport(System)
import System
#else
import SystemPackage
#endif

import Foundation
import SWBLibc
import Synchronization

private let _EPOLLET: UInt32 = 1 << 31

#if canImport(Glibc)
private let _EPOLLIN = EPOLLIN.rawValue
private let _EPOLLOUT = EPOLLOUT.rawValue
#else
private let _EPOLLIN = UInt32(EPOLLIN)
private let _EPOLLOUT = UInt32(EPOLLOUT)
#endif

private let _epollEventSize = 256
private let _registration = SWBMutex(PipeIORegistration<CInt, Bool>())

final class PipeIOBackend: Sendable {
    private struct State: Sendable {
        let epollFileDescriptor: CInt
    }

    static let shared = PipeIOBackend()

    private let state: Result<State, PipeIOError>

    private init() {
        let epollFileDescriptor = epoll_create1(CInt(EPOLL_CLOEXEC))
        guard epollFileDescriptor >= 0 else {
            self.state = .failure(PipeIOError("epoll_create1 failed", underlyingError: Errno(rawValue: errno)))
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

            var events: [epoll_event] = Array(repeating: epoll_event(events: 0, data: epoll_data(fd: 0)), count: _epollEventSize)

            monitorLoop: while true {
                let eventCount = epoll_wait(epollFileDescriptor, &events, CInt(events.count), -1)
                if eventCount < 0 {
                    if errno == EINTR || errno == EAGAIN {
                        continue // Interrupted by a signal; try again.
                    }
                    reportError(PipeIOError("epoll_wait failed", underlyingError: Errno(rawValue: errno)))
                    break monitorLoop
                }

                for index in 0..<Int(eventCount) {
                    let targetFileDescriptor = events[index].data.fd
                    let continuation = _registration.withLock { store in
                        return store.continuation(for: targetFileDescriptor)
                    }
                    continuation?.yield(true)
                }
            }
        }
        thread.name = "org.swift.swift-build.PipeIO"
        thread.start()

        self.state = .success(State(epollFileDescriptor: epollFileDescriptor))
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
            let targetEvent: UInt32
            switch event {
            case .read:
                targetEvent = _EPOLLIN
            case .write:
                targetEvent = _EPOLLOUT
            }

            // Hold the lock across both the map insert and `epoll_ctl` so that the monitor thread cannot observe a half-registered descriptor.
            let outcome: RegistrationOutcome = _registration.withLock { storage in
                switch storage.register(fileDescriptor.rawValue, continuation: continuation) {
                case .updated:
                    // Already attached to epoll by a previous read or write; reuse the existing registration and skip the syscall.
                    return .registered
                case .registered:
                    // Register edge-triggered (`EPOLLET`): with a persistent registration, `epoll_wait` must report the descriptor only when new data arrives, otherwise the monitor thread would spin while buffered bytes sit unread between reads.
                    var event = epoll_event(events: targetEvent | _EPOLLET, data: epoll_data(fd: fileDescriptor.rawValue))
                    let rc = epoll_ctl(state.epollFileDescriptor, EPOLL_CTL_ADD, fileDescriptor.rawValue, &event)
                    if rc != 0 {
                        let capturedError = errno
                        _ = storage.removeRegistration(for: fileDescriptor.rawValue)
                        return .failed(PipeIOError("failed to add \(fileDescriptor.rawValue) to epoll list", underlyingError: Errno(rawValue: capturedError)))
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
                _ = epoll_ctl(state.epollFileDescriptor, EPOLL_CTL_DEL, fileDescriptor.rawValue, nil)
            }
            return continuation
        }
        continuation?.finish()
    }
}

#endif
