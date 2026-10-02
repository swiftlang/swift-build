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

// DEBUG ONLY: launch a child that sleeps, then wait for it. While waiting, this
// process should be idle; on an affected system Foundation's process manager
// thread spins.

import Foundation

let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/sleep")
process.arguments = [CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "30"]
try process.run()
process.waitUntilExit()
print("idle-process: child exited with \(process.terminationStatus)")
