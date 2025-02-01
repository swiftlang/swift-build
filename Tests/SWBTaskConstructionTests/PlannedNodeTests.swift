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

import SWBTaskConstruction
import SWBCore
import SWBTestSupport
import SWBUtil
import Testing

@Suite
fileprivate struct PlannedNodeTests {
    @Test(.requireSDKs(.macOS))
    func basics() async throws {
        #expect(MakePlannedPathNode(Path("/tmp")).name == "tmp")
        #expect(MakePlannedPathNode(Path("/tmp")).path == Path("/tmp"))

        // Check reference==value equality
        #expect(MakePlannedPathNode(Path("/tmp"))
                === MakePlannedPathNode(Path("/tmp")))

        // Check expected normalization
        #expect(MakePlannedPathNode(Path("/tmp/a/"))
                === MakePlannedPathNode(Path("/tmp/a")))
        #expect(MakePlannedPathNode(Path("/tmp/a/../b"))
                === MakePlannedPathNode(Path("/tmp/b")))
        #expect(MakePlannedPathNode(Path("/tmp/a/."))
                === MakePlannedPathNode(Path("/tmp/a")))
    }
}
