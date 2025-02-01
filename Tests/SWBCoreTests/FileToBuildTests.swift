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
import SWBTestSupport
import SWBUtil
import SWBCore

@Suite fileprivate struct FileToBuildTests: CoreBasedTests {
    /// Tests the basic FileToBuild functionality.
    @Test
    func basics() async throws {
        let mockFileType = try await getCore().specRegistry.getSpec("file") as FileTypeSpec
        let f = FileToBuild(absolutePath: Path.root.join("tmp/foo"), fileType: mockFileType)
        #expect(f.absolutePath == Path.root.join("tmp/foo"))
    }
}

@Suite fileprivate struct FileToBuildGroupTests: CoreBasedTests {
    /// Tests the basic FileToBuildGroup functionality.
    @Test
    func basics() async throws {
        let mockFileType = try await getCore().specRegistry.getSpec("file") as FileTypeSpec
        let f1 = FileToBuild(absolutePath: Path.root.join("tmp").join("foo"), fileType: mockFileType)
        #expect(f1.absolutePath == Path.root.join("tmp").join("foo"))
        let f2 = FileToBuild(absolutePath: Path.root.join("tmp").join("bar"), fileType: mockFileType)
        #expect(f2.absolutePath == Path.root.join("tmp").join("bar"))
        let fg = FileToBuildGroup(action: nil)
        fg.files.append(f1)
        fg.files.append(f2)
        #expect(fg.assignedBuildRuleAction == nil)  // initial build rule action should be nil
    }
}
