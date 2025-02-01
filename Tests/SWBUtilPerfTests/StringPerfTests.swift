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

import Testing
import SWBTestSupport
import SWBUtil

/// A sequence of `count` random UInt8 numbers drawn from `range`.  [Note: it would be preferable to make this struct generic over all types of integers, but I haven’t found a way to do so that lets it compile. Perhaps declaring a new protocol and then making Integers adopt it would work?].
fileprivate struct RandomUInt8Sequence: Sequence {
    struct RandomUInt8Generator : IteratorProtocol {
        var range: CountableClosedRange<UInt8>
        var count: Int
        mutating func next() -> UInt8? {
            guard count > 0 else { return .none }
            count -= 1
            // TYPE-INFERENCE: This extra variable is just used to simplify type inference (versus inline code). This is a workaround for poor type inference performance in the Swift compiler.
            let offset: Int = Int(UInt32.random(in: UInt32.min...UInt32.max)) % Int(range.count)
            return range.lowerBound + UInt8(offset)
        }
    }
    typealias Iterator = RandomUInt8Generator
    var range: CountableClosedRange<UInt8>
    var count: Int
    func makeIterator() -> Iterator {
        return RandomUInt8Generator(range: range, count: count)
    }
}

@Suite(.performance)
fileprivate struct StringPerfTests: PerfTests {
    /// Creates a buffer containing 256 ASCII characters and then creates strings from it.
    @Test
    func creationFromASCIIBuffer_X100000() async {
        let iterations = 100000
        let buffer = [UInt8](RandomUInt8Sequence(range: 32...127, count: 256))
        await measure {
            for _ in 1...iterations {
                let _ = buffer.asReadableString()
            }
        }
    }
}
