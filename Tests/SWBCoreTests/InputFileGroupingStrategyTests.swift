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
@_spi(Testing) import SWBCore

fileprivate struct TestGroupable: InputFileGroupable {
    let absolutePath: Path
    let regionVariantName: String?
}

extension InputFileGroupingStrategy {
    func determineGroupIdentifier(path: Path, regionVariantName: String? = nil) -> String? {
        determineGroupIdentifier(groupable: TestGroupable(absolutePath: path, regionVariantName: regionVariantName))
    }
}

@Suite fileprivate struct InputFileGroupingStrategyTests {
    @Test
    func allInputFilesGroupingStrategy() {
        let gs = AllInputFilesGroupingStrategy(groupIdentifier: "bla-bla")
        #expect(gs.determineGroupIdentifier(path: Path("")) == "bla-bla")
        #expect(gs.determineGroupIdentifier(path: Path("file")) == "bla-bla")
        #expect(gs.determineGroupIdentifier(path: Path("file.h")) == "bla-bla")
        #expect(gs.determineGroupIdentifier(path: Path("file.m")) == "bla-bla")
    }

    @Test
    func commonFileBaseInputFileGroupingStrategy() {
        let gs = CommonFileBaseInputFileGroupingStrategy(toolName: "tool-name")
        #expect(gs.determineGroupIdentifier(path: Path("")) == "tool:tool-name file-base:")
        #expect(gs.determineGroupIdentifier(path: Path("file")) == "tool:tool-name file-base:file")
        #expect(gs.determineGroupIdentifier(path: Path("file.h")) == "tool:tool-name file-base:file")
        #expect(gs.determineGroupIdentifier(path: Path("file.m")) == "tool:tool-name file-base:file")
    }
}
