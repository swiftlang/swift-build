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

import WinSDK

// Also see winternl.h in the Windows SDK for the definitions of a number of these structures.

// https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess#parameters
fileprivate let ProcessBasicInformation: CInt = 0

// https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/show-loader-snaps
fileprivate let FLG_SHOW_LOADER_SNAPS: ULONG = 0x2

// https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess#process_basic_information
fileprivate struct PROCESS_BASIC_INFORMATION {
    var ExitStatus: NTSTATUS = 0
    var PebBaseAddress: ULONG_PTR = 0
    var AffinityMask: ULONG_PTR = 0
    var BasePriority: LONG = 0
    var UniqueProcessId: ULONG_PTR = 0
    var InheritedFromUniqueProcessId: ULONG_PTR = 0
}

// https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntqueryinformationprocess
fileprivate typealias NtQueryInformationProcessFunction = @convention(c) (_ ProcessHandle: HANDLE, _ ProcessInformationClass: CInt, _ ProcessInformation: PVOID, _ ProcessInformationLength: ULONG, _ ReturnLength: PULONG) -> NTSTATUS

fileprivate struct _Win32Error: Error, CustomStringConvertible {
    let functionName: String
    let error: DWORD

    var errorString: String? {
        let flags: DWORD = DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS)
        var buffer: UnsafeMutablePointer<WCHAR>?
        let length: DWORD = withUnsafeMutablePointer(to: &buffer) {
            $0.withMemoryRebound(to: WCHAR.self, capacity: 2) {
                FormatMessageW(flags, nil, error, 0, $0, 0, nil)
            }
        }
        guard let buffer, length > 0 else {
            return nil
        }
        defer { LocalFree(buffer) }
        return String(decodingCString: buffer, as: UTF16.self)
    }

    var description: String {
        let prefix = "\(functionName) returned \(error)"
        if let errorString {
            return [prefix, errorString].joined(separator: ": ")
        }
        return prefix
    }
}

extension String {
    fileprivate func withLPWSTR<T>(_ body: (UnsafeMutablePointer<WCHAR>) throws -> T) rethrows -> T {
        try withUnsafeTemporaryAllocation(of: WCHAR.self, capacity: self.utf16.count + 1, { outBuffer in
            try self.withCString(encodedAs: UTF16.self) { inBuffer in
                outBuffer.baseAddress!.initialize(from: inBuffer, count: self.utf16.count)
                outBuffer[outBuffer.count - 1] = 0
                return try body(outBuffer.baseAddress!)
            }
        })
    }
}

func withStandardError(body: ((String) throws -> ()) throws -> ()) throws {
    guard let stderr = GetStdHandle(STD_ERROR_HANDLE) else {
        throw _Win32Error(functionName: "GetStdHandle", error: GetLastError())
    }
    var mode: DWORD = 0
    let isConsole = GetConsoleMode(stderr, &mode)
    func write(_ message: String) throws {
        if isConsole {
            try message.withLPWSTR { wstr in
                guard WriteConsoleW(stderr, wstr, DWORD(message.utf16.count), nil, nil) else {
                    throw _Win32Error(functionName: "WriteConsoleW", error: GetLastError())
                }
            }
        } else {
            try message.withCString { str in
                guard WriteFile(stderr, str, DWORD(message.utf8.count), nil, nil) else {
                    throw _Win32Error(functionName: "WriteFile", error: GetLastError())
                }
            }
        }
    }
    try body(write)
}

extension PROCESS_BASIC_INFORMATION {
    fileprivate init(_ hProcess: HANDLE, _ NtQueryInformation: NtQueryInformationProcessFunction) throws {
        self.init()

        let processBasicInformationSize = MemoryLayout.size(ofValue: self)
        #if arch(x86_64) || arch(arm64)
        precondition(processBasicInformationSize == 48)
        #elseif arch(i386) || arch(arm)
        precondition(processBasicInformationSize == 24)
        #else
        #error("Unsupported architecture")
        #endif

        var len: ULONG = 0
        guard NtQueryInformation(hProcess, ProcessBasicInformation, &self, ULONG(processBasicInformationSize), &len) == 0 else {
            throw _Win32Error(functionName: "NtQueryInformationProcess", error: GetLastError())
        }
    }

    // FIXME: Does this work for mixed architecture scenarios? WoW64 seems to be OK.
    fileprivate var PebBaseAddress_NtGlobalFlag: ULONG_PTR {
        #if arch(x86_64) || arch(arm64)
        PebBaseAddress + 0xBC // https://github.com/wine-mirror/wine/blob/e1af2ae201c9853133ef3af1dafe15fe992fed92/include/winternl.h#L990 (undocumented officially)
        #elseif arch(i386) || arch(arm)
        PebBaseAddress + 0x68 // https://github.com/wine-mirror/wine/blob/e1af2ae201c9853133ef3af1dafe15fe992fed92/include/winternl.h#L880 (undocumented officially)
        #else
        #error("Unsupported architecture")
        #endif
    }
}

fileprivate func withGFlags(_ hProcess: HANDLE, _ ProcessBasicInformation: PROCESS_BASIC_INFORMATION, _ block: (_ gflags: inout ULONG) -> ()) throws {
    // https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/gflags-flag-table
    var gflags: ULONG = 0
    var actual: SIZE_T = 0
    guard ReadProcessMemory(hProcess, UnsafeMutableRawPointer(bitPattern: Int(ProcessBasicInformation.PebBaseAddress_NtGlobalFlag)), &gflags, SIZE_T(MemoryLayout.size(ofValue: gflags)), &actual) else {
        throw _Win32Error(functionName: "ReadProcessMemory", error: GetLastError())
    }

    block(&gflags)
    guard WriteProcessMemory(hProcess, UnsafeMutableRawPointer(bitPattern: Int(ProcessBasicInformation.PebBaseAddress_NtGlobalFlag)), &gflags, SIZE_T(MemoryLayout.size(ofValue: gflags)), &actual) else {
        throw _Win32Error(functionName: "WriteProcessMemory", error: GetLastError())
    }
}

func withDebugEventLoop(_ hProcess: HANDLE, _ handle: (_ event: String) throws -> ()) throws {
    guard let ntdll = "ntdll.dll".withLPWSTR({ GetModuleHandleW($0) }) else {
        throw _Win32Error(functionName: "GetModuleHandleW", error: GetLastError())
    }

    guard let ntQueryInformationProc = GetProcAddress(ntdll, "NtQueryInformationProcess") else {
        throw _Win32Error(functionName: "GetProcAddress", error: GetLastError())
    }

    let processBasicInformation = try PROCESS_BASIC_INFORMATION(hProcess, unsafeBitCast(ntQueryInformationProc, to: NtQueryInformationProcessFunction.self))

    try withGFlags(hProcess, processBasicInformation) { gflags in
        gflags |= FLG_SHOW_LOADER_SNAPS
    }

    func debugOutputString(_ hProcess: HANDLE, _ dbgEvent: inout DEBUG_EVENT) throws -> String {
        let size = SIZE_T(dbgEvent.u.DebugString.nDebugStringLength)
        return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: Int(size) + 2) { buffer in
            guard ReadProcessMemory(hProcess, dbgEvent.u.DebugString.lpDebugStringData, buffer.baseAddress, size, nil) else {
                throw _Win32Error(functionName: "ReadProcessMemory", error: GetLastError())
            }

            buffer[Int(size)] = 0
            buffer[Int(size + 1)] = 0

            if dbgEvent.u.DebugString.fUnicode != 0 {
                return buffer.withMemoryRebound(to: UInt16.self) { String(decoding: $0, as: UTF16.self) }
            } else {
                return try withUnsafeTemporaryAllocation(of: UInt16.self, capacity: Int(size)) { wideBuffer in
                    if MultiByteToWideChar(UINT(CP_ACP), 0, buffer.baseAddress, Int32(size), wideBuffer.baseAddress, Int32(size)) == 0 {
                        throw _Win32Error(functionName: "MultiByteToWideChar", error: GetLastError())
                    }
                    return String(decoding: wideBuffer, as: UTF16.self)
                }
            }
        }
    }

    func _WaitForDebugEventEx() throws -> DEBUG_EVENT {
        // WARNING: Only the thread that created the process being debugged can call WaitForDebugEventEx.
        var dbgEvent = DEBUG_EVENT()
        guard WaitForDebugEventEx(&dbgEvent, INFINITE) else {
            // WaitForDebugEventEx will fail if dwCreationFlags did not contain DEBUG_ONLY_THIS_PROCESS
            throw _Win32Error(functionName: "WaitForDebugEventEx", error: GetLastError())
        }
        return dbgEvent
    }

    func runDebugEventLoop() throws {
        do {
            while true {
                var dbgEvent = try _WaitForDebugEventEx()
                if dbgEvent.dwProcessId == GetProcessId(hProcess) {
                    switch dbgEvent.dwDebugEventCode {
                    case DWORD(OUTPUT_DEBUG_STRING_EVENT):
                        try handle(debugOutputString(hProcess, &dbgEvent))
                    case DWORD(EXIT_PROCESS_DEBUG_EVENT):
                        return // done!
                    default:
                        break
                    }
                }

                guard ContinueDebugEvent(dbgEvent.dwProcessId, dbgEvent.dwThreadId, DBG_EXCEPTION_NOT_HANDLED) else {
                    throw _Win32Error(functionName: "WaitForDebugEventEx", error: GetLastError())
                }
            }
        } catch {
            throw error
        }
    }

    try runDebugEventLoop()
}

func createProcessTrampoline(_ commandLine: String) throws -> Int32 {
    assert(!commandLine.isEmpty, "Command line is empty")
    var processInformation = PROCESS_INFORMATION()
    guard commandLine.withLPWSTR({ wCommandLine in
        var startupInfo = STARTUPINFOW()
        startupInfo.cb = DWORD(MemoryLayout.size(ofValue: startupInfo))
        return CreateProcessW(
            nil,
            wCommandLine,
            nil,
            nil,
            false,
            DWORD(DEBUG_ONLY_THIS_PROCESS),
            nil,
            nil,
            &startupInfo,
            &processInformation,
        )
    }) else {
        throw _Win32Error(functionName: "CreateProcessW", error: GetLastError())
    }
    defer {
        _ = CloseHandle(processInformation.hThread)
        _ = CloseHandle(processInformation.hProcess)
    }
    var missingDLLs: [String] = []
    try withDebugEventLoop(processInformation.hProcess) { message in
        if let match = try #/ ERROR: Unable to load DLL: "(?<moduleName>.*?)",/#.firstMatch(in: message) {
            missingDLLs.append(String(match.output.moduleName))
        }
    }
    // Don't need to call WaitForSingleObject because the process will have exited after withDebugEventLoop is called
    var exitCode: DWORD = .max
    guard GetExitCodeProcess(processInformation.hProcess, &exitCode) else {
        throw _Win32Error(functionName: "GetExitCodeProcess", error: GetLastError())
    }
    if exitCode == STATUS_DLL_NOT_FOUND {
        try withStandardError { write in
            for missingDLL in missingDLLs {
                try write("This application has failed to start because \(missingDLL) was not found.\r\n")
            }
        }
    }
    return Int32(bitPattern: exitCode)
}

func main() -> Int32 {
    do {
        var commandLine = String(decodingCString: GetCommandLineW(), as: UTF16.self)

        // FIXME: This could probably be more robust
        if commandLine.first == "\"" {
            commandLine = String(commandLine.dropFirst())
            if let index = commandLine.firstIndex(of: "\"") {
                commandLine = String(commandLine.dropFirst(commandLine.distance(from: commandLine.startIndex, to: index) + 2))
            }
        } else if let index = commandLine.firstIndex(of: " ") {
            commandLine = String(commandLine.dropFirst(commandLine.distance(from: commandLine.startIndex, to: index) + 1))
        } else {
            commandLine = ""
        }

        return try createProcessTrampoline(commandLine)
    } catch {
        try? withStandardError { write in
            try write("\(error)\r\n")
        }
        return EXIT_FAILURE
    }
}

exit(main())
