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

public import SWBUtil

/// `TaskResult` represents the result of either a command or a command process.
public enum TaskResult: Hashable, Sendable {
    /// The task ran and exited with the given status
    case exit(exitStatus: Processes.ExitStatus, metrics: CommandMetrics?)

    /// The task could not run due to a set up failure like missing inputs
    case failedSetup

    /// The task got skipped by the build engine
    case skipped

    public static func succeeded(metrics: CommandMetrics? = nil) -> TaskResult {
        .exit(exitStatus: .exit(0), metrics: metrics)
    }

    public var isSuccess: Bool {
        switch self {
        case .exit(let exitStatus, _):
            return exitStatus.isSuccess
        case .failedSetup:
            return false
        case .skipped:
            return true
        }
    }

    public var isCancelled: Bool {
        switch self {
        case .exit(let exitStatus, _):
            return exitStatus.wasCanceled
        case .failedSetup:
            return false
        case .skipped:
            return false
        }
    }

    public var metrics: CommandMetrics? {
        guard case let .exit(_, metrics) = self else {
            return nil
        }
        return metrics
    }

}

public extension Optional where Wrapped == TaskResult {
    /// Indicates that a task failed in a way that parsers reading diagnostics should be skipped.
    ///
    /// **NOTE**: This applies to crashed or cancelled tasks
    var shouldSkipParsingDiagnostics: Bool {
        switch self {
        case .exit(exitStatus: let status, metrics: _):
            return status.wasCanceled
        case .skipped: return false
        case .failedSetup, nil: return true
        }
    }
}

public struct CommandMetrics: Hashable, Sendable {
    public let utime: UInt64         /// User time (in μs)
    public let stime: UInt64         /// Sys time (in μs)
    public let maxRSS: UInt64        /// Max RSS (in bytes)
    public let wcDuration: ElapsedTimerInterval? /// Wall time duration (in μs).

    public init(utime: UInt64, stime: UInt64, maxRSS: UInt64, wcDuration: ElapsedTimerInterval?) {
        self.utime = utime
        self.stime = stime
        self.maxRSS = maxRSS
        self.wcDuration = wcDuration
    }
}
