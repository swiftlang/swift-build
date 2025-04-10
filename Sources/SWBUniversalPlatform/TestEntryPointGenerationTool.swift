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

import SWBUtil
import SWBMacro
import SWBCore

final class TestEntryPointGenerationToolSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "org.swift.test-entry-point-generator"

    override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        TestEntryPointGenerationTaskAction()
    }
}
