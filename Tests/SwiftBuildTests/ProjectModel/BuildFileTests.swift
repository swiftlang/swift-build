//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
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
fileprivate struct BuildFileTests {
    @Test func basicEncoding() throws {
        let obj = ProjectModel.BuildFile(id: "foo", ref: .targetProduct(id: "bar"))
        try testCodable(obj)
    }
}

extension ProjectModel.BuildFile {
    static var example: Self {
        return .init(id: "buildFileId", ref: .reference(id: "referenceId"))
    }
}
