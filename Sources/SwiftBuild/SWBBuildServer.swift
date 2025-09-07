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
#if !os(iOS)
import BuildServerProtocol
public import LanguageServerProtocol
public import LanguageServerProtocolTransport
public import ToolsProtocolsSwiftExtensions
import SWBProtocol
import SWBUtil
import Foundation

/// Wraps a `SWBBuildServiceSession` to expose Build Server Protocol functionality.
public actor SWBBuildServer: QueueBasedMessageHandler {
    /// The session used for underlying build system functionality.
    private let session: SWBBuildServiceSession
    enum PIFSource {
        // PIF should be loaded from the container at the given path
        case container(String)
        // PIF will be transferred to the session externally
        case session
    }
    /// The source of PIF describing the workspace for this build server.
    private let pifSource: PIFSource
    /// The build request representing preparation.
    private let buildRequest: SWBBuildRequest
    /// The currently planned build description used to fulfill requests.
    private var buildDescriptionID: SWBBuildDescriptionID? = nil

    private var indexStorePath: String? {
        buildRequest.parameters.arenaInfo?.indexDataStoreFolderPath.map {
            Path($0).dirname.join("index-store").str
        }
    }
    private var indexDatabasePath: String? {
        buildRequest.parameters.arenaInfo?.indexDataStoreFolderPath
    }

    public let messageHandlingHelper = QueueBasedMessageHandlerHelper(
        signpostLoggingCategory: "build-server-message-handling",
        createLoggingScope: false
    )
    public let messageHandlingQueue = AsyncQueue<BuildServerMessageDependencyTracker>()
    /// Used to serialize workspace loading.
    private let workspaceLoadingQueue = AsyncQueue<Serial>()
    /// Used to serialize preparation builds, which cannot run concurrently.
    private let preparationQueue = AsyncQueue<Serial>()
    /// Connection used to send messages to the client of the build server (an LSP or higher-level BSP implementation).
    private let connectionToClient: any Connection

    /// Represents the lifetime of the build server implementation..
    enum ServerState: CustomStringConvertible {
        case waitingForInitializeRequest
        case waitingForInitializedNotification
        case running
        case shutdown

        var description: String {
            switch self {
            case .waitingForInitializeRequest:
                "waiting for initialization request"
            case .waitingForInitializedNotification:
                "waiting for initialization notification"
            case .running:
                "running"
            case .shutdown:
                "shutdown"
            }
        }
    }
    var state: ServerState = .waitingForInitializeRequest
    /// Allows customization of server exit behavior.
    var exitHandler: (Int) async -> Void

    public static let sessionPIFURI = DocumentURI(.init(string: "swift-build://session-pif")!)

    public init(session: SWBBuildServiceSession, containerPath: String, buildRequest: SWBBuildRequest, connectionToClient: any Connection, exitHandler: @escaping (Int) async -> Void) {
        self.init(session: session, pifSource: .container(containerPath), buildRequest: buildRequest, connectionToClient: connectionToClient, exitHandler: exitHandler)
    }

    public init(session: SWBBuildServiceSession, buildRequest: SWBBuildRequest, connectionToClient: any Connection, exitHandler: @escaping (Int) async -> Void) {
        self.init(session: session, pifSource: .session, buildRequest: buildRequest, connectionToClient: connectionToClient, exitHandler: exitHandler)
    }

    private init(session: SWBBuildServiceSession, pifSource: PIFSource, buildRequest: SWBBuildRequest, connectionToClient: any Connection, exitHandler: @escaping (Int) async -> Void) {
        self.session = session
        self.pifSource = pifSource
        self.buildRequest = Self.preparationRequest(for: buildRequest)
        self.connectionToClient = connectionToClient
        self.exitHandler = exitHandler
    }

    /// Derive a request suitable from preparation from one suitable for a normal build.
    private static func preparationRequest(for buildRequest: SWBBuildRequest) -> SWBBuildRequest {
        var updatedBuildRequest = buildRequest
        updatedBuildRequest.buildCommand = .prepareForIndexing(
            buildOnlyTheseTargets: nil,
            enableIndexBuildArena: true
        )
        updatedBuildRequest.enableIndexBuildArena = true
        updatedBuildRequest.continueBuildingAfterErrors = true

        updatedBuildRequest.parameters.action = "indexbuild"
        var overridesTable = buildRequest.parameters.overrides.commandLine ?? SWBSettingsTable()
        overridesTable.set(value: "YES", for: "ONLY_ACTIVE_ARCH")
        updatedBuildRequest.parameters.overrides.commandLine = overridesTable
        for targetIndex in updatedBuildRequest.configuredTargets.indices {
            updatedBuildRequest.configuredTargets[targetIndex].parameters?.action = "indexbuild"
            var overridesTable = updatedBuildRequest.configuredTargets[targetIndex].parameters?.overrides.commandLine ?? SWBSettingsTable()
            overridesTable.set(value: "YES", for: "ONLY_ACTIVE_ARCH")
            updatedBuildRequest.configuredTargets[targetIndex].parameters?.overrides.commandLine = overridesTable
        }

        return updatedBuildRequest
    }

    public func handle(notification: some NotificationType) async {
        switch notification {
        case is OnBuildExitNotification:
            if state == .shutdown {
                await exitHandler(0)
            } else {
                await exitHandler(1)
            }
        case is OnBuildInitializedNotification:
            guard state == .waitingForInitializedNotification else {
                logToClient(.error, "Build initialized notification received while the build server is \(state.description)")
                break
            }
            state = .running
        case let notification as OnWatchedFilesDidChangeNotification:
            if state != .running {
                logToClient(.error, "Watched files changed notification received while the build server is \(state.description)")
            }
            for change in notification.changes {
                switch pifSource {
                case .container(let containerPath):
                    if change.uri == DocumentURI(.init(filePath: containerPath)) {
                        scheduleRegeneratingBuildDescription()
                        return
                    }
                case .session:
                    if change.uri == Self.sessionPIFURI {
                        scheduleRegeneratingBuildDescription()
                        return
                    }
                }
            }
        default:
            logToClient(.error, "Unknown notification type received")
            break
        }
    }

    public func handle<Request: RequestType>(
        request: Request,
        id: RequestID,
        reply: @Sendable @escaping (LSPResult<Request.Response>) -> Void
    ) async {
        let request = RequestAndReply(request, reply: reply)
        if !(request.params is InitializeBuildRequest) {
            let state = self.state
            guard state == .running else {
                await request.reply { throw ResponseError.unknown("Request received while the build server is \(state.description)") }
                return
            }
        }
        switch request {
        case let request as RequestAndReply<BuildShutdownRequest>:
            await request.reply { await shutdown() }
        case let request as RequestAndReply<BuildTargetPrepareRequest>:
            await request.reply { try await prepare(request: request.params) }
        case let request as RequestAndReply<BuildTargetSourcesRequest>:
            await request.reply { try await buildTargetSources(request: request.params) }
        case let request as RequestAndReply<InitializeBuildRequest>:
            await request.reply { try await self.initialize(request: request.params) }
        case let request as RequestAndReply<TextDocumentSourceKitOptionsRequest>:
            await request.reply { try await sourceKitOptions(request: request.params) }
        case let request as RequestAndReply<WorkspaceBuildTargetsRequest>:
            await request.reply { try await buildTargets(request: request.params) }
        case let request as RequestAndReply<WorkspaceWaitForBuildSystemUpdatesRequest>:
            await request.reply { await waitForBuildSystemUpdates(request: request.params) }
        default:
            await request.reply { throw ResponseError.methodNotFound(Request.method) }
        }
    }

    private func initialize(request: InitializeBuildRequest) throws -> InitializeBuildResponse {
        guard state == .waitingForInitializeRequest else {
            throw ResponseError.unknown("Received initialization request while the build server is \(state)")
        }
        state = .waitingForInitializedNotification
        scheduleRegeneratingBuildDescription()
        return InitializeBuildResponse(
            displayName: "Swift Build Server (Session: \(session.uid))",
            version: "",
            bspVersion: "2.2.0",
            capabilities: BuildServerCapabilities(),
            dataKind: .sourceKit,
            data: SourceKitInitializeBuildResponseData(
                indexDatabasePath: indexDatabasePath,
                indexStorePath: indexStorePath,
                outputPathsProvider: true,
                prepareProvider: true,
                sourceKitOptionsProvider: true,
                watchers: []
            ).encodeToLSPAny()
        )
    }

    private func shutdown() -> LanguageServerProtocol.VoidResponse {
        state = .shutdown
        return VoidResponse()
    }

    private func waitForBuildSystemUpdates(request: WorkspaceWaitForBuildSystemUpdatesRequest) async -> LanguageServerProtocol.VoidResponse {
        await workspaceLoadingQueue.async {}.valuePropagatingCancellation
        return VoidResponse()
    }

    private func scheduleRegeneratingBuildDescription() {
        workspaceLoadingQueue.async {
            do {
                try await self.logTaskToClient(name: "Generating build description") { log in
                    switch self.pifSource {
                    case .container(let containerPath):
                        try await self.session.loadWorkspace(containerPath: containerPath)
                    case .session:
                        break
                    }
                    try await self.session.setSystemInfo(.default())
                    let buildDescriptionOperation = try await self.session.createBuildOperationForBuildDescriptionOnly(
                        request: self.buildRequest,
                        delegate: PlanningOperationDelegate()
                    )
                    var buildDescriptionID: BuildDescriptionID?
                    for try await event in try await buildDescriptionOperation.start() {
                        guard case .reportBuildDescription(let info) = event else {
                            continue
                        }
                        guard buildDescriptionID == nil else {
                            throw ResponseError.unknown("Unexpectedly reported multiple build descriptions")
                        }
                        buildDescriptionID = BuildDescriptionID(info.buildDescriptionID)
                    }
                    guard let buildDescriptionID else {
                        throw ResponseError.unknown("Failed to get build description ID")
                    }
                    self.buildDescriptionID = SWBBuildDescriptionID(buildDescriptionID)
                }
            } catch {
                self.logToClient(.error, "Error generating build description: \(error)")
            }
        }
    }

    private func buildTargets(request: WorkspaceBuildTargetsRequest) async throws -> WorkspaceBuildTargetsResponse {
        try await logTaskToClient(name: "Computing targets list") { _ in
            guard let buildDescriptionID else {
                throw ResponseError.unknown("No build description")
            }
            let targets = try await session.configuredTargets(
                buildDescription: buildDescriptionID,
                buildRequest: buildRequest
            ).asyncMap { targetInfo in
                let tags = try await session.evaluateMacroAsStringList(
                    "BUILD_SERVER_PROTOCOL_TARGET_TAGS",
                    level: .target(targetInfo.identifier.targetGUID.rawValue),
                    buildParameters: buildRequest.parameters,
                    overrides: nil
                ).filter {
                    !$0.isEmpty
                }.map {
                    BuildTargetTag(rawValue: $0)
                }
                let toolchain: DocumentURI? =
                if let toolchain = targetInfo.toolchain {
                    DocumentURI(filePath: toolchain.pathString, isDirectory: true)
                } else {
                    nil
                }

                return BuildTarget(
                    id: try BuildTargetIdentifier(configuredTargetIdentifier: targetInfo.identifier),
                    displayName: targetInfo.name,
                    baseDirectory: nil,
                    tags: tags,
                    capabilities: BuildTargetCapabilities(),
                    languageIds: [.c, .cpp, .objective_c, .objective_cpp, .swift],
                    dependencies: try targetInfo.dependencies.map {
                        try BuildTargetIdentifier(configuredTargetIdentifier: $0)
                    },
                    dataKind: .sourceKit,
                    data: SourceKitBuildTarget(toolchain: toolchain).encodeToLSPAny()
                )
            }

            return WorkspaceBuildTargetsResponse(targets: targets)
        }
    }

    private func buildTargetSources(request: BuildTargetSourcesRequest) async throws -> BuildTargetSourcesResponse {
        try await logTaskToClient(name: "Computing sources list") { _ in
            guard let buildDescriptionID else {
                throw ResponseError.unknown("No build description")
            }
            let response = try await session.sources(
                of: request.targets.map { try $0.configuredTargetIdentifier },
                buildDescription: buildDescriptionID,
                buildRequest: buildRequest
            )
            let sourcesItems = try response.compactMap { (swbSourcesItem) -> SourcesItem? in
                let sources = swbSourcesItem.sourceFiles.map { sourceFile in
                    SourceItem(
                        uri: DocumentURI(URL(filePath: sourceFile.path.pathString)),
                        kind: .file,
                        // Should `generated` check if the file path is a descendant of OBJROOT/DERIVED_SOURCES_DIR?
                        // SourceKit-LSP doesn't use this currently.
                        generated: false,
                        dataKind: .sourceKit,
                        data: SourceKitSourceItemData(
                            language: Language(sourceFile.language),
                            outputPath: sourceFile.indexOutputPath
                        ).encodeToLSPAny()
                    )
                }
                return SourcesItem(
                    target: try BuildTargetIdentifier(configuredTargetIdentifier: swbSourcesItem.configuredTarget),
                    sources: sources
                )
            }
            return BuildTargetSourcesResponse(items: sourcesItems)
        }
    }

    private func sourceKitOptions(request: TextDocumentSourceKitOptionsRequest) async throws -> TextDocumentSourceKitOptionsResponse? {
        try await logTaskToClient(name: "Computing compiler options") { _ in
            guard let buildDescriptionID else {
                throw ResponseError.unknown("No build description")
            }
            guard let fileURL = request.textDocument.uri.fileURL else {
                throw ResponseError.unknown("Text document is not a file")
            }
            let response = try await session.indexCompilerArguments(
                of: AbsolutePath(validating: fileURL.filePath.str),
                in: request.target.configuredTargetIdentifier,
                buildDescription: buildDescriptionID,
                buildRequest: buildRequest
            )
            return TextDocumentSourceKitOptionsResponse(compilerArguments: response)
        }
    }

    private func prepare(request: BuildTargetPrepareRequest) async throws -> LanguageServerProtocol.VoidResponse {
        try await preparationQueue.asyncThrowing {
            var updatedBuildRequest = self.buildRequest
            let targetGUIDs = try request.targets.map {
                try $0.configuredTargetIdentifier.targetGUID.rawValue
            }
            updatedBuildRequest.buildCommand = .prepareForIndexing(
                buildOnlyTheseTargets: targetGUIDs,
                enableIndexBuildArena: true
            )
            let buildOperation = try await self.session.createBuildOperation(
                request: updatedBuildRequest,
                delegate: PlanningOperationDelegate()
            )
            try await self.logTaskToClient(name: "Preparing targets") { taskID in
                let events = try await buildOperation.start()
                await self.reportEventStream(events)
                await buildOperation.waitForCompletion()
            }
        }.valuePropagatingCancellation
        return VoidResponse()
    }

    private func reportEventStream(_ events: AsyncStream<SwiftBuildMessage>) async {
        for try await event in events {
            switch event {
            case .planningOperationStarted(_):
                logToClient(.log, "Planning Build", .begin(.init(title: "Planning Build")))
            case .planningOperationCompleted(_):
                logToClient(.info, "Build Planning Complete", .end(.init()))
            case .buildStarted(_):
                logToClient(.log, "Building", .begin(.init(title: "Building")))
            case .buildDiagnostic(let info):
                logToClient(.log, info.message, .report(.init()))
            case .buildCompleted(let info):
                switch info.result {
                case .ok:
                    logToClient(.log, "Build Complete", .end(.init()))
                case .failed:
                    logToClient(.log, "Build Failed", .end(.init()))
                case .cancelled:
                    logToClient(.log, "Build Cancelled", .end(.init()))
                case .aborted:
                    logToClient(.log, "Build Aborted", .end(.init()))
                }
            case .preparationComplete(_):
                logToClient(.log, "Build Preparation Complete", .end(.init()))
            case .didUpdateProgress(_):
                break
            case .taskStarted(let info):
                logToClient(.log, info.executionDescription, .begin(.init(title: info.executionDescription)))
            case .taskDiagnostic(let info):
                logToClient(.log, info.message, .report(.init()))
            case .taskComplete(_):
                break
            case .targetDiagnostic(let info):
                logToClient(.log, info.message, .report(.init()))
            case .diagnostic(let info):
                logToClient(.log, info.message, .report(.init()))
            case .backtraceFrame, .reportPathMap, .reportBuildDescription, .preparedForIndex, .buildOutput, .targetStarted, .targetComplete, .targetOutput, .targetUpToDate, .taskUpToDate, .taskOutput, .output:
                break
            }
        }
    }

    private func logToClient(_ kind: BuildServerProtocol.MessageType, _ message: String, _ structure: BuildServerProtocol.StructuredLogKind? = nil) {
        connectionToClient.send(
            OnBuildLogMessageNotification(type: .log, message: "\(message)", structure: structure)
        )
    }

    private func logTaskToClient<T>(name: String, _ perform: (String) async throws -> T) async throws -> T {
        let taskID = UUID().uuidString
        logToClient(.log, name, .begin(.init(title: name)))
        defer {
            logToClient(.log, name, .end(.init()))
        }
        return try await perform(taskID)
    }
}

extension BuildTargetIdentifier {
    static let swiftBuildBuildServerTargetScheme = "swift-build"

    init(configuredTargetIdentifier: SWBConfiguredTargetIdentifier) throws {
        var components = URLComponents()
        components.scheme = Self.swiftBuildBuildServerTargetScheme
        components.host = "configured-target"
        components.queryItems = [
            URLQueryItem(name: "configuredTargetGUID", value: configuredTargetIdentifier.rawGUID),
            URLQueryItem(name: "targetGUID", value: configuredTargetIdentifier.targetGUID.rawValue),
        ]

        struct FailedToConvertSwiftBuildTargetToUrlError: Swift.Error, CustomStringConvertible {
            var configuredTargetIdentifier: SWBConfiguredTargetIdentifier

            var description: String {
                return "Failed to generate URL for configured target '\(configuredTargetIdentifier.rawGUID)'"
            }
        }

        guard let url = components.url else {
            throw FailedToConvertSwiftBuildTargetToUrlError(configuredTargetIdentifier: configuredTargetIdentifier)
        }

        self.init(uri: URI(url))
    }

    var isSwiftBuildBuildServerTargetID: Bool {
        uri.scheme == Self.swiftBuildBuildServerTargetScheme
    }

    var configuredTargetIdentifier: SWBConfiguredTargetIdentifier {
        get throws {
            struct InvalidTargetIdentifierError: Swift.Error, CustomStringConvertible {
                var target: BuildTargetIdentifier

                var description: String {
                    return "Invalid target identifier \(target)"
                }
            }
            guard let components = URLComponents(url: self.uri.arbitrarySchemeURL, resolvingAgainstBaseURL: false) else {
                throw InvalidTargetIdentifierError(target: self)
            }
            guard let configuredTargetGUID = components.queryItems?.last(where: { $0.name == "configuredTargetGUID" })?.value else {
                throw InvalidTargetIdentifierError(target: self)
            }
            guard let targetGUID = components.queryItems?.last(where: { $0.name == "targetGUID" })?.value else {
                throw InvalidTargetIdentifierError(target: self)
            }

            return SWBConfiguredTargetIdentifier(rawGUID: configuredTargetGUID, targetGUID: SWBTargetGUID(TargetGUID(rawValue: targetGUID)))
        }
    }
}

private final class PlanningOperationDelegate: SWBPlanningOperationDelegate, Sendable {
    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
        return SWBProvisioningTaskInputs()
    }

    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> SWBExternalToolResult {
        .deferred
    }
}

fileprivate extension Language {
  init?(_ language: SWBSourceLanguage?) {
    switch language {
    case nil: return nil
    case .c: self = .c
    case .cpp: self = .cpp
    case .metal: return nil
    case .objectiveC: self = .objective_c
    case .objectiveCpp: self = .objective_cpp
    case .swift: self = .swift
    }
  }
}
#endif
