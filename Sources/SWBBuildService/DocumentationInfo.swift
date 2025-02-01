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

import SWBBuildSystem
package import SWBCore
import SWBTaskConstruction
package import SWBTaskExecution
package import SWBUtil

enum DocumentationInfoErrors: Error {
    case noBuildDescription
    case noTargetBuildGraph
}

protocol DocumentationInfoDelegate: BuildDescriptionConstructionDelegate, PlanningOperationDelegate, TargetDependencyResolverDelegate {
    var clientDelegate: any ClientDelegate { get }
}

/// Information about built documentation and the path where it will be written.
package struct DocumentationInfoOutput {
    /// The path where the documentation will be built.
    package let outputPath: Path

    /// The identifier of the target associated with the documentation we built.
    package let targetIdentifier: String?
}

extension BuildDescriptionManager {
    /// Generates information about the documentation that will be built for a given build request.
    ///
    /// For a description of how this feature works, see the `SWBBuildServiceSession.generateDocumentationInfo` documentation.
    ///
    /// This part of the feature gets the build description for the build request and calls `generateDocumentationInfo` on it (see below).
    func generateDocumentationInfo(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: any DocumentationInfoDelegate, input: TaskGenerateDocumentationInfoInput) async throws -> [DocumentationInfoOutput] {
        // FIXME: We have temporarily disabled going through the planning operation, since it was causing significant churn: <rdar://problem/31772753> ProvisioningInputs are changing substantially for the same request
        let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
        if delegate.hadErrors {
            throw DocumentationInfoErrors.noTargetBuildGraph
        }
        let planRequest = BuildPlanRequest(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, buildGraph: buildGraph, provisioningInputs: [:])

        // Get the complete build description.
        let buildDescription: BuildDescription
        do {
            if let retrievedBuildDescription = try await getBuildDescription(planRequest, clientDelegate: delegate.clientDelegate, constructionDelegate: delegate) {
                buildDescription = retrievedBuildDescription
            } else {
                // If we don't receive a build description it means we were cancelled.
                return []
            }
        } catch {
            throw DocumentationInfoErrors.noBuildDescription
        }

        return buildDescription.generateDocumentationInfo(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, input: input)
    }
}

extension BuildDescription {
    /// Generates information about the documentation that will be built for a given build request.
    ///
    /// For a description of how this feature works, see the `SWBBuildServiceSession.generateDocumentationInfo` documentation.
    ///
    /// This part of the feature visits all tasks and asks them to generate documentation. All tasks except the DocumentationCompiler returns an empty list.
    func generateDocumentationInfo(workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, input: TaskGenerateDocumentationInfoInput) -> [DocumentationInfoOutput] {
        var output: [DocumentationInfoOutput] = []
        taskStore.forEachTask { task in
            output.append(contentsOf: task.generateDocumentationInfo(input: input).map { info in
                DocumentationInfoOutput(outputPath: info.outputPath, targetIdentifier: info.targetIdentifier)
            })
        }
        return output
    }
}

extension BuildDescription {
    package func generateDocumentationInfoForTesting(workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext, input: TaskGenerateDocumentationInfoInput) -> [DocumentationInfoOutput] {
        return generateDocumentationInfo(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, input: input)
    }
}
