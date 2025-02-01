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
fileprivate struct SandboxingOverrideTests {
    @Test func basicEncoding() throws {
        try testCodable(ProjectModel.SandboxingOverride.forceDisabled)
        try testCodable(ProjectModel.SandboxingOverride.forceEnabled)
        try testCodable(ProjectModel.SandboxingOverride.basedOnBuildSetting)
    }
}
