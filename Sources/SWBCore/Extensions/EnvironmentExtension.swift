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

/// An extension point for extending the build operation.
public struct EnvironmentExtensionPoint: ExtensionPoint {
    public typealias ExtensionProtocol = EnvironmentExtension

    public static let name = "EnvironmentExtensionPoint"

    public init() {}

    // MARK: - actual extension point

    public static func additionalEnvironmentVariables(pluginManager: PluginManager, context: any EnvironmentExtensionAdditionalEnvironmentVariablesContext) async throws -> [String: String] {
        var env: [String: String] = [:]
        for ext in pluginManager.extensions(of: Self.self) {
            try await env.merge(ext.additionalEnvironmentVariables(context: context), uniquingKeysWith: { _, new in new })
        }
        return env
    }
}

public protocol EnvironmentExtension: Sendable {
    func additionalEnvironmentVariables(context: any EnvironmentExtensionAdditionalEnvironmentVariablesContext) async throws -> [String: String]
}

public protocol EnvironmentExtensionAdditionalEnvironmentVariablesContext: Sendable {
    var hostOperatingSystem: OperatingSystem { get }
    var fs: any FSProxy { get }
}
