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

#if os(Windows)
import WinSDK
#endif

#if canImport(System)
import System
#else
import SystemPackage
#endif

import SWBLibc

@Suite
fileprivate struct ServiceConsoleTests {
    @Test
    func emptyInput() async throws {
        // Test against a non-pty.
        let task = SWBUtil.Process()
        task.executableURL = try CLIConnection.swiftbuildToolURL
        task.environment = .init(CLIConnection.environment)

        task.standardInput = FileHandle.nullDevice
        try await withExtendedLifetime(Pipe()) { outputPipe in
            let standardOutput = task._makeStream(for: \.standardOutputPipe, using: outputPipe)
            let promise: Promise<Processes.ExitStatus, any Error> = try task.launch()

            let data = try await standardOutput.reduce(into: [], { $0.append(contentsOf: $1) })
            let output = String(decoding: data, as: UTF8.self)

            // Verify there were no errors.
            #expect(output == "swbuild> \(String.newline)")

            // Assert the tool exited successfully.
            await #expect(try promise.value == .exit(0))
        }
    }

    @Test
    func commandLineArguments() async throws {
        // Test against command line arguments.
        let executionResult = try await Process.getOutput(url: try CLIConnection.swiftbuildToolURL, arguments: ["isAlive"], environment: CLIConnection.environment)

        let output = String(decoding: executionResult.stdout, as: UTF8.self)

        // Verify there were no errors.
        #expect(output == "is alive? yes\(String.newline)")

        // Assert the tool exited successfully.
        #expect(executionResult.exitStatus == .exit(0))
    }

    /// Test that the build service shuts down if the host dies.
    @Test(.skipHostOS(.windows, "PTY not supported on Windows"))
    func serviceShutdown() async throws {
        try await withCLIConnection { cli in
            // Find the service pid.
            try cli.send(command: "dumpPID")
            var reply = try await cli.getResponse()
            let servicePID = try {
                var servicePID = pid_t(-1)
                for line in reply.components(separatedBy: "\n") {
                    if let match = try #/service pid = (?<pid>\d+)/#.firstMatch(in: line) {
                        servicePID = try #require(pid_t(match.output.pid))
                    }
                }
                #expect(servicePID != -1, "unable to find service PID")
                return servicePID
            }()
            #expect(servicePID != cli.processIdentifier, "service PID (\(servicePID)) must not match the CLI PID (\(cli.processIdentifier)) when running in out-of-process mode")

            // Make sure the service has started.
            try cli.send(command: "isAlive")
            reply = try await cli.getResponse()
            #expect(reply.contains("is alive? yes"))

            let serviceExitPromise = try Processes.exitPromise(pid: servicePID)

            // Now terminate the 'swbuild' tool (host process)
            try cli.terminate()

            // Wait for it to exit.
            await #expect(try cli.exitStatus != .exit(0))
            await #expect(try cli.exitStatus.wasSignaled)

            // Now wait for the service subprocess to exit, without any further communication.
            try await withTimeout(timeout: .seconds(30), description: "Service process exit promise 30-second limit") {
                try await withTaskCancellationHandler {
                    try await serviceExitPromise.value
                } onCancel: {
                    serviceExitPromise.fail(throwing: CancellationError())
                }
            }
        }
    }

    /// Tests that the serializedDiagnostics console command is able to print human-readable serialized diagnostics from a .dia file.
    @Test(.skipHostOS(.windows, "PTY not supported on Windows"))
    func dumpSerializedDiagnostics() async throws {
        // Generate and compile a C source file that will generate a compiler warning.
        try await withTemporaryDirectory { tmp in
            let diagnosticsPath = tmp.join("foo.dia")
            let sourceFilePath = tmp.join("foo.c")
            try localFS.write(sourceFilePath, contents: "int main() { int foo; *foo = \"string\"; return 0; }")
            _ = try? await runHostProcess(["clang", "-serialize-diagnostics", diagnosticsPath.str, sourceFilePath.str])

            // Run the `serializedDiagnostics --dump` command on the .dia file generated by the compiler.
            try await withCLIConnection { cli in
                try cli.send(command: "serializedDiagnostics --dump \(diagnosticsPath.str)")

                // Verify that all the attributes of the diagnostic were printed (file path, line, column, range info, message, etc.).
                let reply = try await cli.getResponse()
                #expect(reply.contains("foo.c:1:23: [1:24-1:27]: error: [Semantic Issue] indirection requires pointer operand ('int' invalid)"), Comment(rawValue: reply))
            }
        }
    }
}

#if os(Windows)
private var SYNCHRONIZE: DWORD {
    DWORD(WinSDK.SYNCHRONIZE)
}

extension HANDLE: @retroactive @unchecked Sendable {}

func WaitForSingleObjectAsync(_ handle: HANDLE) async throws {
    var waitHandle: HANDLE?
    defer {
        if let waitHandle {
            _ = UnregisterWait(waitHandle)
        }
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        if !RegisterWaitForSingleObject(
            &waitHandle,
            handle,
            { context, _ in
                let continuation = Unmanaged<AnyObject>.fromOpaque(context!).takeRetainedValue() as! CheckedContinuation<Void, any Error>
                continuation.resume()
            },
            Unmanaged.passRetained(continuation as AnyObject).toOpaque(),
            INFINITE,
            ULONG(WT_EXECUTEONLYONCE | WT_EXECUTELONGFUNCTION)
        ) {
            continuation.resume(throwing: Win32Error(GetLastError()))
        }
    }
}
#endif

extension Processes {
    fileprivate static func exitPromise(pid: pid_t) throws -> Promise<Void, any Error> {
        let promise = Promise<Void, any Error>()
        #if os(Windows)
        guard let proc: HANDLE = OpenProcess(SYNCHRONIZE, false, DWORD(pid)) else {
            throw Win32Error(GetLastError())
        }
        defer { CloseHandle(proc) }
        Task<Void, Never> {
            await promise.fulfill(with: Result.catching { try await WaitForSingleObjectAsync(proc) })
        }
        #else
        Task<Void, Never> {
            func wait(pid: pid_t) throws -> Bool {
                repeat {
                    do {
                        var siginfo = siginfo_t()
                        if waitid(P_PID, id_t(pid), &siginfo, WEXITED | WNOWAIT | WNOHANG) != 0 {
                            throw Errno(rawValue: errno)
                        }
                        return siginfo.si_pid == pid
                    } catch Errno.noChildProcess {
                        return true
                    } catch Errno.interrupted {
                        // ignore
                    }
                } while true
            }
            while !Task.isCancelled {
                do {
                    if try wait(pid: pid) {
                        promise.fulfill(with: ())
                        return
                    }
                    try await Task.sleep(for: .microseconds(1000))
                } catch {
                    promise.fail(throwing: error)
                    return
                }
            }
            promise.fail(throwing: CancellationError())
        }
        #endif
        return promise
    }
}

#if !os(Windows) && !canImport(Darwin) && !os(FreeBSD)
fileprivate extension siginfo_t {
    var si_pid: pid_t {
        #if os(OpenBSD)
        return _data._proc._pid
        #elseif canImport(Glibc)
        return _sifields._sigchld.si_pid
        #elseif canImport(Musl)
        return __si_fields.__si_common.__first.__piduid.si_pid
        #elseif canImport(Bionic)
        return _sifields._kill._pid
        #endif
    }
}
#endif
