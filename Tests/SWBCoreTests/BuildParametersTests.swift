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

@Suite fileprivate struct BuildParametersTests {
    @Test
    func serializationDoesNotContainUnstableHash() throws {
        let action = BuildAction.build
        let configuration = "Debug"
        let activeRunDestination = RunDestinationInfo(
            platform: "macosx",
            sdk: "macosx12.3",
            sdkVariant: "macos",
            targetArchitecture: "arm64",
            supportedArchitectures: ["arm64", "x86_64"],
            disableOnlyActiveArch: false
        )
        let activeArchitecture = "arm64"
        let overrides = [
            "ENABLE_PREVIEWS": "NO",
            "ONLY_ACTIVE_ARCH": "YES",
        ]
        let commandLineOverrides = overrides
        let commandLineConfigOverridesPath: Path? = nil
        let commandLineConfigOverrides = overrides
        let environmentConfigOverridesPath: Path? = nil
        let environmentConfigOverrides = overrides
        let toolchainOverride: String? = nil
        let arena = ArenaInfo.buildArena(derivedDataRoot: Path("/Users/username/Library/Developer/Xcode/DerivedData"), enableIndexDataStore: true)

        let bp = BuildParameters(
            action: action,
            configuration: configuration,
            activeRunDestination: activeRunDestination,
            activeArchitecture: activeArchitecture,
            overrides: overrides,
            commandLineOverrides: commandLineOverrides,
            commandLineConfigOverridesPath: commandLineConfigOverridesPath,
            commandLineConfigOverrides: commandLineConfigOverrides,
            environmentConfigOverridesPath: environmentConfigOverridesPath,
            environmentConfigOverrides: environmentConfigOverrides,
            toolchainOverride: toolchainOverride,
            arena: arena
        )

        let data = try JSONEncoder().encode(bp)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("precomputedHash"), "The hash value isn't stable and shouldn't be encoded")

        let roundTrip = try JSONDecoder().decode(BuildParameters.self, from: data)
        #expect(bp == roundTrip)
    }
}
