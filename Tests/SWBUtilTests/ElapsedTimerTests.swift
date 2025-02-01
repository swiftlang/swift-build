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

@Suite fileprivate struct ElapsedTimerTests {
    @Test
    func time() async throws {
        do {
            let delta = try await ElapsedTimer.measure {
                try await Task.sleep(for: .microseconds(1000))
                return ()
            }
            #expect(delta.seconds > 1.0 / 1000.0)
        }

        do {
            let (delta, result) = try await ElapsedTimer.measure { () -> Int in
                try await Task.sleep(for: .microseconds(1000))
                return 22
            }
            #expect(delta.seconds > 1.0 / 1000.0)
            #expect(result == 22)
        }
    }
}
