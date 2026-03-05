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

import SWBUtil
import Synchronization

/// A mock clock whose current time is controllable.
public struct MockClock: Clock {
    public typealias Instant = ContinuousClock.Instant

    private final class State: Sendable {
        let now: SWBMutex<Instant>

        init(now: Instant) {
            self.now = .init(now)
        }
    }

    private let state: State

    public init(now: Instant = .now) {
        self.state = .init(now: now)
    }

    public var now: Instant {
        state.now.withLock({ $0 })
    }

    public var minimumResolution: Duration {
        ContinuousClock.continuous.minimumResolution
    }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        state.now.withLock { now in
            if now < deadline {
                now = deadline
            }
        }
    }
}
