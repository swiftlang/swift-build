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
import WinSDK

#if canImport(System)
public import System
#else
public import SystemPackage
#endif

extension UnsafePointer where Pointee == CInterop.PlatformChar {
    /// Invokes `body` with a resolved and potentially `\\?\`-prefixed version of the pointee,
    /// to ensure long paths greater than MAX_PATH (260) characters are handled correctly.
    ///
    /// - seealso: https://learn.microsoft.com/en-us/windows/win32/fileio/maximum-file-path-limitation
    public func withCanonicalPathRepresentation<Result>(_ body: (Self) throws -> Result) throws -> Result {
        // 1. Normalize the path first.
        // Contrary to the documentation, this works on long paths independently
        // of the registry or process setting to enable long paths (but it will also
        // not add the \\?\ prefix required by other functions under these conditions).
        let dwLength: DWORD = GetFullPathNameW(self, 0, nil, nil)
        return try withUnsafeTemporaryAllocation(of: WCHAR.self, capacity: Int(dwLength)) { pwszFullPath in
            guard (1..<dwLength).contains(GetFullPathNameW(self, DWORD(pwszFullPath.count), pwszFullPath.baseAddress, nil)) else {
                throw Win32Error(GetLastError())
            }

            // 1.5 Leave \\.\ prefixed paths alone since device paths are already an exact representation and PathCchCanonicalizeEx will mangle these.
            if let base = pwszFullPath.baseAddress,
                base[0] == UInt8(ascii: "\\"),
                base[1] == UInt8(ascii: "\\"),
                base[2] == UInt8(ascii: "."),
                base[3] == UInt8(ascii: "\\") {
                return try body(base)
            }

            // 2. Canonicalize the path.
            // This will add the \\?\ prefix if needed based on the path's length.
            var pwszCanonicalPath: LPWSTR?
            let flags: ULONG = numericCast(PATHCCH_ALLOW_LONG_PATHS.rawValue)
            let result = PathAllocCanonicalize(pwszFullPath.baseAddress, flags, &pwszCanonicalPath)
            if let pwszCanonicalPath {
                defer { LocalFree(pwszCanonicalPath) }
                if result == S_OK {
                    // 3. Perform the operation on the normalized path.
                    return try body(pwszCanonicalPath)
                }
            }
            throw Win32Error(WIN32_FROM_HRESULT(result))
        }
    }
}

@inline(__always)
fileprivate func HRESULT_CODE(_ hr: HRESULT) -> DWORD {
    DWORD(hr) & 0xffff
}

@inline(__always)
fileprivate func HRESULT_FACILITY(_ hr: HRESULT) -> DWORD {
    DWORD(hr << 16) & 0x1fff
}

@inline(__always)
fileprivate func SUCCEEDED(_ hr: HRESULT) -> Bool {
    hr >= 0
}

// This is a non-standard extension to the Windows SDK that allows us to convert
// an HRESULT to a Win32 error code.
@inline(__always)
fileprivate func WIN32_FROM_HRESULT(_ hr: HRESULT) -> DWORD {
    if SUCCEEDED(hr) { return DWORD(ERROR_SUCCESS) }
    if HRESULT_FACILITY(hr) == FACILITY_WIN32 {
        return HRESULT_CODE(hr)
    }
    return DWORD(hr)
}
#endif
