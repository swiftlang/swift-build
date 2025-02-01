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

// FIXME: Should we add some general mechanism for representing NSErrors in Swift Build?  If so, we should also add a general transport structure to send it over the message pipe.
//
/// An error from computation of provisioning task inputs.
public struct ProvisioningTaskInputError: Codable, Hashable, Sendable
{
    public let description: String
    public let recoverySuggestion: String?
}

/// A ProvisioningTaskInputs struct encapsulates all of the parameters necessary to sign and provision a product.
///
/// There are four flavors of signing:
///
/// 1. Unsigned.
/// 2. Ad-hoc signed.
/// 3. Signed with a profile.
/// 4. Signed without a profile.
public struct ProvisioningTaskInputs: Codable, Hashable, Sendable
{
    /// The SHA1 hash of the signing certificate, suitable for passing to the `codesign` tool.
    ///
    /// If this is nil, then `identityName`, `profileName`, `profileUUID` and `designatedRequirements` will all also be nil.
    public let identityHash: String?
    /// The serial number of the signing certificate, suitable for passing to xcsigningtool
    public let identitySerialNumber: String?
    /// The name of the signing certificate, suitable for presentation to the user.
    public let identityName: String?
    /// The name of the provisioning profile, suitable for presentation to the user.
    public let profileName: String?
    /// The UUID of the provisioning profile, suitable for use as the value of `EXPANDED_PROVISIONING_PROFILE`.
    public let profileUUID: String?
    /// The path on disk of the provisioning profile, suitable for passing to the product packaging utility task.
    public let profilePath: Path?
    /// The designated requirements string suitable for passing to the `codesign` tool.  Note that this is *not* fully evaluated, it may need `$(CODE_SIGN_IDENTIFIER)` to be evaluated before signing.
    public let designatedRequirements: String?
    /// The fully evaluated and merged entitlements dictionary, suitable for passing to the product packaging utility task and to the `codesign` tool.
    public let signedEntitlements: PropertyListItem
    /// The fully evaluated and merged simulated entitlements dictionary, suitable for passing to the product packaging utility task and to the linker.
    public let simulatedEntitlements: PropertyListItem
    /// The evaluated value of `$(AppIdentifierPrefix)`.
    public let appIdentifierPrefix: String?
    /// The evaluated value of `$(TeamIdentifierPrefix)`.
    public let teamIdentifierPrefix: String?
    /// Whether the team is an enterprise team.
    public let isEnterpriseTeam: Bool?
    /// Whether the signing operation should invoke xcsigningtool.
    public let useSigningTool: Bool?
    /// Whether the signing operation involves cloud signing.
    public let signingToolKeyPath: String?
    /// Whether the signing operation involves cloud signing.
    public let signingToolKeyID: String?
    /// Whether the signing operation involves cloud signing.
    public let signingToolKeyIssuerID: String?
    /// The keychain path override.
    public let keychainPath: String?
    /// Any errors here should be presented to the user as signing failures, and signing should not proceed.
    public let errors: [ProvisioningTaskInputError]
    /// Any warnings here should be presented to the user, but signing may still proceed.
    public let warnings: [String]

    public init(identityHash: String? = nil, identitySerialNumber: String? = nil, identityName: String? = nil, profileName: String? = nil, profileUUID: String? = nil, profilePath: Path? = nil, designatedRequirements: String? = nil, signedEntitlements: PropertyListItem = .plDict([:]), simulatedEntitlements: PropertyListItem = .plDict([:]), appIdentifierPrefix: String? = nil, teamIdentifierPrefix: String? = nil, isEnterpriseTeam: Bool? = false, useSigningTool: Bool? = false, signingToolKeyPath: String? = nil, signingToolKeyID: String? = nil, signingToolKeyIssuerID: String? = nil, keychainPath: String? = nil, errors: [[String: String]] = [], warnings: [String] = [])
    {
        self.identityHash = identityHash
        self.identitySerialNumber = identitySerialNumber
        self.identityName = identityName
        self.profileName = profileName
        self.profileUUID = profileUUID
        self.profilePath = profilePath
        self.designatedRequirements = designatedRequirements
        self.signedEntitlements = signedEntitlements
        self.simulatedEntitlements = simulatedEntitlements
        self.appIdentifierPrefix = appIdentifierPrefix
        self.teamIdentifierPrefix = teamIdentifierPrefix
        self.isEnterpriseTeam = isEnterpriseTeam
        self.useSigningTool = useSigningTool
        self.signingToolKeyPath = signingToolKeyPath
        self.signingToolKeyID = signingToolKeyID
        self.signingToolKeyIssuerID = signingToolKeyIssuerID
        self.keychainPath = keychainPath
        self.errors = errors.map({ return ProvisioningTaskInputError(description: $0["description"] ?? "", recoverySuggestion: $0["recoverySuggestion"]) })
        self.warnings = warnings
    }
}

extension ProvisioningTaskInputs {
    public func entitlements(for variant: EntitlementsVariant) -> PropertyListItem {
        switch variant {
        case .signed:
            return signedEntitlements
        case .simulated:
            return simulatedEntitlements
        }
    }
}
