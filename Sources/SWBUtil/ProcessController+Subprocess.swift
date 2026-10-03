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

// This lives in its own file, separate from ProcessController.swift, because on
// non-Darwin platforms Subprocess declares public `pid_t`, `uid_t`, and `gid_t`
// type aliases which shadow the C library's. In a file that imports Subprocess,
// `pid_t` therefore refers to `Subprocess.pid_t`, which can't appear in public
// API since Subprocess is imported internally.

#if canImport(Subprocess) && (!canImport(Darwin) || os(macOS))
import Foundation
import Subprocess

#if canImport(System)
import System
#else
import SystemPackage
#endif

extension ProcessController {
    /// Runs the process to completion using swift-subprocess.
    /// - parameter onStarted: Called with the process identifier once the process has started running.
    static func runUsingSubprocess(path: Path, arguments: [String], environment: Environment?, workingDirectory: Path?, input: FileDescriptor, output: FileDescriptor, error: FileDescriptor, highPriority: Bool, onStarted: (_ processIdentifier: Int) -> Void) async throws -> Processes.ExitStatus {
        var platformOptions = PlatformOptions()
        platformOptions.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(5))]
        #if os(macOS)
        if highPriority {
            platformOptions.qualityOfService = .userInitiated
        }
        #endif
        let configuration = Subprocess.Configuration(
            executable: .path(FilePath(path.str)),
            arguments: .init(arguments),
            environment: environment.map { .custom(.init($0)) } ?? .inherit,
            workingDirectory: (workingDirectory?.str).map { FilePath($0) },
            platformOptions: platformOptions
        )
        return try await Processes.ExitStatus(Subprocess.run(configuration, input: .fileDescriptor(input, closeAfterSpawningProcess: false), output: .fileDescriptor(output, closeAfterSpawningProcess: false), error: .fileDescriptor(error, closeAfterSpawningProcess: false), body: { execution in
            onStarted(numericCast(execution.processIdentifier.value))
        }).terminationStatus)
    }
}
#endif
