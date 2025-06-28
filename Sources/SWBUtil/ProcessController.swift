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

public import Foundation

#if canImport(Subprocess)
import Subprocess
#endif

import Synchronization

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

public final class ProcessController: Sendable {
    public let path: Path
    public let arguments: [String]
    public let environment: Environment?
    public let workingDirectory: Path?
    private let state = SWBMutex<State>(.unstarted)
    private let done = WaitCondition()

    private struct RunningState {
        var task: Task<Void, Never>
        var pid: pid_t?
    }

    private enum State {
        case unstarted
        case running(_ runningState: RunningState)
        case exited(exitStatus: Result<Processes.ExitStatus, any Error>)
    }

    public init(path: Path, arguments: [String], environment: Environment?, workingDirectory: Path?) {
        self.path = path
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    public func start(input: FileDescriptor, output: FileDescriptor, error: FileDescriptor, highPriority: Bool) {
        state.withLock { state in
            guard case .unstarted = state else {
                fatalError("API misuse: process was already started")
            }

            func updateState(processIdentifier pid: pid_t?) {
                self.state.withLock { state in
                    guard case var .running(runningState) = state, runningState.pid == nil else {
                        preconditionFailure() // unreachable
                    }
                    runningState.pid = pid
                    state = .running(runningState)
                }
            }

            let task = Task<Void, Never>.detached { [path, arguments, environment, workingDirectory, done] in
                defer { done.signal() }
                let result = await Result.catching {
                    #if !canImport(Darwin) || os(macOS)
                    #if canImport(Subprocess)
                    var platformOptions = PlatformOptions()
                    platformOptions.teardownSequence = [.gracefulShutDown(allowedDurationToNextStep: .seconds(5))]
                    #if os(macOS)
                    if highPriority {
                        platformOptions.qualityOfService = .userInitiated
                    }
                    #endif
                    return try await Processes.ExitStatus(Subprocess.run(.path(FilePath(path.str)), arguments: .init(arguments), environment: environment.map { .custom([String: String]($0)) } ?? .inherit, workingDirectory: (workingDirectory?.str).map { FilePath($0) } ?? nil, platformOptions: platformOptions, input: .fileDescriptor(input, closeAfterSpawningProcess: false), output: .fileDescriptor(output, closeAfterSpawningProcess: false), error: .fileDescriptor(error, closeAfterSpawningProcess: false), body: { execution in
                        updateState(processIdentifier: execution.processIdentifier.value)
                    }).terminationStatus)
                    #else
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path.str)
                    process.arguments = arguments
                    process.environment = environment.map { .init($0) } ?? nil
                    if let workingDirectory {
                        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory.str)
                    }
                    if highPriority {
                        process.qualityOfService = .userInitiated
                    }
                    process.standardInput = FileHandle(fileDescriptor: input.rawValue, closeOnDealloc: false)
                    process.standardOutput = FileHandle(fileDescriptor: output.rawValue, closeOnDealloc: false)
                    process.standardError = FileHandle(fileDescriptor: error.rawValue, closeOnDealloc: false)
                    try await process.run {
                        updateState(processIdentifier: process.processIdentifier)
                    }
                    return try Processes.ExitStatus(process)
                    #endif
                    #else
                    throw StubError.error("Process spawning is unavailable")
                    #endif
                }

                self.state.withLock { state in
                    switch state {
                    case .unstarted, .running:
                        state = .exited(exitStatus: result)
                    case .exited:
                        preconditionFailure() // unreachable
                    }
                }
            }

            state = .running(.init(task: task))
        }
    }

    public func waitUntilExit() async {
        await done.wait()
    }

    public func terminate() {
        state.withLock { state in
            if case let .running(state) = state {
                state.task.cancel()
            }
        }
    }

    public var processIdentifier: pid_t? {
        get {
            state.withLock { state in
                switch state {
                case .unstarted, .exited:
                    nil
                case let .running(state):
                    state.pid
                }
            }
        }
    }

    public var exitStatus: Processes.ExitStatus? {
        get throws {
            try state.withLock { state in
                switch state {
                case .unstarted:
                    nil
                case .running:
                    nil
                case let .exited(exitStatus):
                    try exitStatus.get()
                }
            }
        }
    }
}

extension RunProcessNonZeroExitError {
    public init?(_ process: ProcessController) throws {
        self.args = [process.path.str] + process.arguments
        self.workingDirectory = process.workingDirectory
        self.environment = process.environment ?? .init()
        guard let exitStatus = try process.exitStatus else {
            return nil
        }
        self.status = exitStatus
        self.output = nil
        if self.status.isSuccess {
            return nil
        }
    }
}
