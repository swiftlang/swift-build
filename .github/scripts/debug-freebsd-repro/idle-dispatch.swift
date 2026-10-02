//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

// DEBUG ONLY: a 1 second repeating dispatch timer under dispatchMain(). This
// process should be idle between ticks; on an affected system the libdispatch
// manager thread spins.

import Dispatch
import Foundation

let seconds = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 30 : 30
var ticks = 0
let timer = DispatchSource.makeTimerSource(queue: .global())
timer.schedule(deadline: .now() + 1, repeating: 1)
timer.setEventHandler {
    ticks += 1
    if ticks >= seconds {
        print("idle-dispatch: \(ticks) ticks")
        exit(0)
    }
}
timer.resume()
dispatchMain()
