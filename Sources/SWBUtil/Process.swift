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
import SWBLibc

#if os(Windows)
public typealias pid_t = Int32
#endif

#if !canImport(Darwin)
extension ProcessInfo {
    public var isMacCatalystApp: Bool {
        false
    }
}
#endif

#if (!canImport(Foundation.NSTask) || targetEnvironment(macCatalyst)) && canImport(Darwin)
public final class Process {
    public enum TerminationReason: Int {
        case exit = 1
        case uncaughtSignal = 2
    }

    public var currentDirectoryURL: URL?
    public var executableURL: URL?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var processIdentifier: Int32 { -1 }
    public var standardError: Any?
    public var standardInput: Any?
    public var standardOutput: Any?
    public var isRunning: Bool { false }
    public var terminationStatus: Int32 { -1 }
    public var terminationReason: TerminationReason { .exit }
    public var terminationHandler: ((Process) -> Void)?
    public var qualityOfService: QualityOfService = .default

    public init() {
    }

    public func terminate() {
    }

    public func waitUntilExit() {
    }

    public func run() throws {
        throw StubError.error("Process spawning is unavailable")
    }
}
#else
public typealias Process = Foundation.Process
#endif

extension Process {
    public static func getOutput(url: URL, arguments: [String], currentDirectoryURL: URL? = nil, environment: Environment? = nil, interruptible: Bool = true) async throws -> Processes.ExecutionResult {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            // Extend the lifetime of the pipes to avoid file descriptors being closed until the AsyncStream is finished being consumed.
            return try await withExtendedLifetime((Pipe(), Pipe())) { (stdoutPipe, stderrPipe) in
                let (exitStatus, output) = try await _getOutput(url: url, arguments: arguments, currentDirectoryURL: currentDirectoryURL, environment: environment, interruptible: interruptible) { process in
                    let stdoutStream = process.makeStream(for: \.standardOutputPipe, using: stdoutPipe)
                    let stderrStream = process.makeStream(for: \.standardErrorPipe, using: stderrPipe)
                    return (stdoutStream, stderrStream)
                } collect: { (stdoutStream, stderrStream) in
                    let stdoutData = try await stdoutStream.collect()
                    let stderrData = try await stderrStream.collect()
                    return (stdoutData: stdoutData, stderrData: stderrData)
                }
                return Processes.ExecutionResult(exitStatus: exitStatus, stdout: Data(output.stdoutData), stderr: Data(output.stderrData))
            }
        } else {
            // Extend the lifetime of the pipes to avoid file descriptors being closed until the AsyncStream is finished being consumed.
            return try await withExtendedLifetime((Pipe(), Pipe())) { (stdoutPipe, stderrPipe) in
                let (exitStatus, output) = try await _getOutput(url: url, arguments: arguments, currentDirectoryURL: currentDirectoryURL, environment: environment, interruptible: interruptible) { process in
                    let stdoutStream = process._makeStream(for: \.standardOutputPipe, using: stdoutPipe)
                    let stderrStream = process._makeStream(for: \.standardErrorPipe, using: stderrPipe)
                    return (stdoutStream, stderrStream)
                } collect: { (stdoutStream, stderrStream) in
                    let stdoutData = try await stdoutStream.collect()
                    let stderrData = try await stderrStream.collect()
                    return (stdoutData: stdoutData, stderrData: stderrData)
                }
                return Processes.ExecutionResult(exitStatus: exitStatus, stdout: Data(output.stdoutData), stderr: Data(output.stderrData))
            }
        }
    }

    public static func getMergedOutput(url: URL, arguments: [String], currentDirectoryURL: URL? = nil, environment: Environment? = nil, interruptible: Bool = true) async throws -> (exitStatus: Processes.ExitStatus, output: Data) {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
            // Extend the lifetime of the pipe to avoid file descriptors being closed until the AsyncStream is finished being consumed.
            return try await withExtendedLifetime(Pipe()) { pipe in
                let (exitStatus, output) = try await _getOutput(url: url, arguments: arguments, currentDirectoryURL: currentDirectoryURL, environment: environment, interruptible: interruptible) { process in
                    process.standardOutputPipe = pipe
                    process.standardErrorPipe = pipe
                    return pipe.fileHandleForReading.bytes(on: .global())
                } collect: { stream in
                    try await stream.collect()
                }
                return (exitStatus: exitStatus, output: Data(output))
            }
        } else {
            // Extend the lifetime of the pipe to avoid file descriptors being closed until the AsyncStream is finished being consumed.
            return try await withExtendedLifetime(Pipe()) { pipe in
                let (exitStatus, output) = try await _getOutput(url: url, arguments: arguments, currentDirectoryURL: currentDirectoryURL, environment: environment, interruptible: interruptible) { process in
                    process.standardOutputPipe = pipe
                    process.standardErrorPipe = pipe
                    return pipe.fileHandleForReading._bytes(on: .global())
                } collect: { stream in
                    try await stream.collect()
                }
                return (exitStatus: exitStatus, output: Data(output))
            }
        }
    }

    private static func _getOutput<T, U>(url: URL, arguments: [String], currentDirectoryURL: URL?, environment: Environment?, interruptible: Bool, setup: (Process) -> T, collect: (T) async throws -> U) async throws -> (exitStatus: Processes.ExitStatus, output: U) {
        if !url.isFileURL {
            throw StubError.error("\(url) is not an absolute file URL")
        }
        let executableFilePath = try url.standardizedFileURL.filePath
        if try !localFS.isExecutable(executableFilePath) {
            throw StubError.error("\(executableFilePath.str) is not an executable file")
        }
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }
        process.environment = environment.map { .init($0) } ?? nil

        let streams = setup(process)

        try await process.run(interruptible: interruptible)

        let output = try await collect(streams)

        #if !canImport(Darwin)
        // Clear the pipes to prevent file descriptor leaks on platforms using swift-corelibs-foundation
        // This asserts on Darwin
        process.standardOutputPipe = nil
        process.standardErrorPipe = nil
        #endif

        return try (.init(process), output)
    }

    public static func run(url: URL, arguments: [String], currentDirectoryURL: URL? = nil, environment: Environment? = nil, interruptible: Bool = true) async throws -> Processes.ExitStatus {
        try await getOutput(url: url, arguments: arguments, currentDirectoryURL: currentDirectoryURL, environment: environment, interruptible: interruptible).exitStatus
    }
}

/// Utilities for working with processes.
//
// NOTE: This is currently just a namespace. We would like to use Process, but it conflicts with one from the Swift stdlib.
public enum Processes: Sendable {
    /// Captures the execution result of a process, including its exit status, and standard output and standard error data.
    public struct ExecutionResult: Sendable {
        public let exitStatus: ExitStatus
        public let stdout: Data
        public let stderr: Data

        public init(exitStatus: ExitStatus, stdout: Data, stderr: Data) {
            self.exitStatus = exitStatus
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public enum ExitStatus: Hashable, Equatable, Sendable {
        case exit(_ code: Int32)
        case uncaughtSignal(_ signal: Int32)

        public init?(rawValue: Int32) {
            #if os(Windows)
            let dwExitCode = DWORD(bitPattern: rawValue)
            // Do the same thing as swift-corelibs-foundation (the input value is the GetExitCodeProcess return value)
            if (dwExitCode & 0xF0000000) == 0x80000000     // HRESULT
                || (dwExitCode & 0xF0000000) == 0xC0000000 // NTSTATUS
                || (dwExitCode & 0xF0000000) == 0xE0000000 // NTSTATUS (Customer)
                || dwExitCode == 3 {
                self = .uncaughtSignal(Int32(dwExitCode & 0x3FFFFFFF))
            } else {
                self = .exit(Int32(bitPattern: UInt32(dwExitCode)))
            }
            #else
            func WSTOPSIG(_ status: Int32) -> Int32 {
                return status >> 8
            }

            func WIFCONTINUED(_ status: Int32) -> Bool {
                return _WSTATUS(status) == 0x7f && WSTOPSIG(status) == 0x13
            }

            func WIFSTOPPED(_ status: Int32) -> Bool {
                return _WSTATUS(status) == 0x7f && WSTOPSIG(status) != 0x13
            }

            func WIFEXITED(_ status: Int32) -> Bool {
                return _WSTATUS(status) == 0
            }

            func _WSTATUS(_ status: Int32) -> Int32 {
                return status & 0x7f
            }

            func WIFSIGNALED(_ status: Int32) -> Bool {
                return (_WSTATUS(status) != 0) && (_WSTATUS(status) != 0x7f)
            }

            func WEXITSTATUS(_ status: Int32) -> Int32 {
                return (status >> 8) & 0xff
            }

            func WTERMSIG(_ status: Int32) -> Int32 {
                return status & 0x7f
            }

            if WIFSIGNALED(rawValue) {
                self = .uncaughtSignal(WTERMSIG(rawValue))
            } else if WIFEXITED(rawValue) {
                self = .exit(WEXITSTATUS(rawValue))
            } else {
                assert(WIFCONTINUED(rawValue) || WIFSTOPPED(rawValue))
                return nil
            }
            #endif
        }

        public var isSuccess: Bool {
            switch self {
            case let .exit(exitStatus):
                return exitStatus == 0
            case .uncaughtSignal:
                return false
            }
        }

        public var wasSignaled: Bool {
            switch self {
            case .exit:
                return false
            case .uncaughtSignal:
                return true
            }
        }

        /// Returns whether the exit status represents a POSIX signal number corresponding to user-initiated cancellation of a process (SIGINT or SIGKILL).
        public var wasCanceled: Bool {
            switch self {
            case .exit:
                return false
            case let .uncaughtSignal(signal):
                #if os(Windows)
                // Windows doesn't support the concept of signals, so just always return false for now.
                return false
                #else
                return signal == SIGINT || signal == SIGKILL
                #endif
            }
        }
    }
}

extension Processes.ExitStatus {
    public init(_ process: Process) throws {
        assert(!process.isRunning)
        switch process.terminationReason {
        case .exit:
            self = .exit(process.terminationStatus)
        case .uncaughtSignal:
            self = .uncaughtSignal(process.terminationStatus)
#if canImport(Foundation.NSTask) || !canImport(Darwin)
        @unknown default:
            throw StubError.error("Process terminated with unknown termination reason value: \(process.terminationReason)")
#endif
        }
    }
}

extension Processes.ExitStatus: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .exit(status):
            return "exited with status \(status)"
        case let .uncaughtSignal(signal):
            return "terminated with uncaught signal \(signal)"
        }
    }
}

public struct RunProcessNonZeroExitError: Error {
    public let args: [String]
    public let workingDirectory: String?
    public let environment: Environment
    public let status: Processes.ExitStatus

    public enum Output: Sendable {
        case separate(stdout: ByteString, stderr: ByteString)
        case merged(ByteString)
    }

    public let output: Output?

    public init(args: [String], workingDirectory: String?, environment: Environment, status: Processes.ExitStatus, mergedOutput: ByteString) {
        self.init(args: args, workingDirectory: workingDirectory, environment: environment, status: status, output: .merged(mergedOutput))
    }

    public init(args: [String], workingDirectory: String?, environment: Environment, status: Processes.ExitStatus, stdout: ByteString, stderr: ByteString) {
        self.init(args: args, workingDirectory: workingDirectory, environment: environment, status: status, output: .separate(stdout: stdout, stderr: stderr))
    }

    public init(args: [String], workingDirectory: String?, environment: Environment, status: Processes.ExitStatus, output: Output) {
        self.args = args
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.status = status
        self.output = output
    }

    public init?(_ process: Process) throws {
        self.args = ((process.executableURL?.path).map { [$0] } ?? []) + (process.arguments ?? [])
        self.workingDirectory = process.currentDirectoryURL?.path
        self.environment = process.environment.map { .init($0) } ?? .init()
        self.status = try .init(process)
        self.output = nil
        if self.status.isSuccess {
            return nil
        }
    }
}

extension RunProcessNonZeroExitError: CustomStringConvertible, LocalizedError {
    public var description: String {
        let fullArgs: [String]
        if !environment.isEmpty {
            fullArgs = ["env"] + [String: String](environment).sorted(byKey: <).map { key, value in "\(key)=\(value)" } + args
        } else {
            fullArgs = args
        }

        let commandString = UNIXShellCommandCodec(encodingStrategy: .singleQuotes, encodingBehavior: .fullCommandLine).encode(fullArgs)
        let fullCommandString: String
        if let workingDirectory {
            let directoryCommandString = UNIXShellCommandCodec(encodingStrategy: .singleQuotes, encodingBehavior: .fullCommandLine).encode(["cd", workingDirectory])
            fullCommandString = "(\([directoryCommandString, commandString].joined(separator: " && ")))"
        } else {
            fullCommandString = commandString
        }

        let message = "The command `\(fullCommandString)` \(status)."
        switch output {
        case let .separate(stdout, stderr) where !stdout.isEmpty || !stderr.isEmpty:
            return message + [
                !stdout.isEmpty ? " The command's standard output was:\n\n\(stdout.asString)" : nil,
                !stderr.isEmpty ? " The command's standard error was:\n\n\(stderr.asString)" : nil,
            ].compactMap { $0 }.joined(separator: "\n\n")
        case let .merged(output) where !output.isEmpty:
            return message + " The command's output was:\n\n\(output.asString)"
        default:
            return message + " The command had no output."
        }
    }

    public var errorDescription: String? {
        return description
    }
}
