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
import Foundation

// MARK: General planning operation messages


/// Inform the client that a planning operation will start.
public struct PlanningOperationWillStart: SessionMessage, Equatable {
    public static let name = "PLANNING_OPERATION_WILL_START"

    public let sessionHandle: String
    public let planningOperationHandle: String

    public init(sessionHandle: String, planningOperationHandle: String) {
        self.sessionHandle = sessionHandle
        self.planningOperationHandle = planningOperationHandle
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.planningOperationHandle = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(sessionHandle)
            serializer.serialize(planningOperationHandle)
        }
    }
}

/// Inform the client that a planning operation has finished.
public struct PlanningOperationDidFinish: SessionMessage, Equatable {
    public static let name = "PLANNING_OPERATION_FINISHED"

    public let sessionHandle: String
    public let planningOperationHandle: String

    public init(sessionHandle: String, planningOperationHandle: String) {
        self.sessionHandle = sessionHandle
        self.planningOperationHandle = planningOperationHandle
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.sessionHandle = try deserializer.deserialize()
        self.planningOperationHandle = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(sessionHandle)
            serializer.serialize(planningOperationHandle)
        }
    }
}


// MARK: Getting provisioning task inputs from the client

/// The source data to send to the client for it to generate the provisioning task inputs for the service.
public struct ProvisioningTaskInputsSourceData: Serializable, Equatable, Sendable {
    public let configurationName: String
    public let provisioningProfileSupport: ProvisioningProfileSupport
    public let provisioningProfileSpecifier: String
    public let provisioningProfileUUID: String
    public let provisioningStyle: ProvisioningStyle
    public let teamID: String?
    public let bundleIdentifier: String
    public let productTypeEntitlements: PropertyListItem
    public let productTypeIdentifier: String
    public let projectEntitlementsFile: String?
    public let projectEntitlements: PropertyListItem?
    public let signingCertificateIdentifier: String
    public let signingRequiresTeam: Bool
    public let sdkRoot: String
    public let sdkVariant: String?
    public let supportsEntitlements: Bool
    public let wantsBaseEntitlementInjection: Bool
    public let entitlementsDestination: String
    public let localSigningStyle: String
    public let enableCloudSigning: Bool

    public init(configurationName: String, provisioningProfileSupport: ProvisioningProfileSupport, provisioningProfileSpecifier: String, provisioningProfileUUID: String, provisioningStyle: ProvisioningStyle, teamID: String?, bundleIdentifier: String, productTypeEntitlements: PropertyListItem, productTypeIdentifier: String, projectEntitlementsFile: String?, projectEntitlements: PropertyListItem?, signingCertificateIdentifier: String, signingRequiresTeam: Bool, sdkRoot: String, sdkVariant: String?, supportsEntitlements: Bool, wantsBaseEntitlementInjection: Bool, entitlementsDestination: String, localSigningStyle: String, enableCloudSigning: Bool) {
        self.configurationName = configurationName
        self.provisioningProfileSupport = provisioningProfileSupport
        self.provisioningProfileSpecifier = provisioningProfileSpecifier
        self.provisioningProfileUUID = provisioningProfileUUID
        self.provisioningStyle = provisioningStyle
        self.teamID = teamID
        self.bundleIdentifier = bundleIdentifier
        self.productTypeEntitlements = productTypeEntitlements
        self.productTypeIdentifier = productTypeIdentifier
        self.projectEntitlementsFile = projectEntitlementsFile
        self.projectEntitlements = projectEntitlements
        self.signingCertificateIdentifier = signingCertificateIdentifier
        self.signingRequiresTeam = signingRequiresTeam
        self.sdkRoot = sdkRoot
        self.sdkVariant = sdkVariant
        self.supportsEntitlements = supportsEntitlements
        self.wantsBaseEntitlementInjection = wantsBaseEntitlementInjection
        self.entitlementsDestination = entitlementsDestination
        self.localSigningStyle = localSigningStyle
        self.enableCloudSigning = enableCloudSigning
    }

    /*!
     *  @deprecated Use init(configurationName:provisioningProfileSupport:provisioningProfileSpecifier:provisioningProfileUUID:provisioningStyle:teamID:bundleIdentifier:productTypeEntitlements:productTypeIdentifier:projectEntitlementsFile:projectEntitlements:signingCertificateIdentifier:signingRequiresTeam:sdkRoot:sdkVariant:supportsEntitlements:wantsBaseEntitlementInjection:entitlementsDestination:localSigningStyle:enableCloudSigning:)
     */
    public init(configurationName: String, provisioningProfileSupport: ProvisioningProfileSupport, provisioningProfileSpecifier: String, provisioningProfileUUID: String, provisioningStyle: ProvisioningStyle, teamID: String?, bundleIdentifier: String, productTypeEntitlements: PropertyListItem, productTypeIdentifier: String, projectEntitlementsFile: String?, projectEntitlements: PropertyListItem?, signingCertificateIdentifier: String, signingRequiresTeam: Bool, sdkRoot: String, sdkVariant: String?, supportsEntitlements: Bool, wantsBaseEntitlementInjection: Bool, entitlementsDestination: String, localSigningStyle: String) {
        self.init(configurationName: configurationName, provisioningProfileSupport: provisioningProfileSupport, provisioningProfileSpecifier: provisioningProfileSpecifier, provisioningProfileUUID: provisioningProfileUUID, provisioningStyle: provisioningStyle, teamID: teamID, bundleIdentifier: bundleIdentifier, productTypeEntitlements: productTypeEntitlements, productTypeIdentifier: productTypeIdentifier, projectEntitlementsFile: projectEntitlementsFile, projectEntitlements: projectEntitlements, signingCertificateIdentifier: signingCertificateIdentifier, signingRequiresTeam: signingRequiresTeam, sdkRoot: sdkRoot, sdkVariant: sdkVariant, supportsEntitlements: supportsEntitlements, wantsBaseEntitlementInjection: wantsBaseEntitlementInjection, entitlementsDestination: entitlementsDestination, localSigningStyle: localSigningStyle, enableCloudSigning: false)
    }

    public init(from deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(20...22)
        self.configurationName = try deserializer.deserialize()
        if count >= 21 {
            _ = try deserializer.deserialize() as Bool  // Deprecated field, kept for compatibility
        }
        self.provisioningProfileSupport = count >= 21 ? try deserializer.deserialize() : .unsupported
        self.provisioningProfileSpecifier = try deserializer.deserialize()
        self.provisioningProfileUUID = try deserializer.deserialize()
        self.provisioningStyle = try deserializer.deserialize()
        self.teamID = try deserializer.deserialize()
        self.bundleIdentifier = try deserializer.deserialize()
        let productTypeEntitlementsBytes: [UInt8]? = try deserializer.deserialize()
        self.productTypeEntitlements = try productTypeEntitlementsBytes.map { try PropertyList.fromBytes($0) } ?? .plDict([:])
        self.productTypeIdentifier = try deserializer.deserialize()
        self.projectEntitlementsFile = try deserializer.deserialize()
        let projectEntitlementsBytes: [UInt8]? = try deserializer.deserialize()
        self.projectEntitlements = try projectEntitlementsBytes.map { try PropertyList.fromBytes($0) }
        _ = try deserializer.deserialize() as Bool // Deprecated field, kept for compatibility
        self.signingCertificateIdentifier = try deserializer.deserialize()
        self.signingRequiresTeam = try deserializer.deserialize()
        self.sdkRoot = try deserializer.deserialize()
        self.sdkVariant = try deserializer.deserialize()
        self.supportsEntitlements = try deserializer.deserialize()
        self.wantsBaseEntitlementInjection = try deserializer.deserialize()
        self.entitlementsDestination = try deserializer.deserialize()
        self.localSigningStyle = try deserializer.deserialize()
        self.enableCloudSigning = count >= 22 ? try deserializer.deserialize() : false
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(21) {
            serializer.serialize(configurationName)
            serializer.serialize(false) // Deprecated field, kept for compatibility
            serializer.serialize(provisioningProfileSupport)
            serializer.serialize(provisioningProfileSpecifier)
            serializer.serialize(provisioningProfileUUID)
            serializer.serialize(provisioningStyle)
            serializer.serialize(teamID)
            serializer.serialize(bundleIdentifier)
            // FIXME: <rdar://problem/40036582> We have no way to handle any errors in PropertyListItem.asBytes() here.
            serializer.serialize(try? productTypeEntitlements.asBytes(.binary))
            serializer.serialize(productTypeIdentifier)
            serializer.serialize(projectEntitlementsFile)
            // FIXME: <rdar://problem/40036582> We have no way to handle any errors in PropertyListItem.asBytes() here.
            serializer.serialize(projectEntitlements.map { try? $0.asBytes(.binary) } ?? nil)
            serializer.serialize(false) // Deprecated field, kept for compatibility
            serializer.serialize(signingCertificateIdentifier)
            serializer.serialize(signingRequiresTeam)
            serializer.serialize(sdkRoot)
            serializer.serialize(sdkVariant)
            serializer.serialize(supportsEntitlements)
            serializer.serialize(wantsBaseEntitlementInjection)
            serializer.serialize(entitlementsDestination)
            serializer.serialize(localSigningStyle)
        }
    }
}

// FIXME: Need to send the substantive data (build settings, etc.) to the client so it can generate the inputs.
//
/// A request from the service for provisioning task inputs for a configured target.
public struct GetProvisioningTaskInputsRequest: SessionMessage, Equatable {
    public static let name = "GET_PROVISIONING_TASK_INPUTS_REQUEST"

    public let sessionHandle: String
    public let planningOperationHandle: String
    /// The GUID of the target in the project model so the client can look up the target object.
    public let targetGUID: String
    /// The UUID of the configured target in the planning operation to match up the response with the right target.
    public let configuredTargetHandle: String
    public let sourceData: ProvisioningTaskInputsSourceData

    public init(sessionHandle: String, planningOperationHandle: String, targetGUID: String, configuredTargetHandle: String, sourceData: ProvisioningTaskInputsSourceData) {
        self.sessionHandle = sessionHandle
        self.planningOperationHandle = planningOperationHandle
        self.targetGUID = targetGUID
        self.configuredTargetHandle = configuredTargetHandle
        self.sourceData = sourceData
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(6)
        self.sessionHandle = try deserializer.deserialize()
        self.planningOperationHandle = try deserializer.deserialize()
        self.targetGUID = try deserializer.deserialize()
        self.configuredTargetHandle = try deserializer.deserialize()
        // This used to be the settingsHandle, but it hasn't been used for a long time.
        _ =  try deserializer.deserialize() as String
        self.sourceData = try deserializer.deserialize()
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(6) {
            serializer.serialize(sessionHandle)
            serializer.serialize(planningOperationHandle)
            serializer.serialize(targetGUID)
            serializer.serialize(configuredTargetHandle)
            // This used to be the settingsHandle, but it hasn't been used for a long time.
            serializer.serialize("")
            serializer.serialize(sourceData)
        }
    }
}

// FIXME: This is just a stub at present - it just contains a (meaningless) string as payload.
//
/// A response from the client to the service's request for provisioning task inputs for a configured target.
public struct ProvisioningTaskInputsResponse: SessionMessage, RequestMessage, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "PROVISIONING_TASK_INPUTS_RESPONSE"

    public let sessionHandle: String
    public let planningOperationHandle: String
    public let configuredTargetHandle: String

    public let identityHash: String?
    public let identitySerialNumber: String?
    public let identityName: String?
    public let profileName: String?
    public let profileUUID: String?
    public let profilePath: String?
    public let designatedRequirements: String?
    public let signedEntitlements: PropertyListItem?
    public let simulatedEntitlements: PropertyListItem?
    public let appIdentifierPrefix: String?
    public let teamIdentifierPrefix: String?
    public let isEnterpriseTeam: Bool?
    public let useSigningTool: Bool?
    public let signingToolKeyPath: String?
    public let signingToolKeyID: String?
    public let signingToolKeyIssuerID: String?
    public let keychainPath: String?
    public let errors: [[String: String]]
    public let warnings: [String]

    public init(sessionHandle: String, planningOperationHandle: String, configuredTargetHandle: String, identityHash: String?, identitySerialNumber:String?, identityName: String?, profileName: String?, profileUUID: String?, profilePath: String?, designatedRequirements: String?, signedEntitlements: PropertyListItem?, simulatedEntitlements: PropertyListItem?, appIdentifierPrefix: String?, teamIdentifierPrefix: String?, isEnterpriseTeam: Bool?, useSigningTool: Bool?, signingToolKeyPath: String?, signingToolKeyID: String?, signingToolKeyIssuerID: String?, keychainPath: String?, errors: [[String: String]], warnings: [String]) {
        self.sessionHandle = sessionHandle
        self.planningOperationHandle = planningOperationHandle
        self.configuredTargetHandle = configuredTargetHandle

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

    public init(from deserializer: any Deserializer) throws {
        let count: Int = try deserializer.beginAggregate()
        self.sessionHandle = try deserializer.deserialize()
        self.planningOperationHandle = try deserializer.deserialize()
        self.configuredTargetHandle = try deserializer.deserialize()

        self.identityHash = try deserializer.deserialize()
        self.identityName = try deserializer.deserialize()
        self.profileName = try deserializer.deserialize()
        self.profileUUID = try deserializer.deserialize()
        self.profilePath = try deserializer.deserialize()
        self.designatedRequirements = try deserializer.deserialize()
        let signedEntitlementsBytes: [UInt8]? = try deserializer.deserialize()
        self.signedEntitlements = try signedEntitlementsBytes.map { try PropertyList.fromBytes($0) }
        let simulatedEntitlementsBytes: [UInt8]? = try deserializer.deserialize()
        self.simulatedEntitlements = try simulatedEntitlementsBytes.map { try PropertyList.fromBytes($0) }
        self.appIdentifierPrefix = try deserializer.deserialize()
        self.teamIdentifierPrefix = try deserializer.deserialize()
        self.isEnterpriseTeam = try deserializer.deserialize()
        self.keychainPath = try deserializer.deserialize()

        var errors = [[String: String]]()
        let errorCount: Int = try deserializer.beginAggregate()
        for _ in 0..<errorCount {
            let error: [String: String] = try deserializer.deserialize()
            errors.append(error)
        }
        self.errors = errors
        self.warnings = try deserializer.deserialize()

        if count == 22 {
            self.identitySerialNumber = try deserializer.deserialize()
            self.useSigningTool = try deserializer.deserialize()
            self.signingToolKeyPath = try deserializer.deserialize()
            self.signingToolKeyID = try deserializer.deserialize()
            self.signingToolKeyIssuerID = try deserializer.deserialize()
        } else {
            self.identitySerialNumber = nil
            self.useSigningTool = nil
            self.signingToolKeyPath = nil
            self.signingToolKeyID = nil
            self.signingToolKeyIssuerID = nil
        }
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(22) {
            serializer.serialize(sessionHandle)
            serializer.serialize(planningOperationHandle)
            serializer.serialize(configuredTargetHandle)

            serializer.serialize(identityHash)
            serializer.serialize(identityName)
            serializer.serialize(profileName)
            serializer.serialize(profileUUID)
            serializer.serialize(profilePath)
            serializer.serialize(designatedRequirements)
            // FIXME: <rdar://problem/40036582> We have no way to handle any errors in PropertyListItem.asBytes() here.
            serializer.serialize(signedEntitlements.map { try? $0.asBytes(.binary) } ?? nil)
            serializer.serialize(simulatedEntitlements.map { try? $0.asBytes(.binary) } ?? nil)
            serializer.serialize(appIdentifierPrefix)
            serializer.serialize(teamIdentifierPrefix)
            serializer.serialize(isEnterpriseTeam)
            serializer.serialize(keychainPath)
            serializer.serializeAggregate(errors.count) {
                for error in errors {
                    serializer.serialize(error)
                }
            }
            serializer.serialize(warnings)
            serializer.serialize(identitySerialNumber)
            serializer.serialize(useSigningTool)
            serializer.serialize(signingToolKeyPath)
            serializer.serialize(signingToolKeyID)
            serializer.serialize(signingToolKeyIssuerID)
        }
    }
}



let planningOperationMessageTypes: [any Message.Type] = [
    PlanningOperationWillStart.self,
    PlanningOperationDidFinish.self,
    GetProvisioningTaskInputsRequest.self,
    ProvisioningTaskInputsResponse.self,
]
