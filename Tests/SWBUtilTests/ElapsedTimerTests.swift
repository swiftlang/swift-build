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
import SWBUtil
import Testing
import SWBTestSupport

@Suite fileprivate struct ElapsedTimerTests {
    @Test(.skipHostOS(.freebsd, "Currently hangs on FreeBSD"))
    func time() async throws {
        do {
            let clock = MockClock()
            let delta = try await ElapsedTimer.measure(clock: clock) {
                try await clock.sleep(for: .microseconds(1001))
                return ()
            }
            #expect(delta.seconds > 1.0 / 1000.0)
        }

        do {
            let clock = MockClock()
            let (delta, result) = try await ElapsedTimer.measure(clock: clock) { () -> Int in
                try await clock.sleep(for: .microseconds(1001))
                return 22
            }
            #expect(delta.seconds > 1.0 / 1000.0)
            #expect(result == 22)
        }
    }
}
