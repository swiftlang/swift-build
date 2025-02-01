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

public import Foundation

import SWBUtil

public struct SWBSystemInfo: Sendable {
    public static func `default`() throws -> Self {
        let processInfo = ProcessInfo.processInfo
        return Self(
            operatingSystemVersion: processInfo.operatingSystemVersion,
            productBuildVersion: try processInfo.productBuildVersion().description,
            nativeArchitecture: Architecture.host.stringValue ?? "undefined_arch")
    }

    public let operatingSystemVersion: OperatingSystemVersion
    public let productBuildVersion: String
    public let nativeArchitecture: String

    public init(operatingSystemVersion: OperatingSystemVersion, productBuildVersion: String, nativeArchitecture: String) {
        self.operatingSystemVersion = operatingSystemVersion
        self.productBuildVersion = productBuildVersion
        self.nativeArchitecture = nativeArchitecture
    }
}
