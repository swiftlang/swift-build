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
import SWBCore
import SWBProtocol
import SWBServiceCore
import SWBTaskConstruction
import SWBTaskExecution
import SWBUtil

// MARK: - Retrieve build description

/// Message that contains enough information to load a build description
private protocol BuildDescriptionMessage: SessionMessage {
    /// The ID of the build description from which to load the configured targets
    var buildDescriptionID: BuildDescriptionID { get }

    /// The build request that was used to generate the build description with the given ID.
    var request: BuildRequestMessagePayload { get }
}

extension BuildDescriptionConfiguredTargetsRequest: BuildDescriptionMessage {}
extension BuildDescriptionConfiguredTargetSourcesRequest: BuildDescriptionMessage {}
extension IndexBuildSettingsRequest: BuildDescriptionMessage {}

fileprivate extension Request {
    struct BuildDescriptionDoesNotExistError: Error {}

    func buildDescription(for message: some BuildDescriptionMessage) async throws -> BuildDescription {
        return try await buildRequestAndDescription(for: message).description
    }

    func buildRequestAndDescription(for message: some BuildDescriptionMessage) async throws -> (request: BuildRequest, description: BuildDescription) {
        let session = try self.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let buildRequest = try BuildRequest(from: message.request, workspace: workspaceContext.workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let clientDelegate = ClientExchangeDelegate(request: self, session: session)
        let operation = IndexingOperation(workspace: workspaceContext.workspace)
        let buildDescription = try await session.buildDescriptionManager.getNewOrCachedBuildDescription(
            .cachedOnly(
                message.buildDescriptionID,
                request: buildRequest,
                buildRequestContext: buildRequestContext,
                workspaceContext: workspaceContext
            ), clientDelegate: clientDelegate, constructionDelegate: operation
        )?.buildDescription

        guard let buildDescription else {
            throw BuildDescriptionDoesNotExistError()
        }
        return (buildRequest, buildDescription)
    }
}

// MARK: - Message handlers

struct BuildDescriptionConfiguredTargetsMsg: MessageHandler {
    /// Compute the toolchains that can handle all Swift and clang compilation tasks in the given target.
    private func toolchainIDs(in configuredTarget: ConfiguredTarget, of buildDescription: BuildDescription) -> [String]? {
        var toolchains: [String]?

        for task in buildDescription.taskStore.tasksForTarget(configuredTarget) {
            let targetToolchains: [String]? =
                switch task.payload {
                case let payload as SwiftTaskPayload: payload.indexingPayload.toolchains
                case let payload as ClangTaskPayload: payload.indexingPayload?.toolchains
                default: nil
                }
            guard let targetToolchains else {
                continue
            }
            if let unwrappedToolchains = toolchains {
                toolchains = unwrappedToolchains.filter { targetToolchains.contains($0) }
            } else {
                toolchains = targetToolchains
            }
        }

        return toolchains
    }

    func handle(request: Request, message: BuildDescriptionConfiguredTargetsRequest) async throws -> BuildDescriptionConfiguredTargetsResponse {
        let buildDescription = try await request.buildDescription(for: message)

        var configuredTargetIdentifiersByGUID: [String: ConfiguredTargetIdentifier] = [:]
        for configuredTarget in buildDescription.allConfiguredTargets {
            configuredTargetIdentifiersByGUID[configuredTarget.guid.stringValue] = ConfiguredTargetIdentifier(rawGUID: configuredTarget.guid.stringValue, targetGUID: TargetGUID(rawValue: configuredTarget.target.guid))
        }

        let dependencyRelationships = Dictionary(
            buildDescription.targetDependencies.map { (ConfiguredTarget.GUID(id: $0.target.guid), [$0]) },
            uniquingKeysWith: { $0 + $1 }
        )

        let session = try request.session(for: message)

        let targetInfos = buildDescription.allConfiguredTargets.map { configuredTarget in
            let toolchain: Path?
            if let toolchainID = toolchainIDs(in: configuredTarget, of: buildDescription)?.first {
                toolchain = session.core.toolchainRegistry.lookup(toolchainID)?.path
                if toolchain == nil {
                    log("Unable to find path for toolchain with identifier \(toolchainID)", isError: true)
                }
            } else {
                log("Unable to find toolchain for \(configuredTarget)", isError: true)
                toolchain = nil
            }

            let dependencyRelationships = dependencyRelationships[configuredTarget.guid]
            return BuildDescriptionConfiguredTargetsResponse.ConfiguredTargetInfo(
                identifier: ConfiguredTargetIdentifier(rawGUID: configuredTarget.guid.stringValue, targetGUID: TargetGUID(rawValue: configuredTarget.target.guid)),
                name: configuredTarget.target.name,
                dependencies: Set(dependencyRelationships?.flatMap(\.targetDependencies).compactMap { configuredTargetIdentifiersByGUID[$0.guid] } ?? []),
                toolchain: toolchain
            )
        }
        return BuildDescriptionConfiguredTargetsResponse(configuredTargets: targetInfos)
    }
}

fileprivate extension SourceLanguage {
    init?(_ language: IndexingInfoLanguage?) {
        switch language {
        case nil: return nil
        case .c: self = .c
        case .cpp: self = .cpp
        case .metal: self = .metal
        case .objectiveC: self = .objectiveC
        case .objectiveCpp: self = .objectiveCpp
        case .swift: self = .swift
        }
    }
}

struct BuildDescriptionConfiguredTargetSourcesMsg: MessageHandler {
    private struct UnknownConfiguredTargetIDError: Error, CustomStringConvertible {
        let configuredTarget: ConfiguredTargetIdentifier
        var description: String { "Unknown configured target: \(configuredTarget)" }
    }

    typealias SourceFileInfo = BuildDescriptionConfiguredTargetSourcesResponse.SourceFileInfo
    typealias ConfiguredTargetSourceFilesInfo = BuildDescriptionConfiguredTargetSourcesResponse.ConfiguredTargetSourceFilesInfo

    func handle(request: Request, message: BuildDescriptionConfiguredTargetSourcesRequest) async throws -> BuildDescriptionConfiguredTargetSourcesResponse {
        let buildDescription = try await request.buildDescription(for: message)

        let configuredTargetsByID = Dictionary(
            buildDescription.allConfiguredTargets.map { ($0.guid, $0) }
        ) { lhs, rhs in
            log("Found conflicting targets for the same ID: \(lhs.guid)", isError: true)
            return lhs
        }

        let indexingInfoInput = TaskGenerateIndexingInfoInput(requestedSourceFile: nil, outputPathOnly: true, enableIndexBuildArena: false)
        let sourcesItems = try message.configuredTargets.map { configuredTargetIdentifier in
            guard let target = configuredTargetsByID[ConfiguredTarget.GUID(id: configuredTargetIdentifier.rawGUID)] else {
                throw UnknownConfiguredTargetIDError(configuredTarget: configuredTargetIdentifier)
            }
            let sourceFiles = buildDescription.taskStore.tasksForTarget(target).flatMap { task in
                task.generateIndexingInfo(input: indexingInfoInput).compactMap { (entry) -> SourceFileInfo? in
                    return SourceFileInfo(
                        path: entry.path,
                        language: SourceLanguage(entry.indexingInfo.language),
                        outputPath: entry.indexingInfo.indexOutputFile
                    )
                }
            }
            return ConfiguredTargetSourceFilesInfo(configuredTarget: configuredTargetIdentifier, sourceFiles: sourceFiles)
        }
        return BuildDescriptionConfiguredTargetSourcesResponse(targetSourceFileInfos: sourcesItems)
    }
}

struct IndexBuildSettingsMsg: MessageHandler {
    private struct AmbiguousIndexingInfoError: Error, CustomStringConvertible {
        var description: String { "Found multiple indexing informations for the same source file" }
    }

    private struct FailedToGetCompilerArgumentsError: Error {}

    func handle(request: Request, message: IndexBuildSettingsRequest) async throws -> IndexBuildSettingsResponse {
        let (buildRequest, buildDescription) = try await request.buildRequestAndDescription(for: message)

        let configuredTarget = buildDescription.allConfiguredTargets.filter { $0.guid.stringValue == message.configuredTarget.rawGUID }.only

        let indexingInfoInput = TaskGenerateIndexingInfoInput(
            requestedSourceFile: message.file,
            outputPathOnly: false,
            enableIndexBuildArena: buildRequest.enableIndexBuildArena
        )
        // First find all the tasks that declare the requested source file as an input file. This should narrow the list
        // of targets down significantly.
        let taskForSourceFile = buildDescription.taskStore.tasksForTarget(configuredTarget)
            .filter { $0.inputPaths.contains(message.file) }
        // Now get the indexing info for the targets that might be relevant and perform another check to ensure they
        // actually represent the requested source file.
        let indexingInfos =
            taskForSourceFile
            .flatMap { $0.generateIndexingInfo(input: indexingInfoInput) }
            .filter({ $0.path == message.file })
        guard let indexingInfo = indexingInfos.only else {
            throw AmbiguousIndexingInfoError()
        }
        guard let compilerArguments = indexingInfo.indexingInfo.compilerArguments else {
            throw FailedToGetCompilerArgumentsError()
        }
        return IndexBuildSettingsResponse(compilerArguments: compilerArguments)
    }
}
