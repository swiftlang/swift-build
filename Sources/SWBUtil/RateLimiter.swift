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
public struct RateLimiter: ~Copyable {
    private let start: ContinuousClock.Instant
    private var last: ContinuousClock.Instant

    /// The length of the time interval to which updates are rate-limited.
    public let interval: Duration

    public init(interval: Duration) {
        let now = ContinuousClock.now
        self.interval = interval
        self.start = now
        self.last = now
    }

    /// Returns a value indicating whether the delta between now and the last
    /// time this function returned `true`, is greater than the time interval
    /// with which this object was initialized.
    public mutating func hasNextIntervalPassed() -> Bool {
        let now = ContinuousClock.now
        let elapsed = now - last
        if elapsed >= interval {
            last = now
            return true
        }
        return false
    }
}

@available(*, unavailable)
extension RateLimiter: Sendable { }
