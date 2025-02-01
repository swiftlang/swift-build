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

/// Client-side delegate protocol for collecting localization information.
public protocol SWBLocalizationDelegate: SWBPlanningOperationDelegate {}

/// Response for a `getLocalizationInfo` request.
public struct SWBLocalizationInfo: Sendable {
    /// Localization info keyed by target GUID.
    public let infoByTarget: [String: SWBLocalizationTargetInfo]
}

/// Localization info corresponding to a particular target.
public struct SWBLocalizationTargetInfo: Sendable {
    /// Paths to source .xcstrings files used as inputs in this target.
    ///
    /// This collection specifically contains compilable files, AKA files in a Resources phase (not a Copy Files phase).
    public let compilableXCStringsPaths: Set<String>

    /// Paths to .stringsdata files produced by this target, grouped by build attributes such as platform and architecture.
    public let stringsdataPathsByBuildPortion: [SWBLocalizationBuildPortion: Set<String>]

    /// Paths to all .stringsdata files produced by this target.
    public var producedStringsdataPaths: Set<String> {
        return stringsdataPathsByBuildPortion.values.reduce([]) { $0.union($1) }
    }
}

/// Describes attributes of a portion of a build, for example platform and architecture, that are relevant to distinguishing localized strings extracted during a build.
public struct SWBLocalizationBuildPortion: Sendable, Hashable {
    /// The name of the platform we were building for.
    ///
    /// Mac Catalyst is treated as its own platform.
    public let effectivePlatformName: String

    /// The name of the build variant, e.g. "normal"
    public let variant: String

    /// The name of the architecture we were building for.
    public let architecture: String

    public init(effectivePlatformName: String, variant: String, architecture: String) {
        self.effectivePlatformName = effectivePlatformName
        self.variant = variant
        self.architecture = architecture
    }
}
