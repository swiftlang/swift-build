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

/// Utility to avoid duplicating implementation details about macCatalyst.
public struct MacCatalystInfo {
    /// Effective platform name to use for the `SWBLocalizationInfo` API.
    public static let localizationEffectivePlatformName = "maccatalyst"

    /// Bundle identifier prefix for targets which request a derived bundle identifier. Includes the ending period.
    public static let bundleIdPrefix = "maccatalyst."

    /// `BUILT_PRODUCTS_DIR` suffix for public SDK builds.
    public static let publicSDKBuiltProductsDirSuffix = "-maccatalyst"

    /// Name of the SDK variant used for the `SDK_VARIANT` build setting.
    public static let sdkVariantName = "iosmac"

    private init() { }
}
