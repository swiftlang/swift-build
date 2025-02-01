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

extension Process {
    /// Type-safe accessor for `standardOutput`.
    public var standardOutputPipe: Pipe? {
        get { standardOutput as? Pipe }
        set { standardOutput = newValue }
    }

    /// Type-safe accessor for `standardError`.
    public var standardErrorPipe: Pipe? {
        get { standardError as? Pipe }
        set { standardError = newValue }
    }
}

extension Process {
    /// Returns an ``AsyncStream`` configured to read the standard output or error stream of the process.
    ///
    /// - note: This method will mutate the `standardOutput` or `standardError` property of the Process object, replacing any existing `Pipe` or `FileHandle` which may be set. It must be called before the process is started.
    @available(macOS, deprecated: 15.0, message: "Use the AsyncSequence-returning overload.")
    @available(iOS, deprecated: 18.0, message: "Use the AsyncSequence-returning overload.")
    @available(tvOS, deprecated: 18.0, message: "Use the AsyncSequence-returning overload.")
    @available(watchOS, deprecated: 11.0, message: "Use the AsyncSequence-returning overload.")
    @available(visionOS, deprecated: 2.0, message: "Use the AsyncSequence-returning overload.")
    public func _makeStream(for keyPath: ReferenceWritableKeyPath<Process, Pipe?>, using pipe: Pipe) -> AsyncThrowingStream<UInt8, any Error> {
        precondition(!isRunning) // the pipe setters will raise `NSInvalidArgumentException` anyways
        self[keyPath: keyPath] = pipe
        return pipe.fileHandleForReading._bytes(on: .global())
    }

    /// Returns an ``AsyncStream`` configured to read the standard output or error stream of the process.
    ///
    /// - note: This method will mutate the `standardOutput` or `standardError` property of the Process object, replacing any existing `Pipe` or `FileHandle` which may be set. It must be called before the process is started.
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public func makeStream(for keyPath: ReferenceWritableKeyPath<Process, Pipe?>, using pipe: Pipe) -> any AsyncSequence<UInt8, any Error> {
        precondition(!isRunning) // the pipe setters will raise `NSInvalidArgumentException` anyways
        self[keyPath: keyPath] = pipe
        return pipe.fileHandleForReading.bytes(on: .global())
    }
}

extension Process {
    /// Runs the process and returns a promise which is fulfilled when the process exits.
    ///
    /// - note: This method sets the process's termination handler, if one is set.
    /// - throws: Rethrows the error from ``Process/run`` if the task could not be launched.
    public func launch() throws -> Promise<Processes.ExitStatus, any Error> {
        let promise = Promise<Processes.ExitStatus, any Error>()

        terminationHandler = { process in
            do {
                promise.fulfill(with: try .init(process))
            } catch {
                promise.fail(throwing: error)
            }
        }

        do {
            try run()
        } catch {
            terminationHandler = nil

            // If `run` throws, the terminationHandler won't be called.
            throw error
        }

        return promise
    }
}


extension Process {
    /// Runs the process and suspends until completion.
    ///
    /// - parameter interruptible: Whether the process should respond to task cancellation. If `true`, task cancellation will cause `SIGTERM` to be sent to the process if it starts running by the time the task is cancelled. If `false`, the process will always run to completion regardless of the task's cancellation status.
    ///
    /// - note: This method sets the process's termination handler, if one is set.
    /// - throws: ``CancellationError`` if the task was cancelled. Applies only when `interruptible` is true.
    /// - throws: Rethrows the error from ``Process/run`` if the task could not be launched.
    public func run(interruptible: Bool = true) async throws {
        @Sendable func cancelIfRunning() {
            // Only send the termination signal if the process is already running.
            // We might have created the termination monitoring continuation at this
            // point but not yet completed run(), and terminate() will raise an
            // Objective-C exception if the process has not yet started.
            if interruptible && isRunning {
                terminate()
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                terminationHandler = { _ in
                    continuation.resume()
                }

                do {
                    // Check for cancellation -- if we entered the cancellation
                    // handler before the process actually started, and therefore
                    // didn't call terminate(), don't actually start it.
                    if interruptible {
                        try Task.checkCancellation()
                    }

                    try run()
                } catch {
                    terminationHandler = nil

                    // If `run` throws, the terminationHandler won't be called,
                    // so resume the continuation with this error.
                    continuation.resume(throwing: error)
                }

                if Task.isCancelled {
                    cancelIfRunning()
                }
            }

            // Check for cancellation -- if terminate() was called, the termination
            // handler will have resumed the previous continuation without throwing
            // an error; this distinguishes cooperative cancellation from successful
            // execution of the task to completion (even if that task otherwise exited
            // with a non-zero exit code or terminated due to an uncaught signal).
            if interruptible {
                try Task.checkCancellation()
            }
        } onCancel: {
            cancelIfRunning()
        }
    }
}
