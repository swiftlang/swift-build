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

package import class SWBCore.Core
package import class SWBCore.SDK
package import class SWBCore.SDKVariant
package import struct SWBCore.MacCatalystInfo
package import SWBUtil
package import SWBProtocol
import Testing

package struct TestSDKInfo: Sendable {
    package let name: String
    package let path: Path
    package let version: String
    package let buildVersion: ProductBuildVersion?
    package let defaultDeploymentTarget: String

    private init(name: String, path: Path, version: String, buildVersion: ProductBuildVersion?, defaultDeploymentTarget: String) {
        self.name = name
        self.path = path
        self.version = version
        self.buildVersion = buildVersion
        self.defaultDeploymentTarget = defaultDeploymentTarget
    }

    package init(_ sdk: SDK) {
        var versionString: String
        if let version = sdk.version?.description {
            versionString = version
        } else {
            let pathParts = sdk.path.basename.split(separator: ".")
            precondition(pathParts.count > 1, "could not determine \(sdk.canonicalName) SDK version from path: \(sdk.path.str)")
            versionString = pathParts[0].lowercased().withoutPrefix(sdk.canonicalName) + "." + pathParts[1]
        }
        self.init(name: sdk.canonicalName, path: sdk.path, version: versionString, buildVersion: sdk.productBuildVersion.map { try? ProductBuildVersion($0) } ?? nil, defaultDeploymentTarget: sdk.defaultDeploymentTarget?.description ?? versionString)
    }

    package static func undefined() -> TestSDKInfo {
        TestSDKInfo(name: "/<undefined-sdk-name>", path: Path("/<undefined-sdk-path>"), version: "<undefined-sdk-version>", buildVersion: nil, defaultDeploymentTarget: "<undefined-sdk-deployment-target>")
    }
}

package struct TestSDKVariantInfo: Sendable {
    package let defaultDeploymentTarget: String

    private init(defaultDeploymentTarget: String) {
        self.defaultDeploymentTarget = defaultDeploymentTarget
    }

    init(_ sdkVariant: SDKVariant) {
        self.init(defaultDeploymentTarget: sdkVariant.defaultDeploymentTarget?.description ?? "13.1")
    }

    package static func undefined() -> TestSDKVariantInfo {
        TestSDKVariantInfo(defaultDeploymentTarget: "<undefined-sdk-deployment-target>")
    }
}

extension CoreBasedTests {
    package func getSDKPath(platform: BuildVersion.Platform) async throws -> Path {
        let core = try await getCore()
        switch platform {
        case .macOS, .macCatalyst:
            return core.loadSDK(name: "macosx").path
        case .iOS:
            return core.loadSDK(name: "iphoneos").path
        case .iOSSimulator:
            return core.loadSDK(name: "iphonesimulator").path
        case .tvOS:
            return core.loadSDK(name: "appletvos").path
        case .tvOSSimulator:
            return core.loadSDK(name: "appletvsimulator").path
        case .watchOS:
            return core.loadSDK(name: "watchos").path
        case .watchOSSimulator:
            return core.loadSDK(name: "watchsimulator").path
        case .xrOS:
            return core.loadSDK(name: "xros").path
        case .xrOSSimulator:
            return core.loadSDK(name: "xrsimulator").path
        case .driverKit:
            return core.loadSDK(name: "driverkit").path
        default:
            return Path("/<undefined-sdk-path>")
        }
    }

    /// Utility method to compute the build directories for a build.
    /// - parameter baseDir: The root directory under which all the build directories will be located.
    /// - parameter buildType: A string indicating the type of build, distinguishing it from other builds in the same test. This can be a usefully symbolic name, but functionally is the subdirectory of the `baseDir` in which the root dirs are defined.
    /// - returns: A tuple with the `SYMROOT`, `OBJROOT` and `DSTROOT` absolute paths.
    package func buildDirs(in baseDir: Path, for buildType: String) -> (symroot: String, objroot: String, dstroot: String) {
        let buildTypePath = baseDir.join(buildType)
        return (buildTypePath.join("sym").str, buildTypePath.join("obj").str, buildTypePath.join("dst").str)
    }
}

extension Core {
    package func loadSDK(name: String) -> TestSDKInfo {
        guard let sdk = sdkRegistry.lookup(nameOrPath: name, basePath: .root) else {
            return TestSDKInfo.undefined()
        }

        return TestSDKInfo(sdk)
    }

    package func loadSDKVariant(name: String, sdkName: String) -> TestSDKVariantInfo {
        guard let sdk = sdkRegistry.lookup(nameOrPath: sdkName, basePath: .root), let variant = sdk.variant(for: name) else {
            return TestSDKVariantInfo.undefined()
        }

        return TestSDKVariantInfo(variant)
    }

    package func loadSDK(_ runDestination: RunDestinationInfo) -> TestSDKInfo {
        guard let sdk = sdkRegistry.lookup(nameOrPath: runDestination.sdk, basePath: .root) else {
            return TestSDKInfo.undefined()
        }
        return TestSDKInfo(sdk)
    }

    package var macCatalystSDKVariant: TestSDKVariantInfo {
        loadSDKVariant(name: MacCatalystInfo.sdkVariantName, sdkName: "macosx")
    }
}
