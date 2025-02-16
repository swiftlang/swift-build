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
    package static func start(threshold: TimeInterval, swiftInspectPath: Path?) {
        Thread.detachNewThread {
            Thread.current.name = "concurrency-pool-deadlock-watchdog"
            while true {
                let task = Task { throw CancellationError() }
                Thread.sleep(forTimeInterval: threshold)
                guard task.isCancelled else {
                    if let swiftInspectPath {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: swiftInspectPath.str)
                        process.arguments = ["dump-concurrency", "\(ProcessInfo.processInfo.processIdentifier)"]
                        try! process.run()
                        process.waitUntilExit()
                    }
                    fatalError("Concurrency pool deadlock watchdog triggered")
                }
            }
        }
    }
}
