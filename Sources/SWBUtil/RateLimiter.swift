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

/// Provides a simple utility for implementing rate-limiting mechanisms.
///
/// This object is NOT thread-safe.
public struct RateLimiter<ClockType: Clock>: ~Copyable {
    private let clock: ClockType
    private let start: ClockType.Instant
    private var last: ClockType.Instant

    /// The length of the time interval to which updates are rate-limited.
    public let interval: ClockType.Duration

    public init(interval: ClockType.Duration, clock: ClockType = ContinuousClock.continuous) {
        self.clock = clock
        let now = clock.now
        self.interval = interval
        self.start = now
        self.last = now
    }

    /// Returns a value indicating whether the delta between now and the last
    /// time this function returned `true`, is greater than the time interval
    /// with which this object was initialized.
    public mutating func hasNextIntervalPassed() -> Bool {
        let now = clock.now
        let elapsed = last.duration(to: now)
        if elapsed >= interval {
            last = now
            return true
        }
        return false
    }
}

@available(*, unavailable)
extension RateLimiter: Sendable { }
