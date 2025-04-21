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
import Foundation

public struct Win32Error: Error, CustomStringConvertible {
    public let error: DWORD

    public init(_ error: DWORD) {
        self.error = error
    }

    public var description: String {
        let flags: DWORD = DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS)
        var buffer: UnsafeMutablePointer<WCHAR>?
        let length: DWORD = withUnsafeMutablePointer(to: &buffer) {
            $0.withMemoryRebound(to: WCHAR.self, capacity: 2) {
                FormatMessageW(flags, nil, error, 0, $0, 0, nil)
            }
        }
        guard let buffer, length > 0 else {
            return "Win32 Error Code \(error)"
        }
        defer { LocalFree(buffer) }
        return String(decodingCString: buffer, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
