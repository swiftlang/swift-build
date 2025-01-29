//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

#if os(macOS)
private import EditLine
private import EditLine.readline
#elseif !canImport(Darwin) && !os(Windows) && !os(Android) && !os(FreeBSD)
private import readline
#endif

import SWBCSupport

public func swb_readline(_ prompt: String?) -> String? {
    #if os(macOS) || (!canImport(Darwin) && !os(Windows) && !os(Android) && !os(FreeBSD))
    return prompt?.utf8CString.withUnsafeBufferPointer { bp -> String? in
        if let ptr = readline(bp.baseAddress) {
            defer { ptr.deallocate() }
            return String(cString: ptr)
        }
        return nil
    }
    #else
    return nil
    #endif
}

@discardableResult public func swb_add_history(_ string: String?) -> Int {
    #if os(macOS) || (!canImport(Darwin) && !os(Windows) && !os(Android) && !os(FreeBSD))
    return string?.utf8CString.withUnsafeBufferPointer { Int(add_history($0.baseAddress)) } ?? Int(add_history(nil))
    #else
    return 0
    #endif
}

@discardableResult public func swb_read_history(_ filename: String?) -> Int {
    #if os(macOS) || (!canImport(Darwin) && !os(Windows) && !os(Android) && !os(FreeBSD))
    return filename?.utf8CString.withUnsafeBufferPointer { Int(read_history($0.baseAddress)) } ?? Int(read_history(nil))
    #else
    return 0
    #endif
}

@discardableResult public func swb_write_history(_ filename: String?) -> Int {
    #if os(macOS) || (!canImport(Darwin) && !os(Windows) && !os(Android) && !os(FreeBSD))
    return filename?.utf8CString.withUnsafeBufferPointer { Int(write_history($0.baseAddress)) } ?? Int(write_history(nil))
    #else
    return 0
    #endif
}

@discardableResult public func swb_history_truncate_file(_ filename: String?, _ nlines: Int) -> Int {
    #if os(macOS) || (!canImport(Darwin) && !os(Windows) && !os(Android) && !os(FreeBSD))
    return filename?.utf8CString.withUnsafeBufferPointer { Int(history_truncate_file($0.baseAddress, Int32(nlines))) } ?? Int(history_truncate_file(nil, Int32(nlines)))
    #else
    return 0
    #endif
}
