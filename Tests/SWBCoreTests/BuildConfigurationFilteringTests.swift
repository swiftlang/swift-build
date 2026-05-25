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
@_spi(Testing) import SWBCore
@_spi(Testing) import SWBMacro

@Suite fileprivate struct BuildConfigurationFilteringTests {
    @Test(arguments: ["Debug", "Release"])
    func initFromScope(_ configuration: String) {
        let filter = createBuildConfigurationFilter(configuration: configuration)
        #expect(filter == BuildConfigurationFilter(buildConfiguration: configuration))
    }

    private func createBuildConfigurationFilter(configuration: String) -> BuildConfigurationFilter? {
        var table = MacroValueAssignmentTable(namespace: BuiltinMacros.namespace)
        table.push(BuiltinMacros.CONFIGURATION, literal: configuration)
        let scope = MacroEvaluationScope(table: table)
        return BuildConfigurationFilter(scope)
    }
}
