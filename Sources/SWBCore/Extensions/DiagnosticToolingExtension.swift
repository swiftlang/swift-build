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

/// An extension point for tooling used to diagnose build system issues..
public struct DiagnosticToolingExtensionPoint: ExtensionPoint {
    public typealias ExtensionProtocol = DiagnosticToolingExtension

    public static let name = "DiagnosticToolingExtensionPoint"

    public init() {}
}

public protocol DiagnosticToolingExtension: Sendable {
    func initialize()
}
