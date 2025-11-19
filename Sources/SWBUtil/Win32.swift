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

#if os(Windows)
    public import WinSDK

    /// Calls a Win32 API function that fills a (potentially long path) null-terminated string buffer by continually attempting to allocate more memory up until the true max path is reached.
    /// This is especially useful for protecting against race conditions like with GetCurrentDirectoryW where the measured length may no longer be valid on subsequent calls.
    /// - parameter initialSize: Initial size of the buffer (including the null terminator) to allocate to hold the returned string.
    /// - parameter maxSize: Maximum size of the buffer (including the null terminator) to allocate to hold the returned string.
    /// - parameter body: Closure to call the Win32 API function to populate the provided buffer.
    ///   Should return the number of UTF-16 code units (not including the null terminator) copied, 0 to indicate an error.
    ///   If the buffer is not of sufficient size, should return a value greater than or equal to the size of the buffer.
    private func FillNullTerminatedWideStringBuffer(initialSize: DWORD, maxSize: DWORD, _ body: (UnsafeMutableBufferPointer<WCHAR>) throws -> DWORD) throws -> String {
        var bufferCount = max(1, min(initialSize, maxSize))
        while bufferCount <= maxSize {
            if let result = try withUnsafeTemporaryAllocation(
                of: WCHAR.self,
                capacity: Int(bufferCount),
                { buffer in
                    let count = try body(buffer)
                    switch count {
                    case 0:
                        throw Win32Error(GetLastError())
                    case 1..<DWORD(buffer.count):
                        let result = String(decodingCString: buffer.baseAddress!, as: UTF16.self)
                        assert(result.utf16.count == count, "Parsed UTF-16 count \(result.utf16.count) != reported UTF-16 count \(count)")
                        return result
                    default:
                        bufferCount *= 2
                        return nil
                    }
                }
            ) {
                return result
            }
        }
        throw Win32Error(DWORD(ERROR_INSUFFICIENT_BUFFER))
    }

    private let maxPathLength = DWORD(Int16.max)  // https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
    private let maxEnvVarLength = DWORD(Int16.max)  // https://devblogs.microsoft.com/oldnewthing/20100203-00/

    @_spi(Testing) public func SWB_GetModuleFileNameW(_ hModule: HMODULE?) throws -> String {
        try FillNullTerminatedWideStringBuffer(initialSize: DWORD(MAX_PATH), maxSize: maxPathLength) {
            GetModuleFileNameW(hModule, $0.baseAddress!, DWORD($0.count))
        }
    }

    public func SWB_GetEnvironmentVariableW(_ wName: LPCWSTR) throws -> String {
        try FillNullTerminatedWideStringBuffer(initialSize: 1024, maxSize: maxEnvVarLength) {
            GetEnvironmentVariableW(wName, $0.baseAddress!, DWORD($0.count))
        }
    }

    public func SWB_GetWindowsDirectoryW() throws -> String {
        try FillNullTerminatedWideStringBuffer(initialSize: DWORD(MAX_PATH), maxSize: maxPathLength) {
            GetWindowsDirectoryW($0.baseAddress!, DWORD($0.count))
        }
    }
#endif
