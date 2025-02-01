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

import SWBCore

struct MacCatalystInfoExtension: SDKVariantInfoExtension {
    var supportsMacCatalystMacroNames: Set<String> {
        ["SUPPORTS_MACCATALYST"]
    }

    var disallowedMacCatalystMacroNames: Set<String> {
        ["DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER"]
    }

    var macCatalystDeriveBundleIDMacroNames: Set<String> {
        ["DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER"]
    }
}
