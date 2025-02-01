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

public import struct Foundation.TimeInterval

extension Duration {
    /// The value of the time interval in nanoseconds (ns).
    public var nanoseconds: Int64 {
        (components.seconds * Int64(1e+9)) + (components.attoseconds / Int64(1e+9))
    }

    /// The value of the time interval in microseconds (μs).
    public var microseconds: Int64 {
        (components.seconds * Int64(1e+6)) + (components.attoseconds / Int64(1e+12))
    }

    /// The value of the time interval in fractional seconds (s).
    public var seconds: TimeInterval {
        Double(components.seconds) + (Double(components.attoseconds) / 1e+18)
    }
}
