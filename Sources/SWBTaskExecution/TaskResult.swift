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

package import SWBCore
import SWBUtil
package import SWBLLBuild

extension TaskResult {
    package init(_ result: CommandExtendedResult) {
        guard let exitStatus = Processes.ExitStatus(rawValue: result.exitStatus) else {
            self = .failedSetup
            return
        }

        self = .exit(exitStatus: exitStatus, metrics: result.metrics.map { .init($0, wcDuration: nil) })
    }
}

extension SWBCore.CommandMetrics {
    init(_ metrics: SWBLLBuild.CommandMetrics, wcDuration: ElapsedTimerInterval?) {
        self.init(utime: metrics.utime, stime: metrics.stime, maxRSS: metrics.maxRSS, wcDuration: wcDuration)
    }
}
