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

extension Int {
    // FIXME: Figure out what the best API for this is. Having a more explicit (non-format string based) API is easier to make efficient, but it ends up taking so many arguments just to get the same flexibility.
    public func toString(format: String = "%d") -> String {
        return String(format: format, self)
    }

    /// Returns a string form of the receiver as an adjective, e.g. 1st, 2nd, 3rd, 4th, <n>th.  This only makes grammatical sense for positive integers, but is supported for non-positive integers for ease of use.
    public var asOrdinal: String {
        let tensDigit = self / 10 % 10
        switch self % 10 {
        case 1 where tensDigit != 1, -1 where tensDigit != -1:
            return toString() + "st"
        case 2 where tensDigit != 1, -2 where tensDigit != -1:
            return toString() + "nd"
        case 3 where tensDigit != 1, -3 where tensDigit != -1:
            return toString() + "rd"
        default:
            return toString() + "th"
        }
    }
}

extension UInt {
    // FIXME: Figure out what the best API for this is. Having a more explicit (non-format string based) API is easier to make efficient, but it ends up taking so many arguments just to get the same flexibility.
    public func toString(format: String = "%d") -> String {
        return String(format: format, self)
    }

    /// Returns a string form of the receiver as an adjective, e.g. 1st, 2nd, 3rd, 4th, <n>th.  This only makes grammatical sense for positive integers, but is supported for non-positive integers for ease of use.
    public var asOrdinal: String {
        let tensDigit = self / 10 % 10
        switch self % 10 {
        case 1 where tensDigit != 1:
            return toString() + "st"
        case 2 where tensDigit != 1:
            return toString() + "nd"
        case 3 where tensDigit != 1:
            return toString() + "rd"
        default:
            return toString() + "th"
        }
    }
}
