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
import SWBTestSupport
@_spi(Testing) import SWBUtil
import SWBCore
import SWBLibc
import SwiftBuild

#if os(Windows)
import WinSDK
#if canImport(System)
import System
#else
import SystemPackage
#endif
#endif

/// Helper class for talking to 'swbuild' the tool
final class CLIConnection {
    private let task: SWBUtil.Process
    private let monitorHandle: FileHandle
    private let temporaryDirectory: NamedTemporaryDirectory
    private let exitPromise: Promise<Processes.ExitStatus, any Error>
    private let outputStream: AsyncThrowingStream<UInt8, any Error>
    private var outputStreamIterator: AsyncCLIConnectionResponseSequence<AsyncThrowingStream<UInt8, any Error>>.AsyncIterator

    static var swiftbuildToolSearchPaths: [URL] {
        var searchPaths: [URL] = []

        // The main bundle (which may be a test host)'s executables directory.
        if let executablesURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            searchPaths.append(executablesURL)
        }

        let bundle = Bundle.module
        if bundle.bundleURL.deletingLastPathComponent().lastPathComponent == "PlugIns" {
            searchPaths.append(contentsOf: [
                // Next to this class's .xctest bundle's parent app's executable (e.g. test-hosted path) - iOS / shallow bundle
                bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent(),

                // Next to this class's .xctest bundle's parent app's executable (e.g. test-hosted path) - macOS / deep bundle
                bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MacOS"),
            ])
        }

        // Up from this class's .xctest bundle (e.g. flat BUILT_PRODUCTS_DIR-relative path)
        searchPaths.append(bundle.bundleURL.deletingLastPathComponent())

        if let url = Bundle(for: SWBBuildService.self).executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("Support") {
            searchPaths.append(url)
        }

        #if SWIFT_PACKAGE
        // Add the parent directory of the bundle containing the build service (the package build directory)
        searchPaths.append(Bundle(for: SWBBuildService.self).bundleURL.deletingLastPathComponent())
        #endif

        return searchPaths
    }

    static var swiftbuildToolURL: URL {
        get throws {
            let searchPath = try StackedSearchPath(paths: swiftbuildToolSearchPaths.map { try $0.filePath }, fs: localFS)
            let os = try ProcessInfo.processInfo.hostOperatingSystem()
            guard let toolPath = searchPath.findExecutable(operatingSystem: os, basename: "swbuild") else {
                throw StubError.error("Could not lookup path to `swbuild`. Search paths: \(searchPath.paths)")
            }
            return URL(fileURLWithPath: toolPath.str)
        }
    }

    static var environment: Environment {
        var env = Environment.current.filter(keys: [
            "PATH", // important to allow swift to be looked up in PATH on Windows/Linux
            "DEVELOPER_DIR",
            "DYLD_FRAMEWORK_PATH",
            "DYLD_LIBRARY_PATH",
            "LLVM_PROFILE_FILE",
            "MallocNanoZone"
        ]).addingContents(of: Environment([
            // Prevent locally-enabled MSL from failing several tests because MSL prints messages to standard output streams.
            "EnableMallocStackLoggingLiteOnStart": "0"
        ]))
        // For Windows when running in an IDE like VS Code
        if env[.path] == nil, let swiftRuntimePath = try? swiftRuntimePath() {
            env[.path] = swiftRuntimePath.str
        }
        // Required to be set for Process.run to function
        if env["SystemRoot"] == nil, let systemRoot = try? systemRoot() {
            env["SystemRoot"] = systemRoot.str
        }
        return env
    }

    fileprivate init(currentDirectory: Path? = nil) async throws {
        #if os(Windows)
        throw StubError.error("PTY not supported on Windows")
        #else
        temporaryDirectory = try NamedTemporaryDirectory()

        // Allocate a PTY we can use to talk to the tool.
        var monitorFD = Int32(0)
        var sessionFD = Int32(0)
        if openpty(&monitorFD, &sessionFD, nil, nil, nil) != 0 {
            throw POSIXError(errno, context: "openpty")
        }
        _ = fcntl(monitorFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(sessionFD, F_SETFD, FD_CLOEXEC)

        monitorHandle = FileHandle(fileDescriptor: monitorFD, closeOnDealloc: true)
        let sessionHandle = FileHandle(fileDescriptor: sessionFD, closeOnDealloc: true)

        // Launch the tool.
        task = Process()
        task.executableURL = try CLIConnection.swiftbuildToolURL
        task.currentDirectoryURL = URL(fileURLWithPath: (currentDirectory ?? temporaryDirectory.path).str)
        task.standardInput = sessionHandle
        task.standardOutput = sessionHandle
        task.standardError = sessionHandle
        task.environment = .init(Self.environment)
        do {
            exitPromise = try task.launch()
        } catch {
            throw StubError.error("Failed to launch the CLI connection: \(error)")
        }

        // Close the session handle, so the FD will close once the service stops.
        try sessionHandle.close()

        outputStream = monitorHandle._bytes(on: .global())
        outputStreamIterator = outputStream.cliResponses.makeAsyncIterator()
        #endif
    }

    func shutdown() async {
        // If the task is still running, ensure orderly shutdown.
        if task.isRunning {
            try? send(command: "quit")
            _ = try? await getResponse()
            _ = try? await exitStatus
        }

        // Consume the rest of the output before closing the handle to ensure the dispatch IO is closed
        while let _ = try? await outputStreamIterator.next() {
        }

        try? monitorHandle.close()
    }

    func terminate() throws {
        try Self.terminate(processIdentifier: processIdentifier)
    }

    static func terminate(processIdentifier: Int32) throws {
        #if os(Windows)
        guard let proc = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(processIdentifier)) else {
            throw Win32Error(GetLastError())
        }
        defer { CloseHandle(proc) }
        if !TerminateProcess(proc, UINT(0xC0000000 | DWORD(9))) {
            throw Win32Error(GetLastError())
        }
        #else
        if SWBLibc.kill(processIdentifier, SIGKILL) != 0 {
            throw POSIXError(errno, context: "kill", String(processIdentifier), String(SIGKILL))
        }
        #endif
    }

    func send(command: String) throws {
        #if !os(Windows)
        // Give readline a chance to disable the terminal echo attribute by
        // waiting for a few ms. This works around a non-deterministic issue
        // where the user input may be echoed back to the terminal twice on
        // occasion, prompting test failures <rdar://51241102>.
        usleep(10)
        #endif
        try monitorHandle.write(contentsOf: Data(command.appending("\n").utf8))
    }

    func getResponse() async throws -> String {
        try await outputStreamIterator.next() ?? ""
    }

    var processIdentifier: Int32 {
        task.processIdentifier
    }

    var exitStatus: Processes.ExitStatus {
        get async throws {
            try await exitPromise.value
        }
    }
}

func withCLIConnection(currentDirectory: Path? = nil, _ body: sending (borrowing CLIConnection) async throws -> Void) async throws {
    try await withTimeout(timeout: .seconds(1200), description: "CLI connection 20-minute limit") {
        let connection = try await CLIConnection(currentDirectory: currentDirectory)
        let processIdentifier = connection.processIdentifier
        try await withTaskCancellationHandler {
            // Wait for the session to be ready.
            _ = try await connection.getResponse()
            let result = await Result.catching({ try await body(connection) })
            await connection.shutdown()
            return try result.get()
        } onCancel: {
            try? CLIConnection.terminate(processIdentifier: processIdentifier)
        }
    }
}

public struct AsyncCLIConnectionResponseSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = String

    var base: Base

    public struct AsyncIterator: AsyncIteratorProtocol {
        var _base: Base.AsyncIterator

        internal init(underlyingIterator: Base.AsyncIterator) {
            _base = underlyingIterator
        }

        public mutating func next() async throws -> Element? {
            if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
                return try await next(isolation: nil)
            } else {
                // Read until we see the CLI print the prompt. This is fragile, but works ok in practice so far.
                let prompt = Array("swbuild> ".utf8)
                var reply = [UInt8]()
                while !reply.hasSuffix(prompt) {
                    do {
                        if let byte = try await _base.next() {
                            reply.append(byte)
                        } else if reply.isEmpty {
                            return nil
                        } else {
                            break
                        }
                    } catch let error as SWBUtil.POSIXError {
                        // The result of a read operation when pty session is closed is platform-dependent.
                        // BSDs send EOF, Linux raises EIO...
                        #if os(Linux) || os(Android)
                        if error.code == EIO {
                            break
                        }
                        #endif
                        throw error
                    }
                }
                return String(decoding: reply, as: UTF8.self)
            }
        }

        @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
        public mutating func next(isolation actor: isolated (any Actor)?) async throws(any Error) -> String? {
            // Read until we see the CLI print the prompt. This is fragile, but works ok in practice so far.
            let prompt = Array("swbuild> ".utf8)
            var reply = [UInt8]()
            while !reply.hasSuffix(prompt) {
                do {
                    if let byte = try await _base.next(isolation: actor) {
                        reply.append(byte)
                    } else if reply.isEmpty {
                        return nil
                    } else {
                        break
                    }
                } catch let error as SWBUtil.POSIXError {
                    // The result of a read operation when pty session is closed is platform-dependent.
                    // BSDs send EOF, Linux raises EIO...
                    #if os(Linux) || os(Android)
                    if error.code == EIO {
                        break
                    }
                    #endif
                    throw error
                }
            }
            return String(decoding: reply, as: UTF8.self)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(underlyingIterator: base.makeAsyncIterator())
    }

    internal init(underlyingSequence: Base) {
        base = underlyingSequence
    }
}

extension AsyncSequence where Self.Element == UInt8 {
    public var cliResponses: AsyncCLIConnectionResponseSequence<Self> {
        AsyncCLIConnectionResponseSequence(underlyingSequence: self)
    }
}

extension AsyncCLIConnectionResponseSequence: Sendable where Base: Sendable { }

@available(*, unavailable)
extension AsyncCLIConnectionResponseSequence.AsyncIterator: Sendable { }

fileprivate func swiftRuntimePath() throws -> Path? {
    #if os(Windows)
    let name = "swiftCore.dll"
    return try name.withCString(encodedAs: CInterop.PlatformUnicodeEncoding.self) { wName in
        guard let handle = GetModuleHandleW(wName) else {
            throw Win32Error(GetLastError())
        }
        return try Path(SWB_GetModuleFileNameW(handle)).dirname
    }
    #else
    return nil
    #endif
}

fileprivate func systemRoot() throws -> Path? {
    #if os(Windows)
    let dwLength: DWORD = GetWindowsDirectoryW(nil, 0)
    if dwLength == 0 {
        throw Win32Error(GetLastError())
    }
    return try withUnsafeTemporaryAllocation(of: WCHAR.self, capacity: Int(dwLength)) {
        switch GetWindowsDirectoryW($0.baseAddress!, DWORD($0.count)) {
        case 1..<dwLength:
            return Path(String(decodingCString: $0.baseAddress!, as: CInterop.PlatformUnicodeEncoding.self))
        case 0:
            throw Win32Error(GetLastError())
        default:
            throw Win32Error(DWORD(ERROR_INSUFFICIENT_BUFFER))
        }
    }
    #else
    return nil
    #endif
}
