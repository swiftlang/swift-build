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
package import Testing

private let asyncMeasureLock = AsyncLockedValue<Void>(())

package protocol PerfTests {
    func measure(subiterations: Int, _ body: () async throws -> Void) async rethrows
}

extension PerfTests {
    package func measure(subiterations: Int = 1, _ body: () async throws -> Void) async rethrows {
        let iterationCount = getEnvironmentVariable("CI")?.boolValue == true ? 1 : 10
        let time = try await asyncMeasureLock.withLock { _ in
            var timings: [Duration] = []
            for _ in 0..<iterationCount {
                for _ in 0..<subiterations {
                    try await timings.append(SuspendingClock.suspending.measure {
                        try await body()
                    })
                }
            }
            return timings.reduce(Duration.seconds(0), { $0 + ($1 / Double(timings.count)) }) // average
        }
        _ = time
    }
}

extension Trait where Self == Testing.ConditionTrait {
    package static var performance: Self {
        disabled("Skipping performance test") {
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
    }
}

// Used to make printing for debugging purposes easier.
private let shouldPrint = getEnvironmentVariable("SWB_PERF_TESTS_ENABLE_DEBUG_PRINT")?.boolValue ?? false

public func perfPrint(_ message: String) {
    if shouldPrint {
        print(message)
    }
}
