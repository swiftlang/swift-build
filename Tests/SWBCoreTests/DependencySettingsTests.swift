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
import SWBUtil
import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBMacro

@Suite fileprivate struct DependencySettingsTests {

    @Test
    func emptyDependenciesValueDisablesVerification() throws {
        var table1 = MacroValueAssignmentTable(namespace: BuiltinMacros.namespace)
        table1.push(BuiltinMacros.DEPENDENCIES_VERIFICATION, literal: true)
        let scope1 = MacroEvaluationScope(table: table1)
        #expect(!DependencySettings(scope1).verification)

        var table2 = MacroValueAssignmentTable(namespace: BuiltinMacros.namespace)
        table2.push(BuiltinMacros.DEPENDENCIES_VERIFICATION, literal: true)
        table2.push(BuiltinMacros.DEPENDENCIES, literal: ["Foo"])
        let scope2 = MacroEvaluationScope(table: table2)
        #expect(DependencySettings(scope2).verification)
    }

}
