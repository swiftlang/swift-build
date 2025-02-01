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
import Testing
import SWBUtil

@Suite fileprivate struct IntTests {
    @Test
    func intFormat() {
        #expect(10.toString(format: "%03d") == "010")
    }

    @Test
    func toOrdinal() {
        #expect(Int(1).asOrdinal == "1st")
        #expect(Int(2).asOrdinal == "2nd")
        #expect(Int(3).asOrdinal == "3rd")
        #expect(Int(4).asOrdinal == "4th")
        #expect(Int(10).asOrdinal == "10th")
        #expect(Int(11).asOrdinal == "11th")
        #expect(Int(12).asOrdinal == "12th")
        #expect(Int(13).asOrdinal == "13th")
        #expect(Int(19).asOrdinal == "19th")
        #expect(Int(21).asOrdinal == "21st")
        #expect(Int(32).asOrdinal == "32nd")
        #expect(Int(43).asOrdinal == "43rd")
        #expect(Int(76).asOrdinal == "76th")
        #expect(Int(100).asOrdinal == "100th")
        #expect(Int(112).asOrdinal == "112th")
        #expect(Int(9311).asOrdinal == "9311th")

        // Make sure to test both signed and unsigned positive integers in order to have full test coverage of both implementations
        #expect(UInt(1).asOrdinal == "1st")
        #expect(UInt(2).asOrdinal == "2nd")
        #expect(UInt(3).asOrdinal == "3rd")
        #expect(UInt(4).asOrdinal == "4th")
        #expect(UInt(10).asOrdinal == "10th")
        #expect(UInt(11).asOrdinal == "11th")
        #expect(UInt(12).asOrdinal == "12th")
        #expect(UInt(13).asOrdinal == "13th")
        #expect(UInt(19).asOrdinal == "19th")
        #expect(UInt(21).asOrdinal == "21st")
        #expect(UInt(32).asOrdinal == "32nd")
        #expect(UInt(43).asOrdinal == "43rd")
        #expect(UInt(76).asOrdinal == "76th")
        #expect(UInt(100).asOrdinal == "100th")
        #expect(UInt(112).asOrdinal == "112th")
        #expect(UInt(9311).asOrdinal == "9311th")

        // Isaac Asimov defined a "Zeroth Law of Robotics". :-)
        #expect(Int(0).asOrdinal == "0th")
        #expect(UInt(0).asOrdinal == "0th")
        #expect((-0).asOrdinal == "0th")

        // check negative numbers.
        #expect((-1).asOrdinal == "-1st")
        #expect((-2).asOrdinal == "-2nd")
        #expect((-3).asOrdinal == "-3rd")
        #expect((-4).asOrdinal == "-4th")
        #expect((-10).asOrdinal == "-10th")
        #expect((-11).asOrdinal == "-11th")
        #expect((-12).asOrdinal == "-12th")
        #expect((-13).asOrdinal == "-13th")
        #expect((-19).asOrdinal == "-19th")
        #expect((-21).asOrdinal == "-21st")
        #expect((-32).asOrdinal == "-32nd")
        #expect((-43).asOrdinal == "-43rd")
        #expect((-76).asOrdinal == "-76th")
        #expect((-100).asOrdinal == "-100th")
        #expect((-112).asOrdinal == "-112th")
        #expect((-9311).asOrdinal == "-9311th")
    }
}
