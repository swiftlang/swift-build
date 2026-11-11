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

import Foundation
import Testing

import SWBCore
import SWBProtocol
import SWBTestSupport
import SWBUtil

@Suite
fileprivate struct SwiftSDKPlatformOptInTests: CoreBasedTests {
    /// A client opts in to the platform of a Swift SDK. Without it, the platform is the one of the triple, as before.
    @Test(.requireHostOS(.macOS))
    func platformOfASwiftSDKIsOptIn() async throws {
        let core = try await getCore()
        let triple = "arm64-apple-macos15.0"

        func resolvedDestination(swiftSDKPlatform: String?) throws -> SWBCore.RunDestinationInfo {
            var payload = SWBProtocol.RunDestinationInfo(
                buildTarget: .swiftSDK(sdkManifestPath: Path("/tmp/swift-sdk.json"), triple: triple),
                targetArchitecture: "arm64",
                supportedArchitectures: OrderedSet(["arm64"]),
                disableOnlyActiveArch: false,
                hostTargetedPlatform: nil
            )
            payload.swiftSDKPlatform = swiftSDKPlatform
            return try SWBCore.RunDestinationInfo(from: payload, core: core)
        }

        #expect(try resolvedDestination(swiftSDKPlatform: nil).platform == "macosx")
        #expect(try resolvedDestination(swiftSDKPlatform: "none").platform == "none")
    }
}
