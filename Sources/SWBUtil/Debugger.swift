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
import SWBLibc

public enum Debugger: Sendable {
    public static func pause() {
        #if os(Windows)
        DebugActiveProcess(GetCurrentProcessId())
        #else
        raise(SIGSTOP)
        #endif
    }

    public static func resume() {
        #if os(Windows)
        DebugActiveProcessStop(GetCurrentProcessId())
        #else
        raise(SIGCONT)
        #endif
    }

    public static func isAttached() throws -> Bool {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) != 0 {
            throw POSIXError(errno, context: "sysctl")
        }
        return (info.kp_proc.p_flag & P_TRACED) != 0
        #else
        throw StubError.error("Debugger detection is not supported on this platform")
        #endif
    }

    public static func waitForAttachment(_ condition: @escaping () throws -> Bool = { true }) async throws {
        var attached = try isAttached()
        while !attached {
            try await Task.sleep(for: .seconds(0.1))
            guard try condition() else {
                return
            }
            attached = try isAttached()
        }
    }

    public static var isXcodeAutoAttachEnabled: Bool {
        return ProcessInfo.processInfo.environment["IB_AUTO_ATTACH_ENABLED"]?.boolValue == true
    }

    public static func waitForXcodeAutoAttachIfEnabled() async throws {
        #if canImport(Darwin)
        if isXcodeAutoAttachEnabled {
            try await waitForAttachment() {
                // Exit if parent process died while waiting for debugger
                if kill(getppid(), 0) != 0 {
                    throw StubError.error("Parent process exited while waiting for debugger")
                }
                return true
            }
        }
        #else
        throw StubError.error("Debugger detection is not supported on this platform")
        #endif
    }

    public static func requestXcodeAutoAttachIfEnabled(_ remoteToolPID: Int32) throws {
        #if canImport(Darwin)
        if isXcodeAutoAttachEnabled, let sendPipeName = ProcessInfo.processInfo.environment["IB_AUTO_ATTACH_PIPE_NAME"] {
            let returnPipeName = "/tmp/Xcode.IBCTTAutoAttachPipe.Return.\(getpid()).\(remoteToolPID)"
            unlink(returnPipeName)
            let success = mkfifo(returnPipeName, S_IRWXU | S_IRWXG | S_IRWXO) == 0

            if let writeHandle = FileHandle(forWritingAtPath: sendPipeName) {
                let payload = "\(getpid()).\(remoteToolPID).IBCocoaFramework;"
                try writeHandle.write(contentsOf: Data(payload.utf8))
                try writeHandle.close()
            }

            if success {
                if let readHandle = FileHandle(forReadingAtPath: returnPipeName) {
                    _ = try readHandle.readToEnd()
                    try readHandle.close()
                }

                unlink(returnPipeName)
            }
        }
        #else
        throw StubError.error("Debugger detection is not supported on this platform")
        #endif
    }
}
