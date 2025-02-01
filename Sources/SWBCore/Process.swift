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

import SWBLibc
public import enum SWBUtil.Processes

extension Processes.ExitStatus {
    /// Represents a canceled task as an interrupt signal.
    /// Matches llbuild's LaneBasedExecutionEngine when canceling outstanding tasks.
    public static var buildSystemCanceledTask: Self {
        .uncaughtSignal(SIGINT)
    }
}
