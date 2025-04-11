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
public import SWBProtocol
public import struct Foundation.Data

/// Whether to skip build tasks that are only necessary if the build products will be immediately run on a device (e.g. build-only vs build-and-run).
/// This may be used to defer downloading of build products from a remote server until those products are about to be run, if the build is being executed remotely.
public enum BuildTaskStyle: Sendable {
    case buildOnly
    case buildAndRun
}

public enum BuildLocationStyle: Sendable {
    case regular
    case legacy
}

public enum PreviewStyle: Sendable {
    case dynamicReplacement
    case xojit
}

/// The build command for a build request indicates the goal of the build, which may be to perform a normal full build, or a special build to generate only a certain set of files.
public enum BuildCommand: CustomStringConvertible, Equatable, Sendable {
    /// Perform a normal full build.
    case build(style: BuildTaskStyle, skipDependencies: Bool)

    case generateAssemblyCode(buildOnlyTheseFiles: [Path])
    case generatePreprocessedFile(buildOnlyTheseFiles: [Path])
    case singleFileBuild(buildOnlyTheseFiles: [Path])

    // (For grep's sake, this was formerly known as a "prebuild" in PBX terms.)
    //
    /// Builds only the files needed for the indexer to parse sources.  If `buildOnlyTheseTargets` is nil we do this for everything in the build, otherwise it only prepares those targets.
    case prepareForIndexing(buildOnlyTheseTargets: [Target]?, enableIndexBuildArena: Bool)

    /// Cleans the build folder
    case cleanBuildFolder(style: BuildLocationStyle)

    case preview(style: PreviewStyle)

    public var isPrepareForIndexing: Bool {
        if case BuildCommand.prepareForIndexing = self {
            return true
        } else {
            return false
        }
    }

    public var description: String {
        switch self {
        case .build: return "build"
        case .generateAssemblyCode: return "generateAssemblyCode"
        case .generatePreprocessedFile: return "generatePreprocessedFile"
        case .singleFileBuild: return "singleFileBuild"
        case .prepareForIndexing: return "prepareForIndexing"
        case .cleanBuildFolder: return "cleanBuildFolder"
        case .preview: return "preview"
        }
    }
}

extension SWBCore.BuildTaskStyle {
    init(from payload: BuildTaskStyleMessagePayload) {
        switch payload {
        case .buildOnly:
            self = .buildOnly
        case .buildAndRun:
            self = .buildAndRun
        }
    }
}

extension SWBCore.BuildLocationStyle {
    init(from payload: BuildLocationStyleMessagePayload) {
        switch payload {
        case .regular:
            self = .regular
        case .legacy:
            self = .legacy
        }
    }
}

extension SWBCore.PreviewStyle {
    init(from payload: PreviewStyleMessagePayload) {
        switch payload {
        case .dynamicReplacement:
            self = .dynamicReplacement
        case .xojit:
            self = .xojit
        }
    }
}

extension SWBCore.BuildCommand {
    init(from payload: BuildCommandMessagePayload, workspace: Workspace) throws {
        switch payload {
        case let .build(style, skipDependencies):
            self = .build(style: .init(from: style), skipDependencies: skipDependencies)
        case let .generateAssemblyCode(buildOnlyTheseFiles):
            self = .generateAssemblyCode(buildOnlyTheseFiles: buildOnlyTheseFiles.map(Path.init))
        case let .generatePreprocessedFile(buildOnlyTheseFiles):
            self = .generatePreprocessedFile(buildOnlyTheseFiles: buildOnlyTheseFiles.map(Path.init))
        case let .singleFileBuild(buildOnlyTheseFiles):
            self = .singleFileBuild(buildOnlyTheseFiles: buildOnlyTheseFiles.map(Path.init))
        case let .prepareForIndexing(buildOnlyTheseTargets, enableIndexBuildArena):
            self = try .prepareForIndexing(buildOnlyTheseTargets: buildOnlyTheseTargets?.map {
                guard let target = workspace.target(for: $0) else {
                    throw MsgParserError.missingTarget(guid: $0)
                }
                return target
            } ?? nil, enableIndexBuildArena: enableIndexBuildArena)
        case .migrate:
            throw MsgParserError.swiftMigrationNoLongerAvailable
        case let .cleanBuildFolder(style):
            self = .cleanBuildFolder(style: .init(from: style))
        case let .preview(style):
            self = .preview(style: .init(from: style))
        }
    }
}

/// The scheme command for a build request indicates the overall action of which the build is a part, i.e. what the product of the build will be used for once the build is finished.  This may inform how certain build tasks are run during the build, but does not affect which build tasks are constructed in the build description.
public enum SchemeCommand: CustomStringConvertible, Sendable {
    /// The product will be used in the launch of an app or executable, probably for debugging (i.e., a 'standard' build).
    case launch

    /// The product will be used to run tests.
    case test

    /// The product will be used to launch an app or executable for profiling.
    case profile

    /// The product will be included in an archive, possibly for submission to an app store.
    case archive

    public var description: String {
        switch self {
        case .launch: return "launch"
        case .test: return "test"
        case .profile: return "profile"
        case .archive: return "archive"
        }
    }
}

/// Refer to `SWBCore.SchemeCommand`
extension SchemeCommandMessagePayload {
    var coreRepresentation: SWBCore.SchemeCommand {
        switch self {
        case .launch: return SWBCore.SchemeCommand.launch
        case .test: return SWBCore.SchemeCommand.test
        case .profile: return SWBCore.SchemeCommand.profile
        case .archive: return SWBCore.SchemeCommand.archive
        }
    }
}

public enum DependencyScope: Sendable {
    /// Consider all dependencies visible in the workspace.
    case workspace
    /// Consider only dependencies between targets specified in the build request.
    case buildRequest
}

/// Container for information required to dispatch a build operation.
//
// FIXME: This should probably move into the "actually build" framework?
public final class BuildRequest: CustomStringConvertible, Sendable {
    /// Information on a target to build.
    public struct BuildTargetInfo: Sendable {
        /// The build parameters to use for this target.
        public let parameters: BuildParameters

        /// The target to build.
        public let target: Target

        /// Create a new configured target instance.
        ///
        /// - Parameters:
        ///   - parameters: The build parameters the target is configured with.
        ///   - target: The target to be configured.
        public init(parameters: BuildParameters, target: Target) {
            self.parameters = parameters
            self.target = target
        }
    }

    /// The main build parameters.
    public let parameters: BuildParameters

    // FIXME: Encode the necessary information for the execution environment.

    /// The configured targets to build.
    public let buildTargets: [BuildTargetInfo]

    /// The scope of target dependencies to consider.
    public let dependencyScope: DependencyScope

    /// GUIDs of the configured targets to build.
    private let buildTargetGUIDs: Set<String>

    /// Whether targets should be built in parallel.
    public let useParallelTargets: Bool

    /// Whether implicit dependencies should be added.
    public let useImplicitDependencies: Bool

    /// Whether or not to use "dry run" mode, in which the work to be done is just logged but not executed.
    public let useDryRun: Bool

    /// Whether stale file removal should be enabled.
    public let enableStaleFileRemoval: Bool

    /// Whether or not to continue building after errors.
    public let continueBuildingAfterErrors: Bool

    /// Whether or not to hide the shell script environment in logs.
    public let hideShellScriptEnvironment: Bool

    /// Whether to report non-logged progress updates.
    public let showNonLoggedProgress: Bool

    /// Whether to record build backtrace frames.
    public let recordBuildBacktraces: Bool

    /// Whether the build system should generate a report detailing precompiled modules.
    public let generatePrecompiledModulesReport: Bool

    /// Optional ID of the build description to use for the request.
    /// If set then the build description will be retrieved using the ID and no build planning will occur.
    public let buildDescriptionID: BuildDescriptionID?

    /// Whether or not to use a dedicated build arena for the index related requests.
    public var enableIndexBuildArena: Bool {
        return parameters.action == .indexBuild
    }

    /// The quality-of-service to use for this request.
    public let qos: SWBQoS

    /// Optional path of a directory into which to write diagnostic information about the build plan.
    public let buildPlanDiagnosticsDirPath: Path?

    /// The goal of the build, which may be to perform a normal full build, or a special build to generate only a certain set of files.
    public let buildCommand: BuildCommand

    /// The overall action of which this build is a part, i.e. what the product of the build will be used for once the build is finished.
    /// `nil` indicates that no scheme is in use and that a legacy target-style build is being performed.
    public let schemeCommand: SchemeCommand?

    /// Path of the root container being built. This is typically a .xcworkspace or .xcodeproj,
    /// but can also be a .playground or the path to a directory containing a Package.swift file.
    public let containerPath: Path?

    /// JSON representation of the `SWBBuildRequest` public API object from which this build request was constructed, if provided.
    public let jsonRepresentation: Data?

    /// Create a build request.
    ///
    /// - Parameters:
    ///   - parameters: The default build parameters, used in non-target specific contexts.
    ///   - buildTargets: The list of targets which should be built
    public init(parameters: BuildParameters, buildTargets: [BuildTargetInfo], dependencyScope: DependencyScope = .workspace, continueBuildingAfterErrors: Bool, hideShellScriptEnvironment: Bool = false, useParallelTargets: Bool, useImplicitDependencies: Bool, useDryRun: Bool, enableStaleFileRemoval: Bool? = nil, showNonLoggedProgress: Bool = true, recordBuildBacktraces: Bool? = nil, generatePrecompiledModulesReport: Bool? = nil, buildDescriptionID: BuildDescriptionID? = nil, qos: SWBQoS? = nil, buildPlanDiagnosticsDirPath: Path? = nil, buildCommand: BuildCommand? = nil, schemeCommand: SchemeCommand? = .launch, containerPath: Path? = nil, jsonRepresentation: Data? = nil) {
        self.parameters = parameters
        self.buildTargets = buildTargets
        self.dependencyScope = dependencyScope
        self.buildTargetGUIDs = Set(buildTargets.map(\.target.guid))
        self.continueBuildingAfterErrors = continueBuildingAfterErrors
        self.hideShellScriptEnvironment = hideShellScriptEnvironment
        self.useParallelTargets = useParallelTargets
        self.useImplicitDependencies = useImplicitDependencies
        self.useDryRun = useDryRun
        self.enableStaleFileRemoval = enableStaleFileRemoval ?? UserDefaults.enableBuildSystemStaleFileRemoval
        self.showNonLoggedProgress = showNonLoggedProgress
        self.recordBuildBacktraces = recordBuildBacktraces ?? SWBFeatureFlag.enableBuildBacktraceRecording.value
        self.generatePrecompiledModulesReport = generatePrecompiledModulesReport ?? SWBFeatureFlag.generatePrecompiledModulesReport.value
        self.buildDescriptionID = buildDescriptionID
        self.qos = qos ?? UserDefaults.defaultRequestQoS
        self.buildPlanDiagnosticsDirPath = buildPlanDiagnosticsDirPath
        self.buildCommand = buildCommand ?? .build(style: .buildOnly, skipDependencies: false)
        self.schemeCommand = schemeCommand
        self.containerPath = containerPath
        self.jsonRepresentation = jsonRepresentation
    }

    public var description: String {
        return "\(type(of: self))(\(parameters), \(buildTargets), continueBuildingAfterErrors: \(continueBuildingAfterErrors), hideShellScriptEnvironment: \(hideShellScriptEnvironment), useParallelTargets: \(useParallelTargets), useImplicitDependencies: \(useImplicitDependencies), useDryRun: \(useDryRun), buildDescriptionID: \(buildDescriptionID?.rawValue ?? "<nil>"), buildCommand: \(buildCommand), schemeCommand: \(schemeCommand?.description ?? "<nil>"), containerPath: \(containerPath?.str ?? "<nil>")"
    }
}

extension BuildRequest {
    public convenience init(from payload: BuildRequestMessagePayload, workspace: SWBCore.Workspace) throws {
        let parameters = try BuildParameters(from: payload.parameters)
        let buildCommand = try BuildCommand(from: payload.buildCommand, workspace: workspace)
        let qos: SWBQoS
        if let payloadQoS = payload.qos {
            switch payloadQoS {
            case .background: qos = .background
            case .utility: qos = .utility
            case .default: qos = .default
            case .userInitiated: qos = .userInitiated
            }
        } else {
            qos = UserDefaults.defaultRequestQoS
        }
        let dependencyScope: DependencyScope
        switch payload.dependencyScope {
        case .workspace:
            dependencyScope = .workspace
        case .buildRequest:
            dependencyScope = .buildRequest
        }
        try self.init(parameters: parameters, buildTargets: payload.configuredTargets.map{ try BuildRequest.BuildTargetInfo(from: $0, defaultParameters: parameters, workspace: workspace) }, dependencyScope: dependencyScope, continueBuildingAfterErrors: payload.continueBuildingAfterErrors, hideShellScriptEnvironment: payload.hideShellScriptEnvironment, useParallelTargets: payload.useParallelTargets, useImplicitDependencies: payload.useImplicitDependencies, useDryRun: payload.useDryRun, enableStaleFileRemoval: nil, showNonLoggedProgress: payload.showNonLoggedProgress, recordBuildBacktraces: payload.recordBuildBacktraces, generatePrecompiledModulesReport: payload.generatePrecompiledModulesReport, buildDescriptionID: payload.buildDescriptionID.map(BuildDescriptionID.init), qos: qos, buildPlanDiagnosticsDirPath: payload.buildPlanDiagnosticsDirPath, buildCommand: buildCommand, schemeCommand: payload.schemeCommand?.coreRepresentation, containerPath: payload.containerPath, jsonRepresentation: payload.jsonRepresentation)
    }

    /// Whether the build request _explicitly_ contains the specified `target`.
    ///
    /// Note that the target may still be built in the build operation due to explicit or implicit dependencies
    /// including it in the dependency closure. This method is only used when the `skipDependencies` flag is active
    /// in the build request.
    public func contains(target: Target) -> Bool {
        return buildTargetGUIDs.contains(target.guid)
    }

    /// Whether build execution should skip `target`.
    public func shouldSkipExecution(target: Target) -> Bool {
        let buildOnlyTopLevelTargets: Bool
        switch buildCommand {
        case .singleFileBuild:
            // Single file analyze should only build top-level targets.
            buildOnlyTopLevelTargets = parameters.overrides["RUN_CLANG_STATIC_ANALYZER"] == "YES"
        case .generateAssemblyCode, .generatePreprocessedFile:
            buildOnlyTopLevelTargets = true
        case .prepareForIndexing:
            buildOnlyTopLevelTargets = false
        case let .build(_, skipDependencies):
            buildOnlyTopLevelTargets = skipDependencies
        case .preview, .cleanBuildFolder:
            return false
        }

        return buildOnlyTopLevelTargets && !contains(target: target)
    }

    /// Whether the build command had the `skipDependencies` flag set.
    ///
    /// Note that dependencies may still be skipped in other cases, for example in single-file builds.
    public var skipDependencies: Bool {
        if case let .build(_, skipDependencies) = buildCommand {
            return skipDependencies
        }
        return false
    }
}

private extension BuildRequest.BuildTargetInfo {
    init(from payload: ConfiguredTargetMessagePayload, defaultParameters: BuildParameters, workspace: SWBCore.Workspace) throws {
        guard let target = workspace.target(for: payload.guid) else { throw MsgParserError.missingTarget(guid: payload.guid) }
        try self.init(parameters: payload.parameters.map{ try BuildParameters(from: $0) } ?? defaultParameters, target: target)
    }
}

public enum MsgParserError: Swift.Error {
    case missingKey(name: String)
    case missingProject(guid: String)
    case missingTarget(guid: String)
    case invalidBuildAction(name: String)
    case invalidMessage(description: String)
    case missingWorkspaceContext
    case unknownSession(handle: String)
    case missingPlanningOperation
    case missingClientExchange
    case missingSettings
    case swiftMigrationNoLongerAvailable
}
