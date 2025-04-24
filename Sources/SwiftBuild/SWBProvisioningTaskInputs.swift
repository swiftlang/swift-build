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

import SWBProtocol
import SWBUtil
import Foundation

@frozen public enum SWBProvisioningStyle: Sendable {
    case automatic
    case manual
}

public enum SWBProvisioningProfileSupport: Sendable {
    case unsupported
    case optional
    case required
}

/// Source data for computing provisioning task inputs, to be passed from SwiftBuild.framework to clients.
public struct SWBProvisioningTaskInputsSourceData: Sendable {
    public let configurationName: String

    public let provisioningProfileSupport: SWBProvisioningProfileSupport
    public let provisioningProfileSpecifier: String
    public let provisioningProfileUUID: String
    public let provisioningStyle: SWBProvisioningStyle
    public let teamID: String?
    public let bundleIdentifier: String
    public let productTypeEntitlements: [String: SWBPropertyListItem]
    public let productTypeIdentifier: String
    public let projectEntitlementsFile: String?
    public let projectEntitlements: [String: SWBPropertyListItem]?
    public let signingCertificateIdentifier: String
    public let signingRequiresTeam: Bool
    public let sdkRoot: String
    public let sdkVariant: String?
    public let supportsEntitlements: Bool
    public let wantsBaseEntitlementInjection: Bool
    public let entitlementsDestination: String
    public let localSigningStyle: String
    public let enableCloudSigning: Bool

    init(_ sourceData: ProvisioningTaskInputsSourceData) throws {
        self.configurationName = sourceData.configurationName
        switch sourceData.provisioningProfileSupport {
        case .unsupported:
            self.provisioningProfileSupport = .unsupported
        case .optional:
            self.provisioningProfileSupport = .optional
        case .required:
            self.provisioningProfileSupport = .required
        }
        self.provisioningProfileSpecifier = sourceData.provisioningProfileSpecifier
        self.provisioningProfileUUID = sourceData.provisioningProfileUUID
        switch sourceData.provisioningStyle {
        case .automatic:
            self.provisioningStyle = .automatic
        case .manual:
            self.provisioningStyle = .manual
        }
        self.teamID = sourceData.teamID
        self.bundleIdentifier = sourceData.bundleIdentifier
        self.productTypeEntitlements = try .init(sourceData.productTypeEntitlements.dictValue ?? [:])
        self.productTypeIdentifier = sourceData.productTypeIdentifier
        self.projectEntitlementsFile = sourceData.projectEntitlementsFile
        self.projectEntitlements = try sourceData.projectEntitlements.map { try .init($0.dictValue ?? [:]) } ?? nil
        self.signingCertificateIdentifier = sourceData.signingCertificateIdentifier
        self.signingRequiresTeam = sourceData.signingRequiresTeam
        self.sdkRoot = sourceData.sdkRoot
        self.sdkVariant = sourceData.sdkVariant
        self.supportsEntitlements = sourceData.supportsEntitlements
        self.wantsBaseEntitlementInjection = sourceData.wantsBaseEntitlementInjection
        self.entitlementsDestination = sourceData.entitlementsDestination
        self.localSigningStyle = sourceData.localSigningStyle
        self.enableCloudSigning = sourceData.enableCloudSigning
    }
}

/// The provisioning task inputs computed by IDEProvisioningManager, to be passed from clients to SwiftBuild.framework (and then on to the service).
public struct SWBProvisioningTaskInputs: Sendable {
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
    public let profilePath: String?
    /// The designated requirements string suitable for passing to the `codesign` tool.  Note that this is *not* fully evaluated, it may need `$(CODE_SIGN_IDENTIFIER)` to be evaluated before signing.
    public let designatedRequirements: String?
    /// The fully evaluated and merged entitlements dictionary, suitable for passing to the product packaging utility task and to the `codesign` tool.
    public let signedEntitlements: [String: SWBPropertyListItem]?
    /// The fully evaluated and merged simulated entitlements dictionary, suitable for passing to the product packaging utility task and to the linker.
    public let simulatedEntitlements: [String: SWBPropertyListItem]?
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
    public let errors: [[String: String]]
    /// Any warnings here should be presented to the user, but signing may still proceed.
    public let warnings: [String]

    public init(identityHash: String? = nil, identitySerialNumber: String? = nil, identityName: String? = nil, profileName: String? = nil, profileUUID: String? = nil, profilePath: String? = nil, designatedRequirements: String? = nil, signedEntitlements: [String: SWBPropertyListItem]? = nil, simulatedEntitlements: [String: SWBPropertyListItem]? = nil, appIdentifierPrefix: String? = nil, teamIdentifierPrefix: String? = nil, isEnterpriseTeam: Bool? = false, useSigningTool: Bool? = false, signingToolKeyPath: String? = nil, signingToolKeyID: String? = nil, signingToolKeyIssuerID: String? = nil, keychainPath: String? = nil, errors: [[String: String]] = [], warnings: [String] = []) {
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
        self.errors = errors
        self.warnings = warnings
    }

    /*! backwards compatible initializer for clients older than rdar://123108232
     *  @deprecated Use init(identityHash:identitySerialNumber:identityName:profileName:profileUUID:profilePath:designatedRequirements:signedEntitlements:simulatedEntitlements:appIdentifierPrefix:teamIdentifierPrefix:isEnterpriseTeam:useSigningTool:signingToolKeyPath:signingToolKeyID:signingToolKeyIssuerID:keychainPath:errors:warnings:)
     */
    public init(identityHash: String? = nil, identityName: String? = nil, profileName: String? = nil, profileUUID: String? = nil, profilePath: String? = nil, designatedRequirements: String? = nil, signedEntitlements: [String: SWBPropertyListItem]? = nil, simulatedEntitlements: [String: SWBPropertyListItem]? = nil, appIdentifierPrefix: String? = nil, teamIdentifierPrefix: String? = nil, isEnterpriseTeam: Bool? = false, keychainPath: String? = nil, errors: [[String: String]] = [], warnings: [String] = []) {
        self.init(identityHash: identityHash, identitySerialNumber: nil, identityName: identityName, profileName: profileName, profileUUID: profileUUID, profilePath: profilePath, designatedRequirements: designatedRequirements, signedEntitlements: signedEntitlements, simulatedEntitlements: simulatedEntitlements, appIdentifierPrefix: appIdentifierPrefix, teamIdentifierPrefix: teamIdentifierPrefix, isEnterpriseTeam: isEnterpriseTeam, useSigningTool: false, signingToolKeyPath: nil, signingToolKeyID: nil, signingToolKeyIssuerID: nil, keychainPath: keychainPath, errors: errors, warnings: warnings);
    }
}

/// The service is asking for provisioning task inputs for a configured target.
@discardableResult func handle(message: GetProvisioningTaskInputsRequest, session: SWBBuildServiceSession, delegate: (any SWBPlanningOperationDelegate)?) async -> any Message {
    guard let delegate else {
        return await session.service.send(ErrorResponse("No delegate for response."))
    }

    // Convert the source data from the request into a form that the client can access.
    let sourceData: SWBProvisioningTaskInputsSourceData
    do {
        sourceData = try SWBProvisioningTaskInputsSourceData(message.sourceData)
    } catch {
        return await session.service.send(ErrorResponse(error.localizedDescription))
    }

    // Ask the delegate to get the provisioning inputs and then we'll send them back to the service.
    let inputs = await delegate.provisioningTaskInputs(targetGUID: message.targetGUID, provisioningSourceData: sourceData)
    // Convert the resulting entitlements to the PropertyListItem format.
    let signedEntitlements = (inputs.signedEntitlements?.propertyList).map { PropertyListItem.plDict($0) }
    let simulatedEntitlements = (inputs.simulatedEntitlements?.propertyList).map { PropertyListItem.plDict($0) }

    // Marshal all of the results into the response and send it.
    let reply = ProvisioningTaskInputsResponse(sessionHandle: message.sessionHandle, planningOperationHandle: message.planningOperationHandle, configuredTargetHandle: message.configuredTargetHandle, identityHash: inputs.identityHash, identitySerialNumber: inputs.identitySerialNumber, identityName: inputs.identityName, profileName: inputs.profileName, profileUUID: inputs.profileUUID, profilePath: inputs.profilePath, designatedRequirements: inputs.designatedRequirements, signedEntitlements: signedEntitlements, simulatedEntitlements: simulatedEntitlements, appIdentifierPrefix: inputs.appIdentifierPrefix, teamIdentifierPrefix: inputs.teamIdentifierPrefix, isEnterpriseTeam: inputs.isEnterpriseTeam, useSigningTool: inputs.useSigningTool, signingToolKeyPath: inputs.signingToolKeyPath, signingToolKeyID: inputs.signingToolKeyID, signingToolKeyIssuerID: inputs.signingToolKeyIssuerID, keychainPath: inputs.keychainPath, errors: inputs.errors, warnings: inputs.warnings)
    return await session.service.send(reply)
}
