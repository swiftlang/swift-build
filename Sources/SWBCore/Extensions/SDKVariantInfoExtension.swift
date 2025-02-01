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

/// An extension point for services.
public struct SDKVariantInfoExtensionPoint: ExtensionPoint {
    public typealias ExtensionProtocol = SDKVariantInfoExtension

    public static let name = "SDKVariantInfoExtensionPoint"

    public init() {}
}

// FIXME: Generalize this to be less specific to Mac Catalyst
public protocol SDKVariantInfoExtension: Sendable {
    var supportsMacCatalystMacroNames: Set<String> { get }
    var disallowedMacCatalystMacroNames: Set<String> { get }
    var macCatalystDeriveBundleIDMacroNames: Set<String> { get }
}
