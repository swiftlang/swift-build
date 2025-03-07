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
public import Foundation

/// An extension point for extending the build operation.
public struct SpecificationsExtensionPoint: ExtensionPoint {
    public typealias ExtensionProtocol = SpecificationsExtension

    public static let name = "SpecificationsExtensionPoint"

    public init() {}

    // MARK: - actual extension point

    public static func specificationTypes(pluginManager: PluginManager) -> [any SpecType.Type] {
        return pluginManager.extensions(of: Self.self).reduce([]) { specs, ext in
            specs.appending(contentsOf: ext.specificationTypes())
        }
    }

    public static func specificationClasses(pluginManager: PluginManager) -> [any SpecIdentifierType.Type] {
        return pluginManager.extensions(of: Self.self).reduce([]) { specs, ext in
            specs.appending(contentsOf: ext.specificationClasses())
        }
    }

    public static func specificationClassesClassic(pluginManager: PluginManager) -> [any SpecClassType.Type] {
        return pluginManager.extensions(of: Self.self).reduce([]) { specs, ext in
            specs.appending(contentsOf: ext.specificationClassesClassic())
        }
    }

    public static func specificationImplementations(pluginManager: PluginManager) -> [any SpecImplementationType.Type] {
        return pluginManager.extensions(of: Self.self).reduce([]) { specs, ext in
            specs.appending(contentsOf: ext.specificationImplementations())
        }
    }
}

public protocol SpecificationsExtension: Sendable {
    /// Returns the bundle containing the `.xcspec` files.
    func specificationFiles(resourceSearchPaths: [Path]) -> Bundle?
    func specificationDomains() -> [String: [String]]
    func specificationTypes() -> [any SpecType.Type]
    func specificationClasses() -> [any SpecIdentifierType.Type]
    func specificationClassesClassic() -> [any SpecClassType.Type]
    func specificationImplementations() -> [any SpecImplementationType.Type]

    /// Returns the search paths for two use cases: finding the sole remaining `.xcbuildrules` file, and finding executable scripts next to `.xcspec` files.
    func specificationSearchPaths(resourceSearchPaths: [Path]) -> [URL]
}

extension SpecificationsExtension {
    public func specificationFiles(resourceSearchPaths: [Path]) -> Bundle? { nil }
    public func specificationDomains() -> [String: [String]] { [:] }
    public func specificationTypes() -> [any SpecType.Type] { [] }
    public func specificationClasses() -> [any SpecIdentifierType.Type] { [] }
    public func specificationClassesClassic() -> [any SpecClassType.Type] { [] }
    public func specificationImplementations() -> [any SpecImplementationType.Type] { [] }
    public func specificationSearchPaths(resourceSearchPaths: [Path]) -> [URL] { [] }

    public func findResourceBundle(nameWhenInstalledInToolchain: String, resourceSearchPaths: [Path], defaultBundle: @autoclosure () -> Bundle?) -> Bundle? {
        for searchPath in resourceSearchPaths {
            for bundleBasename in ["\(nameWhenInstalledInToolchain).bundle", "\(nameWhenInstalledInToolchain).resources"] {
                if let bundle = Bundle(path: searchPath.join(bundleBasename).str) {
                    return bundle
                }
            }
        }
        return defaultBundle()
    }
}
