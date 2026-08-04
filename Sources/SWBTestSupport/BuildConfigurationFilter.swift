//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

package import struct SWBProtocol.BuildConfigurationFilter

extension BuildConfigurationFilter {
    /// The set of default filters when filtering for **Debug**.
    package static let debugFilters: Set<BuildConfigurationFilter> = [
        BuildConfigurationFilter(buildConfiguration: "Debug")
    ]

    /// The set of default filters when filtering for **Release**.
    package static let releaseFilters: Set<BuildConfigurationFilter> = [
        BuildConfigurationFilter(buildConfiguration: "Release")
    ]
}
