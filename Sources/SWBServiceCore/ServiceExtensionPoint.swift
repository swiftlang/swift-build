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
public struct ServiceExtensionPoint: ExtensionPoint {
    public typealias ExtensionProtocol = ServiceExtension

    public static let name = "ServiceExtensionPoint"

    public init() {}
}

public protocol ServiceExtension: Sendable {
    /// Called by services upon initialization.
    ///
    /// Clients are expected to use this as a place to register additional handlers on the service.
    func register(_ service: Service)
}
