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
import SWBUtil
import SWBProtocol
import SWBTestSupport
import SWBCore

@Suite(.performance)
fileprivate struct BuildParameterPerfTests: PerfTests {
    @Test
    func init_X50_000() async {
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
        let arena = ArenaInfo.indexBuildArena(derivedDataRoot: Path("/Users/username/Library/Developer/Xcode/DerivedData"))

        await measure {
            for _ in 0..<50_000 {
                _ = BuildParameters(
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
            }
        }
    }

    @Test
    func hash_X10_000_000() async {
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
        let arena = ArenaInfo.indexBuildArena(derivedDataRoot: Path("/Users/username/Library/Developer/Xcode/DerivedData"))

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

        await measure {
            var hasher = Hasher()
            for _ in 0..<10_000_000 {
                bp.hash(into: &hasher)
            }
        }
    }

    @Test
    func minimalInit_X100_000() async {
        await measure {
            for _ in 0..<100_000 {
                _ = BuildParameters(
                    action: .build,
                    configuration: "Debug"
                )
            }
        }
    }

    @Test
    func minimalHash_X10_000_000() async {
        let bp = BuildParameters(
            action: .build,
            configuration: "Debug"
        )
        await measure {
            var hasher = Hasher()
            for _ in 0..<10_000_000 {
                bp.hash(into: &hasher)
            }
        }
    }
}
