//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing
import SWBProjectModel

@Suite fileprivate struct SwiftBuildFileTypeTests {

    @Test func swiftBuildFileTypes() throws {
        let fileTypeIdentifiers = SwiftBuildFileType.all.map(\.fileTypeIdentifier)
        let expectedFileTypeIdentifiers = [
            "folder.abstractassetcatalog",
            "text.json.xcstrings",
            "wrapper.xcdatamodeld",
            "wrapper.xcdatamodel",
            "wrapper.xcmappingmodel",
            "folder.aimodel",
            "file.mlmodel",
            "folder.mlpackage",
            "sourcecode.metal",
            "file.referenceobject",
        ]
        #expect(fileTypeIdentifiers == expectedFileTypeIdentifiers)
    }
}
