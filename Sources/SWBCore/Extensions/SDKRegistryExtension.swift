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

public import SWBUtil

public struct SDKRegistryExtensionPoint: ExtensionPoint {
    public typealias ExtensionProtocol = SDKRegistryExtension

    public static let name = "SDKRegistryExtensionPoint"

    public init() {}
}

public protocol SDKRegistryExtension: Sendable {
    var supportedSDKCanonicalNameSuffixes: Set<String> { get }

    func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: Platform?, data: [String: PropertyListItem])]
}

extension SDKRegistryExtension {
    public var supportedSDKCanonicalNameSuffixes: Set<String> {
        []
    }

    public func additionalSDKs(context: any SDKRegistryExtensionAdditionalSDKsContext) async throws -> [(path: Path, platform: Platform?, data: [String: PropertyListItem])] {
        []
    }
}

public protocol SDKRegistryExtensionAdditionalSDKsContext: Sendable {
    var hostOperatingSystem: OperatingSystem { get }
    var platformRegistry: PlatformRegistry { get }
    var fs: any FSProxy { get }
}
