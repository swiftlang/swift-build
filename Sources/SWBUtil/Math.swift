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

/// Common math and bit-wise operations
public extension Int {
    /// Returns the value with the least-significant bit removed.
    func withoutLSB() -> Int {
        return self & (self - 1)
    }

    /// Check if the value is a power-of-two.
    func isPowerOfTwo() -> Bool {
        // A value is a power of two if it isn't zero and removing one bit makes it zero.
        return self != 0 && withoutLSB() == 0
    }

    /// Return the next larger power-of-two, or 0 on overflow.
    func nextPowerOfTwo() -> Int {
        // Compute the next power of two by filling all bits below the MSB, then adding one.
        var result = self
        result |= result >> 1
        result |= result >> 2
        result |= result >> 4
        result |= result >> 8
        result |= result >> 16
        result |= result >> 32
        return result + 1
    }

    /// Return the smallest power-of-two greater than or equal to the value.
    func roundUpToPowerOfTwo() -> Int {
        return isPowerOfTwo() ? self : nextPowerOfTwo()
    }

    /// Returns the smallest even number greater than or equal to the value.
    func nextEvenNumber() -> Int {
        return self % 2 == 0 ? self : self + 1
    }
}
