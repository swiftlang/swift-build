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

public import struct Foundation.TimeInterval

/// Provides a simple nanosecond-precision elapsed timer using a monotonic clock.
///
/// This is a completely immutable object and thus is thread safe.
public struct ElapsedTimer: Sendable {
    /// The beginning of the time interval, measured when the `ElapsedTimer` was initialized.
    private let start = ContinuousClock.now

    /// Initializes a new timer.
    ///
    /// The `ElapsedTimer` object captures the current time at initialization and uses this as the starting point of an elapsed time measurement.
    ///
    /// - note: The starting point of the timer is fixed once it is initialized and the object provides no facilities to "restart" the clock (simply create a new instance to do so).
    public init() {
    }

    /// Computes the length of the time interval, that is, the length of the time interval between now and the point in time when the `ElapsedTimer` was initialized.
    ///
    /// This value is guaranteed to be positive.
    public func elapsedTime() -> ElapsedTimerInterval {
        return ElapsedTimerInterval(duration: ContinuousClock.now - start)
    }

    /// Time the given closure, returning the elapsed time and the result.
    public static func measure<T>(_ body: () throws -> T) rethrows -> (elapsedTime: ElapsedTimerInterval, result: T) {
        let timer = ElapsedTimer()
        let result = try body()
        return (timer.elapsedTime(), result)
    }

    /// Time the given closure, returning the elapsed time and the result.
    public static func measure<T>(_ body: () async throws -> T) async rethrows -> (elapsedTime: ElapsedTimerInterval, result: T) {
        let timer = ElapsedTimer()
        let result = try await body()
        return (timer.elapsedTime(), result)
    }

    /// Time the given closure, returning the elapsed time.
    public static func measure(_ body: () throws -> Void) rethrows -> ElapsedTimerInterval {
        return try measure(body).elapsedTime
    }

    /// Time the given closure, returning the elapsed time.
    public static func measure(_ body: () async throws -> Void) async rethrows -> ElapsedTimerInterval {
        return try await measure(body).elapsedTime
    }
}

/// Represents the length of the time interval measured by an `ElapsedTimer` with nanosecond precision.
public struct ElapsedTimerInterval: Hashable, Sendable {
    public let duration: Duration

    fileprivate init(duration: Duration) {
        precondition(duration.components.seconds >= 0 && duration.components.attoseconds >= 0, "Duration must be positive")
        self.duration = duration
    }

    public var nanoseconds: UInt64 {
        UInt64(duration.nanoseconds) // always positive
    }

    public var microseconds: UInt64 {
        UInt64(duration.microseconds) // always positive
    }

    public var seconds: TimeInterval {
        duration.seconds
    }
}
