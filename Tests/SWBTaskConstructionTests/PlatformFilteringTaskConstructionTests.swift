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

import Testing
import SWBTestSupport
import SWBCore
import struct SWBProtocol.PlatformFilter
import struct SWBProtocol.RunDestinationInfo
import SWBUtil

@Suite
fileprivate struct PlatformFilteringTaskConstructionTests: CoreBasedTests {
    @Test(.requireSDKs(.macOS))
    func platformFiltering_macCatalyst() async throws {
        // No filter
        try await testPlatformFiltering(runDestination: .macCatalyst, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.macOSAndMacCatalystFilters, expectFiltered: false)

        // Filter
        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.iOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.macOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.linuxFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.macOSAndUnknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .macCatalyst, platformFilters: PlatformFilter.unknownFilters, expectFiltered: true)
    }

    @Test(.requireSDKs(.macOS))
    func platformFiltering_macOS() async throws {

        // No filter
        try await testPlatformFiltering(runDestination: .macOS, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.macOSFilters, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.macOSAndMacCatalystFilters, expectFiltered: false)

        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.macOSAndUnknownFilters, expectFiltered: false)

        // Filter
        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.iOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.linuxFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .macOS, platformFilters: PlatformFilter.unknownFilters, expectFiltered: true)
    }

    @Test(.requireSDKs(.iOS))
    func platformFiltering_iOS() async throws {

        // No filter
        try await testPlatformFiltering(runDestination: .iOS, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .iOSSimulator, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.iOSFilters, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.iOSFilters, expectFiltered: false)

        // Filter
        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.macOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.macOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.macOSAndMacCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.macOSAndMacCatalystFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.linuxFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.linuxFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.macOSAndUnknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.macOSAndUnknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOS, platformFilters: PlatformFilter.unknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .iOSSimulator, platformFilters: PlatformFilter.unknownFilters, expectFiltered: true)
    }

    @Test(.requireSDKs(.tvOS))
    func platformFiltering_tvOS() async throws {

        // No filter
        try await testPlatformFiltering(runDestination: .tvOS, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: false)

        // Filter
        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.iOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.iOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.macOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.macOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.macOSAndMacCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.macOSAndMacCatalystFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.linuxFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.linuxFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.macOSAndUnknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.macOSAndUnknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOS, platformFilters: PlatformFilter.unknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .tvOSSimulator, platformFilters: PlatformFilter.unknownFilters, expectFiltered: true)
    }

    @Test(.requireSDKs(.watchOS))
    func platformFiltering_watchOS() async throws {

        // No filter
        try await testPlatformFiltering(runDestination: .watchOS, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: false)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: false)

        // Filter
        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.iOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.iOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.macOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.macOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.macOSAndMacCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.macOSAndMacCatalystFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.linuxFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.linuxFilters, expectFiltered: true)

        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.macOSAndUnknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.macOSAndUnknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOS, platformFilters: PlatformFilter.unknownFilters, expectFiltered: true)
        try await testPlatformFiltering(runDestination: .watchOSSimulator, platformFilters: PlatformFilter.unknownFilters, expectFiltered: true)
    }

    @Test(.requireSDKs(.driverKit))
    func platformFiltering_DriverKit() async throws {

        // No filter
        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, expectFiltered: false)
        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: false)

        // Filter
        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.iOSFilters, expectFiltered: true)
        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.macOSFilters, expectFiltered: true)
        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: true)
        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: true)

        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.macOSAndMacCatalystFilters, expectFiltered: true)

        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.linuxFilters, expectFiltered: true)

        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.macOSAndUnknownFilters, expectFiltered: true)
        try await testPlatformFiltering(.driverExtension, runDestination: .driverKit, platformFilters: PlatformFilter.unknownFilters, expectFiltered: true)
    }

    @Test(.requireSDKs(.linux))
    func platformFiltering_Linux() async throws {

        // No filter
        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, platformFilters: PlatformFilter.linuxFilters, expectFiltered: false)

        // Filter
        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, expectFiltered: false)

        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, platformFilters: PlatformFilter.iOSFilters, expectFiltered: true)
        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, platformFilters: PlatformFilter.macCatalystFilters, expectFiltered: true)
        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, platformFilters: PlatformFilter.macOSFilters, expectFiltered: true)
        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, platformFilters: PlatformFilter.tvOSFilters, expectFiltered: true)
        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, platformFilters: PlatformFilter.watchOSFilters, expectFiltered: true)
        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, platformFilters: PlatformFilter.driverKitFilters, expectFiltered: true)

        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, platformFilters: PlatformFilter.macOSFilters.union(PlatformFilter.macCatalystFilters), expectFiltered: true)

        try await testPlatformFiltering(.commandLineTool, runDestination: .linux, platformFilters: PlatformFilter.iOSFilters, expectFiltered: true)
    }
}

fileprivate extension PlatformFilter {
    /// The set of default filters when filtering for macOS and Mac Catalyst.
    static let macOSAndMacCatalystFilters: Set<PlatformFilter> = PlatformFilter.macOSFilters.union(PlatformFilter.macCatalystFilters)

    /// Set of filters for macOS and an unknown platform.
    static let macOSAndUnknownFilters: Set<PlatformFilter> = PlatformFilter.macOSFilters.union(PlatformFilter.unknownFilters)

    /// Set of filters for an unknown platform.
    static let unknownFilters: Set<PlatformFilter> = Set([PlatformFilter(platform: "unknown", environment: "unknown")])
}
