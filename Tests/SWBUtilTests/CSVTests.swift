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

@Suite fileprivate struct CSVTests {
    @Test
    func CSVEscaping() {
        #expect("test".csvEscaped() == "test")
        #expect("has whitespace".csvEscaped() == "\"has whitespace\"")
        #expect("has\nnewline".csvEscaped() == "\"has\nnewline\"")
        #expect("has,comma".csvEscaped() == "\"has,comma\"")
        #expect("has\"quote".csvEscaped() == "\"has\"\"quote\"")
    }

    @Test
    func CSVStream() {
        var builder = CSVBuilder()
        builder.writeRow(["col1", "col2", "col3"])
        builder.writeRow(["v1", "v2", "v3"])
        builder.writeRow(["has whitespace", "has,comma", "has\"quote"])
        #expect(builder.output == """
        col1,col2,col3\r
        v1,v2,v3\r
        "has whitespace","has,comma","has""quote"\r

        """)
    }
}
