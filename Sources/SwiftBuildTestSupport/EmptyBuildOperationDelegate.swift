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

import Foundation
package import SwiftBuild

/// An testing implementation of `SWBPlanningOperationDelegate` whose methods are all no-ops.
///
/// This is intended for unit tests which are not interested in handling any delegate methods or only want to handle a subset of delegate methods.
package final class EmptyBuildOperationDelegate: SWBPlanningOperationDelegate, SWBDocumentationDelegate, SWBLocalizationDelegate, SWBIndexingDelegate, SWBPreviewDelegate {
    package init() {
    }

    package func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SwiftBuild.SWBProvisioningTaskInputsSourceData) async -> SwiftBuild.SWBProvisioningTaskInputs {
        SWBProvisioningTaskInputs()
    }

    package func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> SwiftBuild.SWBExternalToolResult {
        .deferred
    }
}
