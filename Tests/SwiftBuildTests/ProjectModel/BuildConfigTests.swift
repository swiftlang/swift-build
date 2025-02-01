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
fileprivate struct BuildConfigTests {
    @Test func basicEncoding() throws {
        let obj = ProjectModel.BuildConfig.example
        try testCodable(obj)
    }
}

extension ProjectModel.BuildConfig {
    static var example: Self {
        return ProjectModel.BuildConfig(
            id: "buildconfig-id",
            name: "BuildConfigName",
            settings: .example,
            impartedBuildSettings: .example
        )
    }
}
