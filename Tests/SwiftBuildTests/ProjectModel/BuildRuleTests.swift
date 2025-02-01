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
fileprivate struct BuildRuleTests {
    @Test func basicEncoding() throws {
        try testCodable(ProjectModel.BuildRule.example)
        try testCodable(ProjectModel.BuildRule.example2)
    }
}

extension ProjectModel.BuildRule {
    static let example: Self = .init(
        id: "foo",
        name: "bar",
        input: .filePattern("*.swift"),
        action: .compiler("foo")
    )

    static let example2: Self = .init(
        id: "foo",
        name: "bar",
        input: .filePattern("*.swift"),
        action: .shellScriptWithFileList(
            "foo",
            inputPaths: ["bar"],
            inputFileListPaths: ["iflp1", "iflp2"],
            outputPaths: ["outputFoo"],
            outputFileListPaths: ["oflp1", "oflp2"],
            outputFilesCompilerFlags: ["flag1", "flag2"],
            dependencyInfo: .dependencyInfo("qux"),
            runOncePerArchitecture: true
        )
    )

}


