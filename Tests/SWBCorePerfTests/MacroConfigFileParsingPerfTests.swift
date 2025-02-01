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
import SWBUtil
import SWBCore
import SWBTestSupport
import SWBMacro

@Suite(.performance)
fileprivate struct MacroConfigFileParsingPerfTests: PerfTests {
    private func runParsingTest(_ byteString: ByteString, iterations: Int) async {
        await measure {
            for _ in 1...iterations {
                let parser = MacroConfigFileParser(byteString: byteString, path: Path("runParsingTest().xcconfig"), delegate: nil)
                parser.parse()
            }
        }
    }

    @Test
    func parsingOfEmptyStrings_X100000() async {
        await runParsingTest("", iterations: 100000)
    }

    @Test
    func parsingOfSingleSimpleAssignments_X100000() async {
        await runParsingTest("MACRO=VALUE", iterations: 100000)
    }

    @Test
    func parsingOfMultipleSimpleAssignments_X1000() async {
        let byteString = ByteString(encodingAsUTF8: [String](repeating:"MACRO=VALUE", count:10).joined(separator: "\n"))
        await runParsingTest(byteString, iterations: 1000)
    }

    @Test
    func parsing1MBFile_X10() async {
        let byteString = ByteString(encodingAsUTF8: (0..<44616).map{ "MACRO\($0) = VALUE\($0)" }.joined(separator: "\n"))
        await runParsingTest(byteString, iterations: 10)
    }
}
