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
public import SWBMacro

/// Provides a common mechanism to computing a wrapped bundle identifier (e.g. the test runner app's bundle identifier).
public func wrappedBundleIdentifier(for bundleIdentifier: String) -> String {
    return "\(bundleIdentifier).xctrunner"
}

/// Compute the bundle identifier used for code signing.
///
/// - Parameters:
///   - scope: The scope in which to expand build settings.
///   - bundleIdentifierFromInfoPlist: Bundle identifier from the target's Info.plist
/// - Returns: The bundle identifier to be used for code signing.
public func computeBundleIdentifier(from scope: MacroEvaluationScope, bundleIdentifierFromInfoPlist: MacroStringExpression) -> String {
    let productBundleIdentifier = scope.evaluate(BuiltinMacros.PRODUCT_BUNDLE_IDENTIFIER)
    if !productBundleIdentifier.isEmpty {
        // When a test bundle is being signed **AND** that test bundle is being hosted in a test runner, then the bundle identifier should actually match the test runner and **not** the test bundle.
        if scope.evaluate(BuiltinMacros.USES_XCTRUNNER) {
            return wrappedBundleIdentifier(for: productBundleIdentifier)
        }
        return productBundleIdentifier
    }

    // If PRODUCT_BUNDLE_IDENTIFIER is not defined, then use the value from the Info.plist.
    return scope.evaluate(bundleIdentifierFromInfoPlist, lookup: nil)
}


/// Compute the identifier of the signing certificate to use.
///
/// - Parameters:
///   - scope: The scope in which to expand build settings.
///   - platform: The platform we are building for.
/// - Returns: The signing certificate identifier to use.
public func computeSigningCertificateIdentifier(from scope: MacroEvaluationScope, platform: Platform?) -> String {
    if platform?.isSimulator == true {
        return "-" // always Ad-hoc sign for simulator even if CODE_SIGN_IDENTITY has been overridden
    }
    return scope.evaluate(BuiltinMacros.CODE_SIGN_IDENTITY)
}


/// Determine the path for entitlements to use for code signing.
///
/// - Parameters:
///   - scope: The scope in which to expand build settings.
///   - project: The project that is being signed.
///   - sdk: The SDK we are building with or `nil` if unknown.
///   - fs: Filesystem proxy used for checking if entitlements files exist.
/// - Returns: The path for entitlements to use.
public func lookupEntitlementsFilePath(from scope: MacroEvaluationScope, project: Project, sdk: SDK?, fs: any FSProxy) -> Path? {
    let path = scope.evaluate(BuiltinMacros.CODE_SIGN_ENTITLEMENTS)
    if !path.isEmpty {
        return path.isAbsolute ? path : project.sourceRoot.join(path)
    }

    if scope.evaluate(BuiltinMacros.ENTITLEMENTS_REQUIRED) {
        if let sdk = sdk {
            let path = sdk.path.join(Path("Entitlements.plist"))
            if fs.exists(path) {
                return path
            }
        }
    }

    return nil
}
