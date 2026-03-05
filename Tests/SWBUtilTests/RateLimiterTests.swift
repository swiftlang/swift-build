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

import Foundation
import Testing
import SWBUtil
import SWBTestSupport

@Suite(.skipHostOS(.freebsd, "Currently hangs on FreeBSD"))
fileprivate struct RateLimiterTests {
    @Test
    func rateLimiterSeconds() async throws {
        let clock = MockClock()
        let timer = ElapsedTimer(clock: clock)
        var limiter = RateLimiter(interval: .seconds(1), clock: clock)
        #expect(limiter.interval == .nanoseconds(1_000_000_000))

        var count = 0
        for _ in 0..<3 {
            if limiter.hasNextIntervalPassed() {
                count += 1
            }
            try await clock.sleep(for: .seconds(1))
        }

        #expect(count > 1)
        #expect(TimeInterval(count) < timer.elapsedTime().seconds)
    }

    @Test
    func rateLimiterTwoSeconds() async throws {
        let clock = MockClock()
        let timer = ElapsedTimer(clock: clock)
        var limiter = RateLimiter(interval: .seconds(2), clock: clock)
        #expect(limiter.interval == .nanoseconds(2_000_000_000))

        var count = 0
        for _ in 0..<3 {
            if limiter.hasNextIntervalPassed() {
                count += 1
            }
            try await clock.sleep(for: .seconds(1))
        }

        #expect(count > 0)
        #expect(TimeInterval(count) < timer.elapsedTime().seconds)
    }

    @Test
    func rateLimiterMilliseconds() async throws {
        let clock = MockClock()
        let timer = ElapsedTimer(clock: clock)
        var limiter = RateLimiter(interval: .milliseconds(100), clock: clock)
        #expect(limiter.interval == .nanoseconds(100_000_000))

        var count = 0
        for _ in 0..<101 {
            if limiter.hasNextIntervalPassed() {
                count += 1
            }
            try await clock.sleep(for: .microseconds(2001))
        }

        #expect(count > 1)
        #expect(TimeInterval(count) < TimeInterval(timer.elapsedTime().seconds * 10))
    }

    @Test
    func rateLimiterMicroseconds() async throws {
        let clock = MockClock()
        let timer = ElapsedTimer(clock: clock)
        var limiter = RateLimiter(interval: .microseconds(100000), clock: clock)
        #expect(limiter.interval == .nanoseconds(100_000_000))

        var count = 0
        for _ in 0..<101 {
            if limiter.hasNextIntervalPassed() {
                count += 1
            }
            try await clock.sleep(for: .microseconds(1001))
        }

        #expect(count > 0)
        #expect(TimeInterval(count) < TimeInterval(timer.elapsedTime().seconds * 10))
    }

    @Test
    func rateLimiterNanoseconds() async throws {
        let clock = MockClock()
        let timer = ElapsedTimer(clock: clock)
        var limiter = RateLimiter(interval: .nanoseconds(100_000_000), clock: clock)
        #expect(limiter.interval == .nanoseconds(100_000_000))

        var count = 0
        for _ in 0..<101 {
            if limiter.hasNextIntervalPassed() {
                count += 1
            }
            try await clock.sleep(for: .microseconds(1001))
        }

        #expect(count > 0)
        #expect(TimeInterval(count) < TimeInterval(timer.elapsedTime().seconds * 10))
    }

    @Test
    func rateLimiterNoCrashNever() async throws {
        let clock = MockClock()
        var limiter = RateLimiter(interval: .nanoseconds(UInt64.max), clock: clock)

        for _ in 0..<2 {
            let nextIntervalPassed = limiter.hasNextIntervalPassed()
            #expect(!nextIntervalPassed)
            try await clock.sleep(for: .seconds(1))
        }
    }
}
