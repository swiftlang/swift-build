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

package import SWBUtil
package import SwiftBuild
import SWBTestSupport

package final class TestBuildOperationDelegate: SWBPlanningOperationDelegate, SWBDocumentationDelegate, SWBLocalizationDelegate, SWBIndexingDelegate, SWBPreviewDelegate {
    /// The number of provisioning task input requests.
    package let numProvisioningTaskInputRequests = LockedValue(0)

    package init() {
    }

    // MARK: SWBPlanningOperationDelegate

    package func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SwiftBuild.SWBProvisioningTaskInputsSourceData) async -> SwiftBuild.SWBProvisioningTaskInputs {
        numProvisioningTaskInputRequests.withLock { $0 += 1 }

        let identity = provisioningSourceData.signingCertificateIdentifier
        if identity == "-" {
            let signedEntitlements = provisioningSourceData.entitlementsDestination == "Signature"
                ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
                : [:]

            let simulatedEntitlements = provisioningSourceData.entitlementsDestination == "__entitlements"
                ? provisioningSourceData.productTypeEntitlements.merging(["application-identifier": .plString(provisioningSourceData.bundleIdentifier)], uniquingKeysWith: { _, new in new }).merging(provisioningSourceData.projectEntitlements ?? [:], uniquingKeysWith: { _, new in new })
                : [:]

            return SWBProvisioningTaskInputs(identityHash: "-", identityName: "-", profileName: nil, profileUUID: nil, profilePath: nil, designatedRequirements: nil, signedEntitlements: signedEntitlements.merging(provisioningSourceData.sdkRoot.contains("simulator") ? ["get-task-allow": .plBool(true)] : [:], uniquingKeysWith: { _, new  in new }), simulatedEntitlements: simulatedEntitlements, appIdentifierPrefix: nil, teamIdentifierPrefix: nil, isEnterpriseTeam: nil, keychainPath: nil, errors: [], warnings: [])
        } else if identity.isEmpty {
            return SWBProvisioningTaskInputs()
        } else {
            return SWBProvisioningTaskInputs(identityHash: "-", errors: [["description": "unable to supply accurate provisioning inputs for CODE_SIGN_IDENTITY=\(identity)\""]])
        }
    }

    package func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> SwiftBuild.SWBExternalToolResult {
        .deferred
    }
}

@available(*, unavailable)
extension TestBuildOperationDelegate: Sendable { }
