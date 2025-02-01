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

extension Diagnostic {
    public static func unavailableTargetTypeDiagnosticString(targetTypeDescription: String, platformInfoLookup: any PlatformInfoLookup, buildPlatforms: Set<BuildVersion.Platform>) -> String {
        return "\(targetTypeDescription)s are not available when building for \(buildPlatforms.displayName(infoLookup: platformInfoLookup))."
    }
}
