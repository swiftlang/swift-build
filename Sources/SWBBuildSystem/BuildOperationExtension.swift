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

package import SWBUtil
package import SWBCore

/// An extension point for extending the build operation.
package struct BuildOperationExtensionPoint: ExtensionPoint {
    package typealias ExtensionProtocol = BuildOperationExtension

    package static let name = "BuildOperationExtensionPoint"

    package init() {}

    // MARK: - actual extension point

    package static func additionalEnvironmentVariables(pluginManager: PluginManager, fromEnvironment: @autoclosure () -> [String: String], parameters: @autoclosure () -> BuildParameters) throws -> [String: String] {
        let (fromEnvironment, parameters) = (fromEnvironment(), parameters())
        return try pluginManager.extensions(of: Self.self).reduce([:], { environment, ext in
            try environment.addingContents(of: ext.additionalEnvironmentVariables(fromEnvironment: fromEnvironment, parameters: parameters))
        })
    }
}

package protocol BuildOperationExtension: Sendable {
    /// Provides a dictionary of additional environment variables
    func additionalEnvironmentVariables(fromEnvironment: [String:String], parameters: BuildParameters) throws -> [String:String]
}
