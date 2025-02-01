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

import SWBCore
import SWBUtil
import Testing
@_spi(Testing) import SWBApplePlatform

fileprivate struct TestGroupable: InputFileGroupable {
    let absolutePath: Path
    let regionVariantName: String?
}

extension InputFileGroupingStrategy {
    func determineGroupIdentifier(path: Path, regionVariantName: String? = nil) -> String? {
        determineGroupIdentifier(groupable: TestGroupable(absolutePath: path, regionVariantName: regionVariantName))
    }
}

@Suite fileprivate struct AppleInputFileGroupingStrategyTests {
    @Test
    func imageScaleFactorsInputFileGroupingStrategy() {
        let gs = ImageScaleFactorsInputFileGroupingStrategy(toolName: "tool-name")
        #expect(gs.determineGroupIdentifier(path: Path("")) == "tool:tool-name file-base:")
        #expect(gs.determineGroupIdentifier(path: Path("file")) == "tool:tool-name file-base:file")
        #expect(gs.determineGroupIdentifier(path: Path("file.tiff")) == "tool:tool-name file-base:file.tiff")
        #expect(gs.determineGroupIdentifier(path: Path("file.png")) == "tool:tool-name file-base:file.png")
        #expect(gs.determineGroupIdentifier(path: Path("file@1x.png")) == "tool:tool-name file-base:file.png")
        #expect(gs.determineGroupIdentifier(path: Path("file@2x.png")) == "tool:tool-name file-base:file.png")
        #expect(gs.determineGroupIdentifier(path: Path("file@3x.png")) == "tool:tool-name file-base:file.png")
    }

    @Test
    func localizationInputFileGroupingStrategy() {
        let gs = LocalizationInputFileGroupingStrategy(toolName: "tool-name")
        #expect(gs.determineGroupIdentifier(path: Path("")) == "tool:tool-name region:")
        #expect(gs.determineGroupIdentifier(path: Path("anything.r"), regionVariantName: "en") == "tool:tool-name region:en")
        #expect(gs.determineGroupIdentifier(path: Path("everything.r"), regionVariantName: "en") == "tool:tool-name region:en")
        #expect(gs.determineGroupIdentifier(path: Path("nothing.r"), regionVariantName: "de") == "tool:tool-name region:de")
        #expect(gs.determineGroupIdentifier(path: Path("something.r"), regionVariantName: "de") == "tool:tool-name region:de")
    }
}
