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

// FIXME: I'm not thrilled with this approach, but for now this is my best idea for isolating some of the nastiness of the XCCodeSignContext hierarchy.

public enum EntitlementsVariant: Int, Serializable, Sendable {
    case signed
    case simulated
}

/// Provides contextual behavior for code signing based on the type of platform being targeted.
public protocol PlatformSigningContext
{
    func adHocSigningAllowed(_ scope: MacroEvaluationScope) -> Bool

    func useAdHocSigningIfSigningIsRequiredButNotSpecified(_ scope: MacroEvaluationScope) -> Bool

    func shouldPassEntitlementsFileContentToCodeSign() -> Bool

    func requiresEntitlements(_ scope: MacroEvaluationScope, hasProfile: Bool, productFileType: FileTypeSpec) -> Bool

    func supportsAppSandboxAndHardenedRuntime() -> Bool
}

extension PlatformSigningContext
{
    /// Returns `true` is ad hoc signing is allowed for the platform.
    ///
    /// This is only in the signing context because some contexts want to call it from `useAdHocSigningIfSigningIsRequiredButNotSpecified()`.
    @_spi(Testing) public func adHocSigningAllowed(_ scope: MacroEvaluationScope) -> Bool
    {
        // Yup, amazingly AD_HOC_CODE_SIGNING_ALLOWED is considered to be true if either it is defined to be true *or* if it is empty.  It has to be explicitly false to be false.  I infer this is for compatibility reasons so the platforms or SDKs don't need to be mass-revved.
        return scope.evaluateAsString(BuiltinMacros.AD_HOC_CODE_SIGNING_ALLOWED).isEmpty || scope.evaluate(BuiltinMacros.AD_HOC_CODE_SIGNING_ALLOWED)
    }

    /// Returns `true` if ad hoc signing should be used if signing is required but no signing identity is provided.
    @_spi(Testing) public func useAdHocSigningIfSigningIsRequiredButNotSpecified(_ scope: MacroEvaluationScope) -> Bool
    {
        return false
    }

    @_spi(Testing) public func shouldPassEntitlementsFileContentToCodeSign() -> Bool
    {
        return true
    }

    @_spi(Testing) public func requiresEntitlements(_ scope: MacroEvaluationScope, hasProfile: Bool, productFileType: FileTypeSpec) -> Bool
    {
        return hasProfile || scope.evaluate(BuiltinMacros.ENTITLEMENTS_REQUIRED)
    }

    @_spi(Testing) public func supportsAppSandboxAndHardenedRuntime() -> Bool {
        return false
    }
}


/// Provides behavior for code signing for the macOS platform.
@_spi(Testing) public struct MacSigningContext: PlatformSigningContext
{
    @_spi(Testing) public func supportsAppSandboxAndHardenedRuntime() -> Bool {
        return true
    }
}


/// Provides behavior for code signing for device platforms.
@_spi(Testing) public struct DeviceSigningContext: PlatformSigningContext
{
    @_spi(Testing) public func useAdHocSigningIfSigningIsRequiredButNotSpecified(_ scope: MacroEvaluationScope) -> Bool
    {
        return adHocSigningAllowed(scope)
    }

    @_spi(Testing) public func requiresEntitlements(_ scope: MacroEvaluationScope, hasProfile: Bool, productFileType: FileTypeSpec) -> Bool
    {
        // Entitlements are only required if what we're signing is not a framework.
        return productFileType.isFramework ? false : (hasProfile || scope.evaluate(BuiltinMacros.ENTITLEMENTS_REQUIRED))
    }
}


/// Provides behavior for code signing for simulator platforms.
@_spi(Testing) public struct SimulatorSigningContext: PlatformSigningContext
{
    @_spi(Testing) public func shouldPassEntitlementsFileContentToCodeSign() -> Bool
    {
        // We don't want to codesign with entitlements because we put them in the LD_ENTITLEMENTS_SECTION.
        return false
    }

    @_spi(Testing) public func requiresEntitlements(_ scope: MacroEvaluationScope, hasProfile: Bool, productFileType: FileTypeSpec) -> Bool
    {
        // We don't need entitlements when building for the simulator.
        return false
    }
}

