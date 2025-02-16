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

package import Foundation

package enum ConcurrencyPoolDeadlockWatchdog {
    package static func start(threshold: TimeInterval) {
        Thread.detachNewThread {
            Thread.current.name = "concurrency-pool-deadlock-watchdog"
            while true {
                let task = Task { throw CancellationError() }
                Thread.sleep(forTimeInterval: threshold)
                guard task.isCancelled else {
                    abort()
                    fatalError("Concurrency pool deadlock watchdog triggered")
                }
            }
        }
    }
}
