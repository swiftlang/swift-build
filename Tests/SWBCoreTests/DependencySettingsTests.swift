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
        #expect(!settings().verification)
        #expect(settings(dependencies: ["Foo"]).verification)
        #expect(settings(verification: .enabled).verification)
        #expect(!settings(dependencies: ["Foo"], verification: .disabled).verification)
    }

    @Test
    func dependenciesAreOrderedAndUnique() throws {
        #expect(Array(settings(dependencies: ["B", "A", "B", "A"]).dependencies) == ["A", "B"])
    }

    func settings(dependencies: [String]? = nil, verification: DependenciesVerificationSetting? = nil) -> DependencySettings {
        var table = MacroValueAssignmentTable(namespace: BuiltinMacros.namespace)
        if let verification {
            table.push(BuiltinMacros.DEPENDENCIES_VERIFICATION, literal: verification)
        }
        if let dependencies {
            table.push(BuiltinMacros.DEPENDENCIES, literal: dependencies)
        }

        let scope = MacroEvaluationScope(table: table)
        return DependencySettings(scope)

    }

}
