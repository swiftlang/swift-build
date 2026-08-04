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

    // MARK: - Empty filter set

    @Test
    func emptyFiltersAlwaysMatch() {
        let context = BuildConfigurationFilter(buildConfiguration: "Debug")
        #expect(context.matches([]))
    }

    // MARK: - Inclusion matching

    @Test
    func matchesSameConfiguration() {
        let context = BuildConfigurationFilter(buildConfiguration: "Debug")
        let filters: Set<BuildConfigurationFilter> = [
            BuildConfigurationFilter(buildConfiguration: "Debug")
        ]
        #expect(context.matches(filters))
    }

    @Test
    func doesNotMatchDifferentConfiguration() {
        let context = BuildConfigurationFilter(buildConfiguration: "Release")
        let filters: Set<BuildConfigurationFilter> = [
            BuildConfigurationFilter(buildConfiguration: "Debug")
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func matchesOneOfMultipleFilters() {
        let context = BuildConfigurationFilter(buildConfiguration: "Debug")
        let filters: Set<BuildConfigurationFilter> = [
            BuildConfigurationFilter(buildConfiguration: "Debug"),
            BuildConfigurationFilter(buildConfiguration: "Release"),
        ]
        #expect(context.matches(filters))
    }

    @Test
    func doesNotMatchAnyFilter() {
        let context = BuildConfigurationFilter(buildConfiguration: "Profile")
        let filters: Set<BuildConfigurationFilter> = [
            BuildConfigurationFilter(buildConfiguration: "Debug"),
            BuildConfigurationFilter(buildConfiguration: "Release"),
        ]
        #expect(!context.matches(filters))
    }

    // MARK: - Optional BuildConfigurationFilter matching

    @Test
    func nilContextMatchesEmptyFilters() {
        let context: BuildConfigurationFilter? = nil
        #expect(context.matches([]))
    }

    @Test
    func nilContextDoesNotMatchNonEmptyFilters() {
        let context: BuildConfigurationFilter? = nil
        let filters: Set<BuildConfigurationFilter> = [
            BuildConfigurationFilter(buildConfiguration: "Debug"),
        ]
        #expect(!context.matches(filters))
    }

    @Test
    func someContextDelegatesToWrappedValue() {
        let context: BuildConfigurationFilter? = BuildConfigurationFilter(buildConfiguration: "Debug")
        let filters: Set<BuildConfigurationFilter> = [
            BuildConfigurationFilter(buildConfiguration: "Debug"),
        ]
        #expect(context.matches(filters))
    }

    private func createBuildConfigurationFilter(configuration: String) -> BuildConfigurationFilter {
        var table = MacroValueAssignmentTable(namespace: BuiltinMacros.namespace)
        table.push(BuiltinMacros._RESOLVED_CONFIGURATION, literal: configuration)
        let scope = MacroEvaluationScope(table: table)
        return BuildConfigurationFilter(scope)
    }

    @Test(arguments: ["Debug", "Release"])
    func initFromScope(_ configuration: String) {
        let filter = createBuildConfigurationFilter(configuration: configuration)
        #expect(filter == BuildConfigurationFilter(buildConfiguration: configuration))
    }
}
