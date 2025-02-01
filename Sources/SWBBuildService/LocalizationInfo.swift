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

import SWBUtil
import SWBCore
import SWBTaskConstruction
import SWBTaskExecution
import SWBBuildSystem

/// Errors that might be thrown while generating localization info from a build description.
enum LocalizationInfoErrors: Error {
    case noBuildDescriptionID // The client didn't set buildDescriptionID
    case noBuildDescription
}

/// A delegate object for generating localization info.
protocol LocalizationInfoDelegate: BuildDescriptionConstructionDelegate {
    var clientDelegate: any ClientDelegate { get }
}

/// The localization info for a particular target.
///
/// Encapsulates the target GUID and any stringsdata files produced by the latest build of that target.
struct LocalizationInfoOutput {
    /// The target GUID (not the ConfiguredTarget guid).
    let targetIdentifier: String

    /// Paths to source .xcstrings files used as inputs in this target.
    ///
    /// This collection specifically contains compilable files, AKA files in a Resources phase (not a Copy Files phase).
    fileprivate(set) var compilableXCStringsPaths: Set<Path> = []

    /// Paths to .stringsdata files produced by this target, grouped by build attributes such as platform and architecture.
    fileprivate(set) var producedStringsdataPaths: [LocalizationBuildPortion: Set<Path>] = [:]
}

extension BuildDescriptionManager {
    /// Generates and returns any applicable localization information from the build represented by `buildRequest`.
    ///
    /// Each returned Output object represents data for a single `Target` (not `ConfiguredTarget`).
    func generateLocalizationInfo(workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: any LocalizationInfoDelegate, input: TaskGenerateLocalizationInfoInput) async throws -> [LocalizationInfoOutput] {
        // We require the client to set buildDescriptionID on the build request so that we can just lookup an existing build description.
        // This guarantees good performance and ensures that we won't need to re-plan if the files changed on disk.
        // Even if the files did change, we still want the plan from this specific build (which in practice will be a build that just completed).

        guard let descriptionID = buildRequest.buildDescriptionID else {
            assertionFailure("The client of generateLocalizationInfo should set buildDescriptionID on the build operation prior to calling the API.")
            throw LocalizationInfoErrors.noBuildDescriptionID
        }

        let buildDescription: BuildDescription
        do {
            if let retrievedBuildDescription = try await getNewOrCachedBuildDescription(.cachedOnly(descriptionID, request: buildRequest, buildRequestContext: buildRequestContext, workspaceContext: workspaceContext), clientDelegate: delegate.clientDelegate, constructionDelegate: delegate)?.buildDescription {
                buildDescription = retrievedBuildDescription
            } else {
                // If we don't receive a build description it means we were cancelled.
                return []
            }
        } catch {
            throw LocalizationInfoErrors.noBuildDescription
        }

        return buildDescription.generateLocalizationInfo(input: input)
    }
}

extension BuildDescription {
    /// Generates and returns information about the localized strings that were / will be extracted during this build.
    func generateLocalizationInfo(input: TaskGenerateLocalizationInfoInput) -> [LocalizationInfoOutput] {
        var outputsByTarget = [String: LocalizationInfoOutput]()

        // Produce only one LocalizationInfoOutput per target.
        taskStore.forEachTask { task in
            guard let targetGUID = task.forTarget?.target.guid else {
                // This task is not associated with a target at all.
                // Ignore for now.
                return // equivalent to `continue` since we're in a closure-based loop.
            }

            let taskLocalizationOutputs = task.generateLocalizationInfo(input: input)

            guard !taskLocalizationOutputs.isEmpty else {
                return // continue
            }

            let taskXCStringsPaths = Set(taskLocalizationOutputs.flatMap(\.compilableXCStringsPaths))
            let taskStringsdataPaths: [LocalizationBuildPortion: Set<Path>] = taskLocalizationOutputs
                .map(\.producedStringsdataPaths)
                .reduce([:], { aggregate, partial in aggregate.merging(partial, uniquingKeysWith: +) })
                .mapValues { Set($0) }

            outputsByTarget[targetGUID, default: LocalizationInfoOutput(targetIdentifier: targetGUID)]
                .compilableXCStringsPaths.formUnion(taskXCStringsPaths)
            outputsByTarget[targetGUID]?.producedStringsdataPaths.merge(taskStringsdataPaths, uniquingKeysWith: { $0.union($1) })
        }

        return Array(outputsByTarget.values)
    }
}
