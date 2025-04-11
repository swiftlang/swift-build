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

import Foundation
import Testing
import SWBTestSupport
import SWBUtil
import SWBCore

@Suite(.requireProcessSpawning)
fileprivate struct ProcessTests {
    @Test
    func output() async throws {
        let result = try await Process.getShellOutput("echo hello")
        #expect(result.exitStatus == .exit(0))
        #expect(result.stdout == Data(("hello" + .newline).utf8))
        #expect(result.stderr == Data())
    }

    @Test
    func outputRedirectingStderr() async throws {
        let result = try await Process.getMergedShellOutput { host in
            host == .windows ? "echo stdout & echo stderr 1>&2" : "echo stdout; echo stderr 1>&2"
        }
        #expect(result.exitStatus == .exit(0))
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            #expect(result.output == Data("stdout \r\nstderr \r\n".utf8))
        } else {
            #expect(result.output == Data("stdout\nstderr\n".utf8))
        }
    }

    @Test
    func outputNotRedirectingStderr() async throws {
        let result = try await Process.getShellOutput("echo stderr 1>&2")
        #expect(result.exitStatus == .exit(0))
        #expect(result.stdout == Data())
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            #expect(result.stderr == Data("stderr \r\n".utf8))
        } else {
            #expect(result.stderr == Data("stderr\n".utf8))
        }
    }

    @Test(.requireThreadSafeWorkingDirectory)
    func workingDirectory() async throws {
        let previous = Path.currentDirectory.str

        let (_, output1, _) = try await Process.getShellOutput({ host in host == .windows ? "echo %CD%" : "echo $PWD" }, currentDirectoryURL: nil)
        #expect(String(decoding: output1, as: UTF8.self) == previous + .newline)

        try await withTemporaryDirectory { dir in
            let (_, output2, _) = try await Process.getShellOutput({ host in host == .windows ? "echo %CD%" : "echo $PWD" }, currentDirectoryURL: URL(fileURLWithPath: dir.str))
            #expect(String(decoding: output2, as: UTF8.self) == dir.str + .newline)

            let (_, output3) = try await Process.getMergedShellOutput({ host in host == .windows ? "echo %CD%" : "echo $PWD" }, currentDirectoryURL: URL(fileURLWithPath: dir.str))
            #expect(String(decoding: output3, as: UTF8.self) == dir.str + .newline)
        }

        let (_, output3, _) = try await Process.getShellOutput({ host in host == .windows ? "echo %CD%" : "echo $PWD" }, currentDirectoryURL: nil)
        #expect(String(decoding: output3, as: UTF8.self) == previous + .newline)

        // Failing on Windows due to https://github.com/apple/swift-corelibs-foundation/issues/5071
#if !os(Windows)
        let (_, output4, _) = try await Process.getShellOutput({ host in host == .windows ? "echo %CD%" : "echo $PWD" }, currentDirectoryURL: URL(fileURLWithPath: Path.root.str))
        #expect(String(decoding: output4, as: UTF8.self) == Path.root.str + .newline)
#endif

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    if i % 2 == 0 {
                        let (_, output3, _) = try await Process.getShellOutput({ host in host == .windows ? "echo %CD%" : "echo $PWD" }, currentDirectoryURL: nil)
                        #expect(String(decoding: output3, as: UTF8.self) == previous + .newline)
                    } else {
                        // Failing on Windows due to https://github.com/apple/swift-corelibs-foundation/issues/5071
#if !os(Windows)
                        let (_, output4, _) = try await Process.getShellOutput({ host in host == .windows ? "echo %CD%" : "echo $PWD" }, currentDirectoryURL: URL(fileURLWithPath: Path.root.str))
                        #expect(String(decoding: output4, as: UTF8.self) == Path.root.str + .newline)
#endif
                    }
                }
            }
            try await group.waitForAll()
        }

        let current = Path.currentDirectory.str
        #expect(previous == current)
    }

    @Test
    func exitCode() async throws {
        let result = try await Process.getShellOutput { host in
            host == .windows ? "exit /b 42" : "exit 42"
        }
        #expect(result.exitStatus == .exit(42))
    }

    @Test(.enabled(if: StackedSearchPath(environment: .current, fs: localFS).lookup(Path("clang")) != nil, "requires clang in PATH"))
    func uncaughtSignal() async throws {
        try await withTemporaryDirectory { tmpDir in
            let mainCPath = tmpDir.join("main.c").str
            let exePath = tmpDir.join("exe").str
            let source =
            """
            #ifdef _WIN32
            #include <windows.h>
            #include <processthreadsapi.h>
            #else
            #include <sys/types.h>
            #include <signal.h>
            #include <unistd.h>
            #endif
            int main() {
                #ifdef _WIN32
                TerminateProcess(GetCurrentProcess(), 0xC0000009); // STATUS_BAD_INITIAL_STACK
                #else
                kill(getpid(), SIGKILL);
                #endif
                return 0;
            }
            """
            try source.write(to: URL(fileURLWithPath: mainCPath), atomically: true, encoding: .utf8)
            let _ = try await runHostProcess(["clang", "-o", exePath, mainCPath])

            do {
                let result = try await Process.getOutput(url: URL(fileURLWithPath: exePath), arguments: [])
                #expect(result.exitStatus == .uncaughtSignal(9))
            }

            do {
                let result = try await Process.getOutput(url: URL(fileURLWithPath: exePath), arguments: [])
                #expect(result.exitStatus != .exit(0))
            }
        }
    }

    @Test
    func exitStatus() throws {
#if !os(Windows)
        #expect(Processes.ExitStatus(rawValue: -2) == .uncaughtSignal(126))
        #expect(Processes.ExitStatus(rawValue: -1) == nil)
        #expect(Processes.ExitStatus(rawValue: 0) == .exit(0))
        #expect(Processes.ExitStatus(rawValue: 1) == .uncaughtSignal(SIGHUP))

        #expect(Processes.ExitStatus(rawValue: 126) == .uncaughtSignal(126))
        #expect(Processes.ExitStatus(rawValue: 127) == nil)
        #expect(Processes.ExitStatus(rawValue: 128) == .exit(0))

        // POSIX
        #expect(Processes.ExitStatus(rawValue: 129) == .uncaughtSignal(SIGHUP))    // 1
        #expect(Processes.ExitStatus(rawValue: 130) == .uncaughtSignal(SIGINT))    // 2
        #expect(Processes.ExitStatus(rawValue: 131) == .uncaughtSignal(SIGQUIT))   // 3
        #expect(Processes.ExitStatus(rawValue: 132) == .uncaughtSignal(SIGILL))    // 4
        #expect(Processes.ExitStatus(rawValue: 133) == .uncaughtSignal(SIGTRAP))   // 5
        #expect(Processes.ExitStatus(rawValue: 134) == .uncaughtSignal(SIGABRT))   // 6; aka SIGIOT
        #expect(Processes.ExitStatus(rawValue: 136) == .uncaughtSignal(SIGFPE))    // 8
        #expect(Processes.ExitStatus(rawValue: 137) == .uncaughtSignal(SIGKILL))   // 9
        #expect(Processes.ExitStatus(rawValue: 139) == .uncaughtSignal(SIGSEGV))   // 11
        #expect(Processes.ExitStatus(rawValue: 141) == .uncaughtSignal(SIGPIPE))   // 13
        #expect(Processes.ExitStatus(rawValue: 142) == .uncaughtSignal(SIGALRM))   // 14
        #expect(Processes.ExitStatus(rawValue: 143) == .uncaughtSignal(SIGTERM))   // 15

        #expect(Processes.ExitStatus(rawValue: 160) == .uncaughtSignal(32))

        #expect(Processes.ExitStatus(rawValue: 254) == .uncaughtSignal(126))
        #expect(Processes.ExitStatus(rawValue: 255) == nil)
        #expect(Processes.ExitStatus(rawValue: 256) == .exit(1))
        #expect(Processes.ExitStatus(rawValue: 257) == .uncaughtSignal(1))

        #expect(Processes.ExitStatus(rawValue: 510) == .uncaughtSignal(126))
        #expect(Processes.ExitStatus(rawValue: 511) == nil)
        #expect(Processes.ExitStatus(rawValue: 512) == .exit(2))
        #expect(Processes.ExitStatus(rawValue: 513) == .uncaughtSignal(1))

        #expect(Processes.ExitStatus(rawValue: 766) == .uncaughtSignal(126))
        #expect(Processes.ExitStatus(rawValue: 767) == nil)
        #expect(Processes.ExitStatus(rawValue: 768) == .exit(3))
        #expect(Processes.ExitStatus(rawValue: 769) == .uncaughtSignal(1))

        #expect(Processes.ExitStatus(rawValue: 1022) == .uncaughtSignal(126))
        #expect(Processes.ExitStatus(rawValue: 1023) == nil)
        #expect(Processes.ExitStatus(rawValue: 1024) == .exit(4))
        #expect(Processes.ExitStatus(rawValue: 1025) == .uncaughtSignal(1))

        #expect(Processes.ExitStatus(rawValue: 65278) == .uncaughtSignal(126))
        #expect(Processes.ExitStatus(rawValue: 65279) == nil)
        #expect(Processes.ExitStatus(rawValue: 65280) == .exit(255))
        #expect(Processes.ExitStatus(rawValue: 65281) == .uncaughtSignal(1))
#endif
    }
}

extension SWBUtil.Process {
    fileprivate static func getMergedShellOutput(_ script: String, currentDirectoryURL: URL? = nil) async throws -> (exitStatus: Processes.ExitStatus, output: Data) {
        try await getMergedShellOutput({ _ in script }, currentDirectoryURL: currentDirectoryURL)
    }

    fileprivate static func getShellOutput(_ script: String, currentDirectoryURL: URL? = nil) async throws -> (exitStatus: Processes.ExitStatus, stdout: Data, stderr: Data) {
        try await getShellOutput({ _ in script }, currentDirectoryURL: currentDirectoryURL)
    }

    fileprivate static func getMergedShellOutput(_ script: (_ hostOS: OperatingSystem) async throws -> String, currentDirectoryURL: URL? = nil) async throws -> (exitStatus: Processes.ExitStatus, output: Data) {
        let (commandShellPath, arguments) = try await _shellAndArgs(script)
        return try await getMergedOutput(url: URL(fileURLWithPath: commandShellPath), arguments: arguments, currentDirectoryURL: currentDirectoryURL)
    }

    fileprivate static func getShellOutput(_ script: (_ hostOS: OperatingSystem) async throws -> String, currentDirectoryURL: URL? = nil) async throws -> (exitStatus: Processes.ExitStatus, stdout: Data, stderr: Data) {
        let (commandShellPath, arguments) = try await _shellAndArgs(script)
        let executionResult = try await getOutput(url: URL(fileURLWithPath: commandShellPath), arguments: arguments, currentDirectoryURL: currentDirectoryURL)
        return (executionResult.exitStatus, executionResult.stdout, executionResult.stderr)
    }

    fileprivate static func _shellAndArgs(_ script: (_ hostOS: OperatingSystem) async throws -> String) async throws -> (String, [String]) {
        let commandShellPath: String
        let arguments: [String]
        let hostOS = try ProcessInfo.processInfo.hostOperatingSystem()
        let scriptString = try await script(hostOS)
        if hostOS == .windows {
            commandShellPath = try #require(getEnvironmentVariable("ComSpec"), "Can't determine path to cmd.exe because the ComSpec environment variable is not set")
            arguments = ["/c", scriptString]
        } else {
            commandShellPath = "/bin/sh"
            arguments = ["-c", scriptString]
        }
        return (commandShellPath, arguments)
    }
}
