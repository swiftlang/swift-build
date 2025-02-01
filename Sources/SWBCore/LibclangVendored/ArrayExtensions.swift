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

public extension Array where Element == String {
    /// Converts a C string array into a Swift array of Strings.
    static func fromCStringArray(_ cStringArray: UnsafePointer<UnsafePointer<Int8>?>) -> [String] {
        // TODO: Perhaps this can be upstreamed to TSC?
        return sequence(state: cStringArray) { ptr in
            defer { ptr += 1 }
            return ptr.pointee
        }.map { String.init(cString: $0 as UnsafePointer<Int8>) }
    }
}

extension UnsafeMutablePointer<UnsafePointer<Int8>?> {
    func toLazyStringSequence() -> some Sequence<String> {
        return sequence(state: self) { ptr in
            defer { ptr += 1 }
            return ptr.pointee.map { String(cString: $0) }
        }
    }
}
