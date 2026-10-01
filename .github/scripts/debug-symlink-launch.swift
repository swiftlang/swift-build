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

// DEBUG ONLY: reproduce ToolsetTaskConstructionTests.toolsetCustomization's symlinked tool launch with Foundation,
// and report the Win32 error that Foundation.Process turns into NSCocoaErrorDomain error 256.
// Usage: debug-symlink-launch.exe <link-dir> <tool-path>...

import Foundation
import WinSDK

let arguments = CommandLine.arguments
let linkDir = URL(fileURLWithPath: arguments[1])
try? FileManager.default.removeItem(at: linkDir)
try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)

for toolPath in arguments.dropFirst(2) {
    let tool = URL(fileURLWithPath: toolPath)
    let link = linkDir.appendingPathComponent(tool.lastPathComponent)
    print("=== \(tool.path)")
    do {
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: tool.path)
        print("    symlink target as written: \((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) ?? "<unreadable>")")
    } catch {
        print("    createSymbolicLink failed: \(error)")
        continue
    }

    for url in [tool, link] {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            print("    Foundation.Process \(url.path): exit \(process.terminationStatus)")
        } catch {
            print("    Foundation.Process \(url.path): FAILED: \(error)")
        }

        var startupInfo = STARTUPINFOW()
        startupInfo.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var processInfo = PROCESS_INFORMATION()
        var windowsPath = url.path.replacingOccurrences(of: "/", with: "\\")
        if windowsPath.hasPrefix("\\"), windowsPath.dropFirst().dropFirst().first == ":" {
            windowsPath.removeFirst()
        }
        let commandLine = "\"\(windowsPath)\" --version"
        let launched = commandLine.withCString(encodedAs: UTF16.self) { wszCommandLine in
            CreateProcessW(nil, UnsafeMutablePointer(mutating: wszCommandLine), nil, nil, false, DWORD(CREATE_NO_WINDOW), nil, nil, &startupInfo, &processInfo)
        }
        if launched {
            WaitForSingleObject(processInfo.hProcess, INFINITE)
            CloseHandle(processInfo.hThread)
            CloseHandle(processInfo.hProcess)
            print("    CreateProcessW \(url.path): OK")
        } else {
            print("    CreateProcessW \(url.path): FAILED with GetLastError() = \(GetLastError())")
        }
    }
}
