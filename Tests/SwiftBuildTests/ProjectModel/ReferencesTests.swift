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
import SwiftBuild
import Testing

@Suite
fileprivate struct ReferencesTests {
    @Test func fileEncoding() throws {
        let obj = ProjectModel.Reference.file(.example)
        try testCodable(obj)
    }

    @Test func groupEncoding() throws {
        let obj = ProjectModel.Reference.group(.example)
        try testCodable(obj)
    }

}

extension ProjectModel.FileReference {
    static var example: Self {
        return .init(
            id: "foo",
            path: "bar",
            pathBase: .projectDir,
            name: "name",
            fileType: "fileType"
        )
    }
}

extension ProjectModel.Group {
    static var example: Self {
        return .init(
            id: "foo",
            path: "bar",
            pathBase: .absolute,
            name: "group",
            subitems: [
                .file(.example)
            ])
    }
}
