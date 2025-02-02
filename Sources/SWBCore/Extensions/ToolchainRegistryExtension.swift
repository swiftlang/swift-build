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
private import SWBMacro

public struct ToolchainRegistryExtensionPoint: ExtensionPoint, Sendable {
    public typealias ExtensionProtocol = ToolchainRegistryExtension

    public static let name = "ToolchainRegistryExtensionPoint"

    public init() {}
}

public protocol ToolchainRegistryExtension: Sendable {
    func additionalToolchains(fs: any FSProxy) async -> [Toolchain]
}

extension ToolchainRegistryExtension {
    public func additionalToolchains(fs: any FSProxy) async -> [Toolchain] {
        []
    }
}
