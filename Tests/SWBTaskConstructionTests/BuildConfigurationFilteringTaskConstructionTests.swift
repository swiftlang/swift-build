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
import SWBTestSupport
import SWBCore
import struct SWBProtocol.BuildConfigurationFilter
import struct SWBProtocol.RunDestinationInfo
import SWBUtil

@Suite
fileprivate struct BuildConfigurationFilteringTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func buildConfigurationFiltering_Debug() async throws {
        // No filter
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", expectFiltered: false)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", buildConfigurationFilters: BuildConfigurationFilter.debugFilters, expectFiltered: false)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", buildConfigurationFilters: BuildConfigurationFilter.debugAndReleaseFilters, expectFiltered: false)

        // Filter
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", buildConfigurationFilters: BuildConfigurationFilter.releaseFilters, expectFiltered: true)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Debug", buildConfigurationFilters: BuildConfigurationFilter.unknownFilters, expectFiltered: true)
    }

    @Test(.requireSDKs(.macOS))
    func buildConfigurationFiltering_Release() async throws {
        // No filter
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", expectFiltered: false)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", buildConfigurationFilters: BuildConfigurationFilter.releaseFilters, expectFiltered: false)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", buildConfigurationFilters: BuildConfigurationFilter.debugAndReleaseFilters, expectFiltered: false)

        // Filter
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", buildConfigurationFilters: BuildConfigurationFilter.debugFilters, expectFiltered: true)
        try await testBuildConfigurationFiltering(runDestination: .macOS, buildConfiguration: "Release", buildConfigurationFilters: BuildConfigurationFilter.unknownFilters, expectFiltered: true)
    }
}

fileprivate extension BuildConfigurationFilter {
    /// The set of default filters when filtering for both Debug and Release.
    static let debugAndReleaseFilters: Set<BuildConfigurationFilter> = BuildConfigurationFilter.debugFilters.union(BuildConfigurationFilter.releaseFilters)

    /// Set of filters for an unknown build configuration.
    static let unknownFilters: Set<BuildConfigurationFilter> = Set([BuildConfigurationFilter(buildConfiguration: "Unknown")])
}
