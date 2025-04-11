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
import SWBProtocol
public import SWBServiceCore
import SWBTaskConstruction
import SWBTaskExecution
package import SWBUtil
import SWBMacro
import Foundation

// MARK: Core Dump Commands

private struct GetPlatformsDumpMsg: MessageHandler {
    func handle(request: Request, message: GetPlatformsRequest) throws -> StringResponse {
        return StringResponse(try request.session(for: message).core.getPlatformsDump())
    }
}

private struct GetSDKsDumpMsg: MessageHandler {
    func handle(request: Request, message: GetSDKsRequest) throws -> StringResponse {
        return StringResponse(try request.session(for: message).core.getSDKsDump())
    }
}

private struct GetToolchainsDumpMsg: MessageHandler {
    func handle(request: Request, message: GetToolchainsRequest) async throws -> StringResponse {
        return StringResponse(try await request.session(for: message).core.getToolchainsDump())
    }
}

private struct GetSpecsDumpMsg: MessageHandler {
    func handle(request: Request, message: GetSpecsRequest) throws -> StringResponse {
        let conformingTo: String?
        if let idx = message.commandLine.firstIndex(of: "--conforms-to"), idx + 1 < message.commandLine.count {
            conformingTo = message.commandLine[idx + 1]
        }  else {
            conformingTo = nil
        }
        return StringResponse(try request.session(for: message).core.getSpecsDump(conformingTo: conformingTo))
    }
}

private struct GetStatisticsDumpMsg: MessageHandler {
    func handle(request: Request, message: GetStatisticsRequest) throws -> StringResponse {
        let result = OutputByteStream()
        for statistic in SWBUtil.allStatistics.statistics.sorted(by: \.name) {
            if statistic.value != 0 {
                result <<< "swift-build.\(statistic.name): \(statistic.value)\n"
            }
        }
        return StringResponse(result.bytes.asString)
    }
}

private struct GetBuildSettingsDescriptionDumpMsg: MessageHandler {
    func handle(request: Request, message: GetBuildSettingsDescriptionRequest) throws -> StringResponse {
        return StringResponse(try request.session(for: message).core.getBuildSettingsDescriptionDump())
    }
}

// MARK: XCFramework CLI Support

private struct CreateXCFrameworkHandler: MessageHandler {
    func handle(request: Request, message: CreateXCFrameworkRequest) async throws -> StringResponse {
        guard let buildService = request.service as? BuildService else {
            throw StubError.error("service object is not of type BuildService")
        }
        let (result, output) = try await XCFramework.createXCFramework(commandLine: message.commandLine, currentWorkingDirectory: message.currentWorkingDirectory, infoLookup: buildService.sharedCore(developerPath: message.effectiveDeveloperPath.map { .xcode($0) }))
        if !result {
            throw StubError.error(output)
        }
        return StringResponse(output)
    }
}

// TODO: Delete once all clients are no longer calling the public APIs which invoke this message
private struct AvailableAppExtensionPointIdentifiersHandler: MessageHandler {
    func handle(request: Request, message: AvailableAppExtensionPointIdentifiersRequest) async throws -> StringListResponse {
        StringListResponse([])
    }
}

// TODO: Delete once all clients are no longer calling the public APIs which invoke this message
private struct MacCatalystUnavailableFrameworkNamesHandler: MessageHandler {
    func handle(request: Request, message: MacCatalystUnavailableFrameworkNamesRequest) async throws -> StringListResponse {
        StringListResponse([])
    }
}

private struct AppleSystemFrameworkNamesHandler: MessageHandler {
    func handle(request: Request, message: AppleSystemFrameworkNamesRequest) async throws -> StringListResponse {
        guard let buildService = request.service as? BuildService else {
            throw StubError.error("service object is not of type BuildService")
        }
        return try await StringListResponse([])
    }
}

private struct ProductTypeSupportsMacCatalystHandler: MessageHandler {
    func handle(request: Request, message: ProductTypeSupportsMacCatalystRequest) async throws -> BoolResponse {
        guard let buildService = request.service as? BuildService else {
            throw StubError.error("service object is not of type BuildService")
        }
        return try await BoolResponse(buildService.sharedCore(developerPath: message.effectiveDeveloperPath.map { .xcode($0) }).productTypeSupportsMacCatalyst(productTypeIdentifier: message.productTypeIdentifier))
    }
}

// MARK: Session Management

private struct CreateSessionHandler: MessageHandler {
    func handle(request: Request, message: CreateSessionRequest) async throws -> CreateSessionResponse {
        let service = request.buildService
        let developerPath: DeveloperPath?
        if let devPath = message.developerPath2 {
            developerPath = devPath
        } else if let devPath = message.effectiveDeveloperPath {
            developerPath = .xcode(devPath)
        } else {
            developerPath = nil
        }
        let (core, diagnostics) = await service.sharedCore(
            developerPath: developerPath,
            resourceSearchPaths: message.resourceSearchPaths ?? [],
            inferiorProducts: message.inferiorProductsPath,
            environment: message.environment ?? [:]
        )
        if let core {
            let session = Session(core, message.name, cachePath: message.cachePath)
            assert(service.sessionMap[session.UID] == nil)
            service.sessionMap[session.UID] = session
            return CreateSessionResponse(sessionID: session.UID, diagnostics: diagnostics)
        } else {
            return CreateSessionResponse(sessionID: nil, diagnostics: diagnostics)
        }
    }
}

private struct ListSessionsHandler: MessageHandler {
    func handle(request: Request, message: ListSessionsRequest) throws -> ListSessionsResponse {
        var items = [String: ListSessionsResponse.SessionInfo]()
        for session in request.buildService.sessionMap.values {
            let stats = session.activeBuildStats()
            items[session.UID] = .init(name: session.name, activeBuildCount: stats.all, activeNormalBuildCount: stats.normal, activeIndexBuildCount: stats.index)
        }
        return ListSessionsResponse(sessions: items)
    }
}

private struct WaitForQuiescenceHandler: MessageHandler {
    func handle(request: Request, message: WaitForQuiescenceRequest) async throws -> VoidResponse {
        let session = try request.session(for: message)
        await session.buildDescriptionManager.waitForBuildDescriptionSerialization()
        return VoidResponse()
    }
}

private struct DeleteSessionHandler: MessageHandler {
    func handle(request: Request, message: DeleteSessionRequest) async throws -> VoidResponse {
        let session = try request.session(for: message)
        await session.buildDescriptionManager.waitForBuildDescriptionSerialization()
        request.buildService.sessionMap.removeValue(forKey: session.UID)
        return VoidResponse()
    }
}

// MARK: Session State Initialization

protocol PIFProvidingRequest {
    func pifJSONData(session: Session) async throws -> [UInt8]
}

extension SetSessionWorkspaceContainerPathRequest: PIFProvidingRequest {
    func pifJSONData(session: Session) async throws -> [UInt8] {
        let fs = localFS

        let containerPath = Path(self.containerPath)

        func dumpPIF(path: Path, isProject: Bool) async throws -> Path {
            let dir = Path.temporaryDirectory.join("org.swift.swift-build").join("PIF")
            try fs.createDirectory(dir, recursive: true)
            let pifPath = dir.join(Foundation.UUID().description + ".json")
            let argument = isProject ? "-project" : "-workspace"
            let result = try await Process.getOutput(url: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["xcodebuild", "-dumpPIF", pifPath.str, argument, path.str], currentDirectoryURL: URL(fileURLWithPath: containerPath.dirname.str, isDirectory: true), environment: Environment.current.addingContents(of: [.developerDir: session.core.developerPath.path.str]))
            if !result.exitStatus.isSuccess {
                throw StubError.error("Could not dump PIF for '\(path.str)': \(String(decoding: result.stderr, as: UTF8.self))")
            }
            return pifPath
        }

        let pifPath: Path
        do {
            switch containerPath.fileExtension {
            case "xcodeproj":
                pifPath = try await dumpPIF(path: containerPath, isProject: true)
            case "xcworkspace", "":
                pifPath = try await dumpPIF(path: containerPath, isProject: false)
            case "json", "pif":
                pifPath = containerPath
            default:
                throw StubError.error("Unknown file format of container at path: \(containerPath.str)")
            }
        }

        return try fs.read(pifPath).bytes
    }
}

extension SetSessionPIFRequest: PIFProvidingRequest {
    func pifJSONData(session: Session) throws -> [UInt8] {
        return pifContents
    }
}

extension MessageHandler where MessageType: SessionMessage & PIFProvidingRequest {
    func handle(request: Request, message: MessageType) async throws -> VoidResponse {
        let session = try request.session(for: message)
        let pifItem = try await PropertyList.fromJSONData(message.pifJSONData(session: session))

        // We expect the initial object is always the workspace.
        let workspaceSignature = try PIFLoader.extractWorkspaceSignature(objects: pifItem)

        // Load the PIF data.
        let loader = PIFLoader(data: pifItem, namespace: session.core.specRegistry.internalMacroNamespace)
        let workspace = try loader.load(workspaceSignature: workspaceSignature)

        // Create the workspace context.
        session.workspaceContext = WorkspaceContext(core: session.core, workspace: workspace, processExecutionCache: ProcessExecutionCache())

        return VoidResponse()
    }
}

private struct SetSessionWorkspaceContainerPathMsg: MessageHandler {
    typealias MessageType = SetSessionWorkspaceContainerPathRequest
}

private struct SetSessionPIFMsg: MessageHandler {
    typealias MessageType = SetSessionPIFRequest
}

private struct SetSessionSystemInfoMsg: MessageHandler {
    func handle(request: Request, message: SetSessionSystemInfoRequest) throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }

        // Update the workspace context.
        workspaceContext.updateSystemInfo(SystemInfo(operatingSystemVersion: message.operatingSystemVersion, productBuildVersion: message.productBuildVersion, nativeArchitecture: message.nativeArchitecture))

        return VoidResponse()
    }
}

private struct SetSessionUserInfoMsg: MessageHandler {
    func handle(request: Request, message: SetSessionUserInfoRequest) async throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }

        struct Context: EnvironmentExtensionAdditionalEnvironmentVariablesContext {
            var hostOperatingSystem: OperatingSystem
            var fs: any FSProxy
        }

        // Update the workspace context.
        let env = try await EnvironmentExtensionPoint.additionalEnvironmentVariables(pluginManager: workspaceContext.core.pluginManager, context: Context(hostOperatingSystem: workspaceContext.core.hostOperatingSystem, fs: workspaceContext.fs))
        workspaceContext.updateUserInfo(try await UserInfo(user: message.user, group: message.group, uid: message.uid, gid: message.gid, home: Path(message.home), processEnvironment: message.processEnvironment, buildSystemEnvironment: message.buildSystemEnvironment).addingPlatformDefaults(from: env))

        return VoidResponse()
    }
}

private struct SetSessionUserPreferencesMsg: MessageHandler {
    func handle(request: Request, message: SetSessionUserPreferencesRequest) throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }

        workspaceContext.updateUserPreferences(UserPreferences(
            enableDebugActivityLogs: message.enableDebugActivityLogs,
            enableBuildDebugging: message.enableBuildDebugging,
            enableBuildSystemCaching: message.enableBuildSystemCaching,
            activityTextShorteningLevel: message.activityTextShorteningLevel,
            usePerConfigurationBuildLocations: message.usePerConfigurationBuildLocations,
            allowsExternalToolExecution: message.allowsExternalToolExecution ?? UserPreferences.allowsExternalToolExecutionDefaultValue)
        )

        return VoidResponse()
    }
}

/// Start a PIF transfer from the client.
///
/// This will establish a workspace context in the relevant session by exchanging a PIF from the client to the service incrementally, only transferring subobjects as necessary.
private struct TransferSessionPIFMsg: MessageHandler {
    static func operationResult(_ operation: Session.PIFTransferOperation) throws -> TransferSessionPIFResponse {
        // Get the list of missing objects.
        switch operation.continueOperation() {
        case .complete:
            return TransferSessionPIFResponse(missingObjects: [])

        case .failed(let error):
            throw StubError.error("unable to load transferred PIF: \(error)")

        case .auditFailed(let diff):
            // this string is checked for on the IDE side.
            throw StubError.error("incremental PIF transfer did not produce the right contents. Diff: \(diff)")

        case .incomplete(let missingObjects):
            return TransferSessionPIFResponse(missingObjects: missingObjects.map{ TransferSessionPIFResponse.MissingObject(type: $0.type, signature: $0.signature) })
        }
    }

    func handle(request: Request, message: TransferSessionPIFRequest) throws -> TransferSessionPIFResponse {
        let session = try request.session(for: message)

        // It is an error if the session is already in the middle of loading a PIF.
        guard let operation = session.startPIFTransfer(workspaceSignature: message.workspaceSignature) else {
            throw MsgHandlingError("unable to initiate PIF transfer session (operation in progress?)")
        }

        // Return the appropriate result.
        return try TransferSessionPIFMsg.operationResult(operation)
    }
}

/// Transfer additional PIF objects.
///
/// This is part of the protocol to transfer a legacy (JSON) PIF, see `TransferSessionPIFMsg`.
private struct TransferSessionPIFObjectsLegacyMsg: MessageHandler {
    func handle(request: Request, message: TransferSessionPIFObjectsLegacyRequest) throws -> TransferSessionPIFResponse {
        let session = try request.session(for: message)

        // It is an error if the session doesn't have a transfer operation.
        guard let operation = session.currentPIFTransferOperation else {
            throw MsgHandlingError("no PIF transfer has been initiated")
        }

        // Add the objects.
        for object in message.objects {
            do {
                try operation.loadingSession.add(object: PropertyList.fromJSONData(object))
            } catch {
                // If the operation failed, cancel the session completely.
                operation.cancel()

                throw error
            }
        }

        // Return the appropriate result.
        return try TransferSessionPIFMsg.operationResult(operation)
    }
}

/// Transfer additional PIF objects.
///
/// This is part of the protocol to transfer a PIF, see `TransferSessionPIFMsg`.
private struct TransferSessionPIFObjectsMsg: MessageHandler {
    func handle(request: Request, message: TransferSessionPIFObjectsRequest) throws -> TransferSessionPIFResponse {
        let session = try request.session(for: message)

        // It is an error if the session doesn't have a transfer operation.
        guard let operation = session.currentPIFTransferOperation else {
            throw MsgHandlingError("no PIF transfer has been initiated")
        }

        // Add the objects.
        for object in message.objects {
            do {
                try operation.loadingSession.add(pifType: object.pifType, object: .binary(object.data), signature: object.signature)
            } catch {
                // If the operation failed, cancel the session completely.
                operation.cancel()

                throw error
            }
        }

        // Return the appropriate result.
        return try TransferSessionPIFMsg.operationResult(operation)
    }
}

/// Receive an audit PIF from the client, so that when PIF transfer has finished it can be used to compare against the fully-loaded PIF we received (perhaps in pieces) from the client.
private struct AuditSessionPIFMsg: MessageHandler {
    func handle(request: Request, message: AuditSessionPIFRequest) throws -> TransferSessionPIFResponse {
        let session = try request.session(for: message)

        guard let operation = session.currentPIFTransferOperation else {
            throw MsgHandlingError("no PIF transfer has been initiated")
        }

        do {
            try operation.setComparisonPIF(objects: PropertyList.fromJSONData(message.pifContents))
        } catch {
            // If the operation failed, cancel the session completely.
            operation.cancel()

            throw error
        }

        return try TransferSessionPIFMsg.operationResult(operation)
    }
}

/// Handles the incremental PIF lookup failure request.
///
/// If the PIF cache was used during the transfer, we remove the cache and restart the operation.
private struct IncrementalPIFRetransmissionMsg: MessageHandler {
    func handle(request: Request, message: IncrementalPIFLookupFailureRequest) throws -> TransferSessionPIFResponse {
        let session = try request.session(for: message)

        // Get the current PIF transfer operation.
        guard let currentPIFOperation = session.currentPIFTransferOperation else {
            throw MsgHandlingError("no PIF transfer has been initiated")
        }

        // If we didn't load anything from cache, just return failure.
        if !currentPIFOperation.loadingSession.didUseCache {
            throw MsgHandlingError("unable to load transferred PIF: \(message.diagnostic)")
        }

        // Cancel the current operation.
        currentPIFOperation.cancel()

        // Start a new pristine PIF transfer operation.
        guard let operation = session.startPristinePIFTransfer(workspaceSignature: currentPIFOperation.workspaceSignature) else {
            throw MsgHandlingError("unable to initiate pristine PIF transfer session")
        }

        return try TransferSessionPIFMsg.operationResult(operation)
    }
}

// MARK: Workspace Model Commands

private struct WorkspaceInfoMsg: MessageHandler {
    func handle(request: Request, message: WorkspaceInfoRequest) throws -> WorkspaceInfoResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }

        return WorkspaceInfoResponse(sessionHandle: session.UID, workspaceInfo: .init(targetInfos: workspaceContext.workspace.projects.flatMap { project in
            return project.targets.map { target in
                return .init(guid: target.guid, targetName: target.name, projectName: project.name)
            }
        }))
    }
}

// MARK: Session Commands

private struct CreateBuildRequestMsg: MessageHandler {
    func handle(request: Request, message: CreateBuildRequest) throws -> BuildCreated {
        let session = try request.session(for: message)

        if BuildAction(actionName: message.request.parameters.action) == .indexBuild {
            // An indexbuild action should only cancel indexing info operations
            session.cancelIndexingInfoOperations()
        } else {
            // Cancel all info operations for any other build action.
            session.cancelInfoOperations()
        }

        let build = try request.buildService.createBuildOperation(request: request, message: message)

        return BuildCreated(id: build.id)
    }
}

private struct BuildStartRequestMsg: MessageHandler {
    func handle(request: Request, message: BuildStartRequest) throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let build = session.activeBuild(for: message.id) else {
            throw StubError.error("Invalid request for nonexistent build ID: '\(message.id)'")
        }
        build.start()
        return VoidResponse()
    }
}

private struct BuildCancelRequestMsg: MessageHandler {
    func handle(request: Request, message: BuildCancelRequest) throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let build = session.activeBuild(for: message.id) else {
            // It's possible that the build completed before the information reached the client that is trying to cancel it. Handle it as no-op.
            return VoidResponse()
        }
        build.cancel()
        return VoidResponse()
    }
}

package class InfoOperation {
    private var isCancelled: LockedValue<Bool> = .init(false)
    package var cancelled: Bool { return isCancelled.withLock{$0} }
    package func cancel() {
        isCancelled.withLock{$0 = true}
        tasks.withLock {
            for task in $0 {
                task.cancel()
            }
        }
    }

    private let tasks: LockedValue<[_Concurrency.Task<Void, Never>]> = .init([])
    package func addTask(_ task: _Concurrency.Task<Void, Never>) {
        tasks.withLock { $0.append(task) }
    }

    private static let lastID: LockedValue<Int> = .init(0)
    package let id: Int

    package let diagnosticContext: DiagnosticContextData

    package init(workspace: SWBCore.Workspace) {
        self.id = InfoOperation.lastID.withLock {
            let id = $0
            $0 += 1
            return id
        }

        self.diagnosticContext = DiagnosticContextData(target: nil)
    }
}

final class IndexingOperation: InfoOperation, BuildDescriptionConstructionDelegate, PlanningOperationDelegate, TargetDependencyResolverDelegate {
    private let _diagnosticsEngine = DiagnosticsEngine()

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    var diagnostics: [ConfiguredTarget? : [Diagnostic]] {
        [nil: _diagnosticsEngine.diagnostics]
    }

    package func updateProgress(statusMessage: String, showInLog: Bool) { }

    package func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID { .init(rawValue: -1) }
    package func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) { }
    package func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) { }
    package func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) { }

    package func buildDescriptionCreated(_ buildDescriptionID: BuildDescriptionID) { }

    // We don't care about the individual diagnostics here, only if there was at least one error.
    package private(set) var hadErrors = false
    package func emit(_ diagnostic: Diagnostic) {
        if diagnostic.behavior == .error {
            hadErrors = true
        }
    }
}

fileprivate enum ResultOrErrorMessage<T> {
    case success(T)
    case failed(any Message)
}

/// Gets the build description from a build description ID.
fileprivate func getIndexBuildDescriptionFromID(buildDescriptionID: BuildDescriptionID, request: Request, session: Session, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, workspaceContext: WorkspaceContext, constructionDelegate: any BuildDescriptionConstructionDelegate) async -> ResultOrErrorMessage<BuildDescription> {
    let clientDelegate = ClientExchangeDelegate(request: request, session: session)
    do {
        let descRequest = BuildDescriptionManager.BuildDescriptionRequest.cachedOnly(buildDescriptionID, request: buildRequest, buildRequestContext: buildRequestContext, workspaceContext: workspaceContext)
        guard let retrievedBuildDescription = try await session.buildDescriptionManager.getNewOrCachedBuildDescription(descRequest, clientDelegate: clientDelegate, constructionDelegate: constructionDelegate) else {
            // If we don't receive a build description it means we were cancelled.
            return .failed(VoidResponse())
        }
        return .success(retrievedBuildDescription.buildDescription)
    } catch {
        return .failed(ErrorResponse("unable to get build description: \(error)"))
    }
}

private struct GetIndexingFileSettingsMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: IndexingFileSettingsRequest) async throws -> VoidResponse {
        try await handleIndexingInfoRequest(serializationQueue: Self.serializationQueue, request: request, message: message) { message, workspaceContext, buildRequest, buildRequestContext, buildDescription, target, elapsedTimer in
#if DEBUG
            // We record the source files we see and report if a particular source file
            // is encountered more than once.
            var seenPaths = Set<Path>()
#endif

            // Collect and return the indexing info.  The indexing info is sent as a property list defined by the SourceFileIndexingInfo object, so there is presently no need for client-side changes to handle this info (and thus little change of revlock issues between the client and the service).  In the future we hope to provide strong typing for this data.

            let indexingInfoInput = TaskGenerateIndexingInfoInput(requestedSourceFile: message.filePath.map(Path.init), outputPathOnly: message.outputPathOnly, enableIndexBuildArena: buildRequest.enableIndexBuildArena)
            do {
                let resultArray: [PropertyListItem] = try buildDescription.taskStore.tasksForTarget(target).flatMap { task in
                    try task.generateIndexingInfo(input: indexingInfoInput).map { info in
                        let path = info.path
                        let indexingInfo = info.indexingInfo

#if DEBUG
                        if !seenPaths.insert(path).inserted {
                            log("Duplicate source file for indexing \(path)")
                        }
#endif

                        guard case .plDict(let indexingInfoDict) = indexingInfo.propertyListItem else {
                            throw StubError.error("Internal error: expected plDict from \(indexingInfo)")
                        }

                        return try .plDict(indexingInfoDict.merging(["sourceFilePath": .plString(path.str)], uniquingKeysWith: { _, _ in
                            throw StubError.error("Internal error: unexpected sourceFilePath key in \(indexingInfo)")
                        }))
                    }
                }

                if UserDefaults.enableIndexingPayloadSerialization {
                    let duration = elapsedTimer.elapsedTime()
                    let date = Date()
                    let dateString = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds, .withTimeZone])

                    let payloadsDirectory = buildDescription.dir.join("IndexingPayloads")
                    try workspaceContext.fs.createDirectory(payloadsDirectory, recursive: true)
                    let obj = PropertyListItem.plDict([
                        "targetID": .plString(message.targetID),
                        "duration": .plDict([
                            "seconds": .plDouble(duration.seconds),
                            "nanoseconds": .plDouble(Double(duration.nanoseconds)),
                        ]),
                        "data": .plArray(resultArray)
                    ])

                    try workspaceContext.fs.write(payloadsDirectory.join("\(dateString).json"), contents: obj.asJSONFragment())
                }

                let resultBytes = ByteString(try PropertyListItem.plArray(resultArray).asBytes(.binary))
                return IndexingFileSettingsResponse(targetID: message.targetID, data: resultBytes)
            } catch {
                return ErrorResponse("could not serialize result array to binary property list: \(error)")
            }
        }
    }
}

private struct GetIndexingHeaderInfoMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: IndexingHeaderInfoRequest) async throws -> VoidResponse {
        try await handleIndexingInfoRequest(serializationQueue: Self.serializationQueue, request: request, message: message) { message, workspaceContext, buildRequest, buildRequestContext, buildDescription, target, elapsedTimer in
            var allTargetOutputPaths: Set<String> = Set()
            for task in buildDescription.taskStore.tasksForTarget(target) {
                guard !task.isGate else { continue }
                allTargetOutputPaths.formUnion(task.outputPaths.map { $0.str })
            }

            let productName = buildRequestContext.getCachedSettings(target.parameters, target: target.target).globalScope.evaluate(BuiltinMacros.PRODUCT_NAME)
            let copiedHeaders = Dictionary(uniqueKeysWithValues: allTargetOutputPaths.intersection(buildDescription.copiedPathMap.keys).compactMap { path -> (String, String)? in
                guard let copiedPath = buildDescription.copiedPathMap[path], ProjectHeaderInfo.headerFileExtensions.contains(Path(copiedPath).fileExtension) else { return nil }
                return (path, copiedPath)
            })

            return IndexingHeaderInfoResponse(targetID: message.targetID, productName: productName, copiedPathMap: copiedHeaders)
        }
    }
}

extension MessageHandler {
    fileprivate func handleIndexingInfoRequest<T: IndexingInfoRequest>(serializationQueue: ActorLock, request: Request, message: T, _ transformResponse: @escaping @Sendable (T, WorkspaceContext, BuildRequest, BuildRequestContext, BuildDescription, ConfiguredTarget, ElapsedTimer) -> any SWBProtocol.Message) async throws -> VoidResponse {
        let elapsedTimer = ElapsedTimer()

        // FIXME: Move this to use ActiveBuild.
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else { throw MsgParserError.missingWorkspaceContext }
        let buildRequest = try BuildRequest(from: message.request, workspace: workspaceContext.workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        // FIXME: We should use this delegate to report status messages about when an indexing request forced us to create a new build description, something which is known to be a source of serious performance issues: <rdar://problem/31633726> Still a lot of build description churn
        let operation = IndexingOperation(workspace: workspaceContext.workspace)

        // Create the request object to track our reply.
        let request = Request(service: request.service, channel: message.responseChannel, name: "indexing_info")

        session.withInfoOperation(operation: operation, buildRequest: buildRequest, requestForReply: request, lock: serializationQueue) {
            /// Returns a build description and found configured targets or a failure message.
            /// It guarantees to return at least one configured target if successful.
            func getBuildDescriptionAndTargets() async -> ResultOrErrorMessage<(BuildDescription, [ConfiguredTarget])> {
                if let buildDescriptionID = buildRequest.buildDescriptionID {
                    let result = await getIndexBuildDescriptionFromID(buildDescriptionID: buildDescriptionID, request: request, session: session, buildRequest: buildRequest, buildRequestContext: buildRequestContext, workspaceContext: workspaceContext, constructionDelegate: operation)
                    switch result {
                    case .success(let buildDescription):
                        let foundTargets = buildDescription.allConfiguredTargets.filter { $0.target.guid == message.targetID }
                        guard !foundTargets.isEmpty else {
                            return .failed(ErrorResponse("could not find target with GUID: '\(message.targetID)' in build description '\(buildDescriptionID)'"))
                        }
                        return .success((buildDescription, foundTargets))
                    case .failed(let msg):
                        return .failed(msg)
                    }

                } else {
                    // FIXME: We have temporarily disabled going through the planning operation, since it was causing significant churn: <rdar://problem/31772753> ProvisioningInputs are changing substantially for the same request
                    let buildGraph = await TargetBuildGraph(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: operation)
                    if operation.hadErrors {
                        return .failed(ErrorResponse("unable to get target build graph"))
                    }
                    let planRequest = BuildPlanRequest(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, buildGraph: buildGraph, provisioningInputs: [:])

                    // Get the complete build description.
                    let clientDelegate = ClientExchangeDelegate(request: request, session: session)
                    let buildDescription: BuildDescription
                    do {
                        if let retrievedBuildDescription = try await session.buildDescriptionManager.getBuildDescription(planRequest, clientDelegate: clientDelegate, constructionDelegate: operation) {
                            buildDescription = retrievedBuildDescription
                        } else {
                            // If we don't receive a build description it means we were cancelled.
                            return .failed(VoidResponse())
                        }
                    } catch {
                        return .failed(ErrorResponse("unable to get build description: \(error)"))
                    }

                    let foundTargets = planRequest.buildGraph.allTargets.filter { $0.target.guid == message.targetID }
                    guard !foundTargets.isEmpty else {
                        return .failed(ErrorResponse("could not find target with GUID: '\(message.targetID)' among: \(planRequest.buildGraph.allTargets.map { "'\($0.target.guid)'" }.sorted().joined(separator: ", "))"))
                    }
                    return .success((buildDescription, foundTargets))
                }
            }

            let buildDescription: BuildDescription
            let foundTargets: [ConfiguredTarget]
            switch await getBuildDescriptionAndTargets() {
            case .success((let bd, let targs)):
                buildDescription = bd
                foundTargets = targs
            case .failed(let msg):
                return msg
            }

            precondition(!foundTargets.isEmpty)

            // If there are multiple candidates choose the most appropriate.
            let target = foundTargets.one(by: {
                buildRequestContext.selectConfiguredTargetForIndex($0, $1, hasEnabledIndexBuildArena: buildRequest.enableIndexBuildArena, runDestination: buildRequest.parameters.activeRunDestination)
            })!

            return transformResponse(message, workspaceContext, buildRequest, buildRequestContext, buildDescription, target, elapsedTimer)
        }

        return VoidResponse()
    }
}

/// A message handler for requests about documentation info.
///
/// For a description of how this feature works, see the `SWBBuildServiceSession.generateDocumentationInfo` documentation.
private struct GetDocumentationInfoMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: DocumentationInfoRequest) throws -> VoidResponse {
        // FIXME: Move this to use ActiveBuild.
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else { throw MsgParserError.missingWorkspaceContext }
        let buildRequest = try BuildRequest(from: message.request, workspace: workspaceContext.workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        // Create the request object to track our reply.
        let requestForReply = Request(service: request.service, channel: message.responseChannel, name: "documentation_info")
        let clientDelegate = ClientExchangeDelegate(request: requestForReply, session: session)

        // FIXME: We should use this delegate to report status messages about when a documentation info request forced us to create a new build description, something which is known to be a source of serious performance issues: <rdar://problem/31633726> Still a lot of build description churn
        let operation = DocumentationOperation(clientDelegate: clientDelegate, workspace: workspaceContext.workspace)

        session.withInfoOperation(operation: operation, buildRequest: buildRequest, requestForReply: requestForReply, lock: Self.serializationQueue) {
            do {
                let output = try await session.buildDescriptionManager.generateDocumentationInfo(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: operation, input: TaskGenerateDocumentationInfoInput())
                return DocumentationInfoResponse(
                    output: output.map { taskOutput in
                        DocumentationInfoMessagePayload(outputPath: taskOutput.outputPath, targetIdentifier: taskOutput.targetIdentifier)
                    }
                )
            } catch {
                return ErrorResponse("could not generate documentation info: \(error)")
            }
        }

        return VoidResponse()
    }
}

private final class DocumentationOperation: InfoOperation, DocumentationInfoDelegate {
    private let _diagnosticsEngine = DiagnosticsEngine()

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    var diagnostics: [ConfiguredTarget? : [Diagnostic]] {
        [nil: _diagnosticsEngine.diagnostics]
    }

    let clientDelegate: any ClientDelegate

    package func updateProgress(statusMessage: String, showInLog: Bool) { }

    package func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID { .init(rawValue: -1) }
    package func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) { }
    package func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) { }
    package func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) { }

    package func buildDescriptionCreated(_ buildDescriptionID: BuildDescriptionID) { }

    package init(clientDelegate: any ClientDelegate, workspace: SWBCore.Workspace) {
        self.clientDelegate = clientDelegate
        super.init(workspace: workspace)
    }

    // We don't care about the individual diagnostics here, only if there was at least one error.
    package private(set) var hadErrors = false
    package func emit(_ diagnostic: Diagnostic) {
        if diagnostic.behavior == .error {
            hadErrors = true
        }
    }
}

/// An InfoOperation for localization information.
private final class LocalizationOperation: InfoOperation, LocalizationInfoDelegate {
    private let _diagnosticsEngine = DiagnosticsEngine()

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    var diagnostics: [ConfiguredTarget? : [Diagnostic]] {
        [nil: _diagnosticsEngine.diagnostics]
    }

    let clientDelegate: any ClientDelegate

    // We don't care about most of these messages.

    package func updateProgress(statusMessage: String, showInLog: Bool) { }

    package func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID { .init(rawValue: -1) }
    package func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) { }
    package func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) { }
    package func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) { }

    package func buildDescriptionCreated(_ buildDescriptionID: BuildDescriptionID) { }

    package init(clientDelegate: any ClientDelegate, workspace: SWBCore.Workspace) {
        self.clientDelegate = clientDelegate
        super.init(workspace: workspace)
    }

    // We don't care about the individual diagnostics here, only if there was at least one error.
    package private(set) var hadErrors = false
    package func emit(_ diagnostic: Diagnostic) {
        if diagnostic.behavior == .error {
            hadErrors = true
        }
    }
}

/// A message handler for requests about localization info.
private struct GetLocalizationInfoMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: LocalizationInfoRequest) throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else { throw MsgParserError.missingWorkspaceContext }
        let buildRequest = try BuildRequest(from: message.request, workspace: workspaceContext.workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        // Create the request object to track our reply.
        let requestForReply = Request(service: request.service, channel: message.responseChannel, name: "localization_info")
        let clientDelegate = ClientExchangeDelegate(request: requestForReply, session: session)

        let operation = LocalizationOperation(clientDelegate: clientDelegate, workspace: workspaceContext.workspace)

        session.withInfoOperation(operation: operation, buildRequest: buildRequest, requestForReply: requestForReply, lock: Self.serializationQueue) {
            do {
                let input = TaskGenerateLocalizationInfoInput(targetIdentifiers: message.targetIdentifiers)
                let output = try await session.buildDescriptionManager.generateLocalizationInfo(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: operation, input: input)

                let response = LocalizationInfoResponse(targetInfos: output.map({ infoOutput in
                    var stringsdataPaths = [LocalizationInfoBuildPortion: Set<Path>]()
                    for (buildPortion, paths) in infoOutput.producedStringsdataPaths {
                        stringsdataPaths[LocalizationInfoBuildPortion(effectivePlatformName: buildPortion.effectivePlatformName, variant: buildPortion.variant, architecture: buildPortion.architecture)] = paths
                    }
                    return LocalizationInfoMessagePayload(targetIdentifier: infoOutput.targetIdentifier, compilableXCStringsPaths: infoOutput.compilableXCStringsPaths, producedStringsdataPaths: stringsdataPaths)
                }))
                return response
            } catch {
                return ErrorResponse("could not generate localization info: \(error)")
            }
        }

        return VoidResponse()
    }
}

/// Provides a list of target GUIDs that a build description covers. Providing a build description ID is a requirement.
///
/// Note that the order of the list is non-deterministic.
private struct BuildDescriptionTargetInfoMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: BuildDescriptionTargetInfoRequest) throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else { throw MsgParserError.missingWorkspaceContext }
        let buildRequest = try BuildRequest(from: message.request, workspace: workspaceContext.workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        guard let buildDescriptionID = buildRequest.buildDescriptionID else {
            throw StubError.error("missing build description ID")
        }

        let operation = IndexingOperation(workspace: workspaceContext.workspace)

        // Create the request object to track our reply.
        let request = Request(service: request.service, channel: message.responseChannel, name: "build_description_target_info")

        session.withInfoOperation(operation: operation, buildRequest: buildRequest, requestForReply: request, lock: Self.serializationQueue) {
            let result = await getIndexBuildDescriptionFromID(buildDescriptionID: buildDescriptionID, request: request, session: session, buildRequest: buildRequest, buildRequestContext: buildRequestContext, workspaceContext: workspaceContext, constructionDelegate: operation)
            switch result {
            case .success(let buildDescription):
                // Note that `buildDescription.allConfiguredTargets` are in non-deterministic order. We could order the result array but it is not important for the request, the client can order it if it needs to.
                let targets = buildDescription.allConfiguredTargets.reduce(into: Set<SWBCore.Target>()) { set, configuredTarget in
                    set.insert(configuredTarget.target)
                }
                return StringListResponse(targets.map{$0.guid})
            case .failed(let msg):
                return msg
            }
        }

        return VoidResponse()
    }
}

private final class PreviewingOperation: InfoOperation, PreviewInfoDelegate {
    private let _diagnosticsEngine = DiagnosticsEngine()

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    var diagnostics: [ConfiguredTarget? : [Diagnostic]] {
        [nil: _diagnosticsEngine.diagnostics]
    }

    let clientDelegate: any ClientDelegate

    package private(set) var errorDiagnostics: [Diagnostic] = []

    package var hadErrors: Bool { !errorDiagnostics.isEmpty }

    package func updateProgress(statusMessage: String, showInLog: Bool) { }

    package func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID { .init(rawValue: -1) }
    package func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) { }
    package func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) { }
    package func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) { }

    package func buildDescriptionCreated(_ buildDescriptionID: BuildDescriptionID) { }

    package init(clientDelegate: any ClientDelegate, workspace: SWBCore.Workspace) {
        self.clientDelegate = clientDelegate
        super.init(workspace: workspace)
    }

    package func emit(_ diagnostic: Diagnostic) {
        if diagnostic.behavior == .error {
            errorDiagnostics.append(diagnostic)
        }
    }
}

protocol PreviewRequest: SessionChannelBuildMessage {
    var targetIDs: [String] { get }
    var generatePreviewInfoInput: TaskGeneratePreviewInfoInput { get }
}

extension PreviewInfoRequest: PreviewRequest {
    var generatePreviewInfoInput: TaskGeneratePreviewInfoInput {
        .thunkInfo(sourceFile: sourceFile, thunkVariantSuffix: thunkVariantSuffix)
    }
}

extension PreviewTargetDependencyInfoRequest: PreviewRequest {
    var generatePreviewInfoInput: TaskGeneratePreviewInfoInput {
        .targetDependencyInfo
    }
}

private struct GetPreviewInfoMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: PreviewInfoRequest) throws -> VoidResponse {
        try handlePreviewMessage(request: request, message: message, serializationQueue: Self.serializationQueue)
    }
}

private struct GetPreviewTargetDependencyInfoMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: PreviewTargetDependencyInfoRequest) throws -> VoidResponse {
        try handlePreviewMessage(request: request, message: message, serializationQueue: Self.serializationQueue)
    }
}

extension MessageHandler {
    func handlePreviewMessage(request: Request, message: some PreviewRequest, serializationQueue: ActorLock) throws -> VoidResponse {
        // FIXME: Move this to use ActiveBuild.
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else { throw MsgParserError.missingWorkspaceContext }
        let buildRequest = try BuildRequest(from: message.request, workspace: workspaceContext.workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        // Create the request object to track our reply.
        let requestForReply = Request(service: request.service, channel: message.responseChannel, name: "preview_info")
        let clientDelegate = ClientExchangeDelegate(request: requestForReply, session: session)

        // FIXME: We should use this delegate to report status messages about when an indexing request forced us to create a new build description, something which is known to be a source of serious performance issues: <rdar://problem/31633726> Still a lot of build description churn
        let operation = PreviewingOperation(clientDelegate: clientDelegate, workspace: workspaceContext.workspace)

        session.withInfoOperation(operation: operation, buildRequest: buildRequest, requestForReply: requestForReply, lock: serializationQueue) {
            do {
                var responses: [PreviewInfoMessagePayload] = []

                let output = try await session.buildDescriptionManager.generatePreviewInfo(
                    workspaceContext: workspaceContext,
                    buildRequest: buildRequest,
                    buildRequestContext: buildRequestContext,
                    delegate: operation,
                    targetIDs: message.targetIDs,
                    input: message.generatePreviewInfoInput
                )
                responses.append(contentsOf: output.map{ $0.asMessagePayload() })

                return PreviewInfoResponse(
                    targetIDs: message.targetIDs,
                    output: responses
                )
            } catch {
                if operation.hadErrors {
                    let errorStrings = operation.errorDiagnostics.map{$0.formatLocalizedDescription(.debug)}
                    return ErrorResponse("could not generate preview info: \(error)\ndiagnostics:\n\(errorStrings.joined(separator: "\n"))")
                } else {
                    return ErrorResponse("could not generate preview info: \(error)")
                }
            }
        }

        return VoidResponse()
    }
}

private extension PreviewInfoContext {
    func asMessagePayload() -> SWBProtocol.PreviewInfoContext {
        .init(sdkRoot: sdkRoot, sdkVariant: sdkVariant, buildVariant: buildVariant, architecture: architecture, pifGUID: pifGUID)
    }
}

private extension PreviewInfoOutput {
    func asMessagePayload() -> PreviewInfoMessagePayload {
        let kind: PreviewInfoMessagePayload.Kind
        switch info {
        case let .thunkInfo(info):
            kind = .thunkInfo(PreviewInfoThunkInfo(compileCommandLine: info.compileCommandLine, linkCommandLine: info.linkCommandLine, thunkSourceFile: info.thunkSourceFile, thunkObjectFile: info.thunkObjectFile, thunkLibrary: info.thunkLibrary))
        case let .targetDependencyInfo(info):
            kind = .targetDependencyInfo(
                PreviewInfoTargetDependencyInfo(
                    objectFileInputMap: info.objectFileInputMap,
                    linkCommandLine: info.linkCommandLine,
                    linkerWorkingDirectory: info.linkerWorkingDirectory,
                    swiftEnableOpaqueTypeErasure: info.swiftEnableOpaqueTypeErasure,
                    swiftUseIntegratedDriver: info.swiftUseIntegratedDriver,
                    enableJITPreviews: info.enableJITPreviews,
                    enableDebugDylib: info.enableDebugDylib,
                    enableAddressSanitizer: info.enableAddressSanitizer,
                    enableThreadSanitizer: info.enableThreadSanitizer,
                    enableUndefinedBehaviorSanitizer: info.enableUndefinedBehaviorSanitizer
                )
            )
        }
        return PreviewInfoMessagePayload(context: context.asMessagePayload(), kind: kind)
    }
}

private final class ProjectDescriptorOperation: InfoOperation, ProjectDescriptorDelegate {
    let clientDelegate: any ClientDelegate

    package init(clientDelegate: any ClientDelegate, workspace: SWBCore.Workspace) {
        self.clientDelegate = clientDelegate
        super.init(workspace: workspace)
    }
}

private struct DescribeSchemesMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: DescribeSchemesRequest) throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else { throw MsgParserError.missingWorkspaceContext }
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        // Create the request object to track our reply.
        let requestForReply = Request(service: request.service, channel: message.responseChannel, name: "describe_schemes")
        let clientDelegate = ClientExchangeDelegate(request: requestForReply, session: session)

        session.withInfoOperation(operation: ProjectDescriptorOperation(clientDelegate: clientDelegate, workspace: workspaceContext.workspace), qos: UserDefaults.defaultRequestQoS, requestForReply: requestForReply, lock: Self.serializationQueue) {
            DescribeSchemesResponse(schemes: ProjectPlanner(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext).describeSchemes(input: message.input))
        }

        return VoidResponse()
    }
}

private struct DescribeProductsMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: DescribeProductsRequest) throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else { throw MsgParserError.missingWorkspaceContext }
        guard let platform = workspaceContext.core.platformRegistry.lookup(name: message.platformName) else {
            throw StubError.error("Couldn't find platform \(message.platformName)")
        }
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        // Create the request object to track our reply.
        let requestForReply = Request(service: request.service, channel: message.responseChannel, name: "describe_products")
        let clientDelegate = ClientExchangeDelegate(request: requestForReply, session: session)

        session.withInfoOperation(operation: ProjectDescriptorOperation(clientDelegate: clientDelegate, workspace: workspaceContext.workspace), qos: UserDefaults.defaultRequestQoS, requestForReply: requestForReply, lock: Self.serializationQueue) {
            let output = ProjectPlanner(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext).describeProducts(input: message.input, platform: platform)
            return DescribeProductsResponse(products: output)
        }

        return VoidResponse()
    }
}

private struct DescribeArchivableProductsMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: DescribeArchivableProductsRequest) throws -> VoidResponse {
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else { throw MsgParserError.missingWorkspaceContext }
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

        // Create the request object to track our reply.
        let requestForReply = Request(service: request.service, channel: message.responseChannel, name: "describe_archivable_products")
        let clientDelegate = ClientExchangeDelegate(request: requestForReply, session: session)

        session.withInfoOperation(operation: ProjectDescriptorOperation(clientDelegate: clientDelegate, workspace: workspaceContext.workspace), qos: UserDefaults.defaultRequestQoS, requestForReply: requestForReply, lock: Self.serializationQueue) {
            DescribeArchivableProductsResponse(products: ProjectPlanner(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext).describeArchivableProducts(input: message.input))
        }

        return VoidResponse()
    }
}

/// Handler for a message from the client with the provisioning task inputs for a configured target.
private struct ProvisioningTaskInputsMsg: MessageHandler {
    func handle(request: Request, message: ProvisioningTaskInputsResponse) throws -> VoidResponse {
        // We get the planning operation from the session.
        let session = try request.session(for: message)
        guard let planningOperation = session.planningOperation(for: message.planningOperationHandle) else {
            throw MsgParserError.missingPlanningOperation
        }

        // Pass the response to the planning operation so it can create the final provisioning inputs object.
        planningOperation.receiveProvisioningTaskInputs(message, message.configuredTargetHandle)

        return VoidResponse()
    }
}

private struct ClientExchangeResponseMsg<MessageType: ClientExchangeMessage & RequestMessage>: MessageHandler where MessageType.ResponseMessage == BoolResponse {
    func handle(request: Request, message: MessageType) throws -> BoolResponse {
        // Get the client exchange from the session.
        let session = try request.session(for: message)
        guard let exchange = session.clientExchange(for: message.exchangeHandle) as? SynchronousClientExchange<MessageType> else {
            throw MsgParserError.missingClientExchange
        }

        // Have the client exchange handle the response.
        let success = exchange.handle(response: message)

        return BoolResponse(success)
    }
}

private struct DeveloperPathHandler: MessageHandler {
    func handle(request: Request, message: DeveloperPathRequest) throws -> StringResponse {
        let session = try request.session(for: message)
        return StringResponse(session.core.developerPath.path.str)
    }
}


final package class BuildDependencyInfoOperation: InfoOperation, TargetDependencyResolverDelegate {
    private let _diagnosticsEngine = DiagnosticsEngine()

    package func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(_diagnosticsEngine)
    }

    var diagnostics: [ConfiguredTarget? : [Diagnostic]] {
        [nil: _diagnosticsEngine.diagnostics]
    }

    package func updateProgress(statusMessage: String, showInLog: Bool) { }

    // We don't care about the individual diagnostics here, only if there was at least one error.
    package private(set) var hadErrors = false
    package func emit(_ diagnostic: Diagnostic) {
        if diagnostic.behavior == .error {
            hadErrors = true
        }
    }
}

/// Get the build dependency info for the build request and emit it to the given file.
///
/// Presently this involves getting the target build phase for the request, and then for each target extracting configuration info as well as relevant inputs and outputs that target declares.
///
/// In the future this could perform a full task construction and examine the individual tasks to get a more complete set of information, but that approach is hypothetical at this time.
private struct DumpBuildDependencyInfoMsg: MessageHandler {
    fileprivate static let serializationQueue = ActorLock()

    func handle(request: Request, message: DumpBuildDependencyInfoRequest) async throws -> VoidResponse {
        // FIXME: Move this to use ActiveBuild.
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let buildRequest = try BuildRequest(from: message.request, workspace: workspaceContext.workspace)
        let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
        let operation = BuildDependencyInfoOperation(workspace: workspaceContext.workspace)

        let request = Request(service: request.service, channel: message.responseChannel, name: "build_dependency_info")
        session.withInfoOperation(operation: operation, buildRequest: buildRequest, requestForReply: request, lock: Self.serializationQueue) {
            // Get the build dependency info.
            let buildDependencyInfo: BuildDependencyInfo
            do {
                buildDependencyInfo = try await BuildDependencyInfo(workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, operation: operation)
            }
            catch {
                return ErrorResponse(error.localizedDescription)
            }

            // Validate the output path.
            let outputPath = Path(message.outputPath)
            guard outputPath.isAbsolute else {
                return ErrorResponse("Invalid output path: \(outputPath.str)")
            }

            // Write the info to the path on disk as JSON.
            let jsonData: Data
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                jsonData = try encoder.encode(buildDependencyInfo)
            }
            catch {
                return ErrorResponse("Unable to serialize build dependency info: \(error.localizedDescription)")
            }
            do {
                try localFS.createDirectory(outputPath.dirname, recursive: true)
                try localFS.write(outputPath, contents: ByteString(jsonData))
            }
            catch {
                return ErrorResponse("Unable to write build dependency info: \(error.localizedDescription)")
            }

            return VoidResponse()
        }

        return VoidResponse()
    }
}


// MARK: Evaluating macros


/// Returns a `Settings` object for a `MacroEvaluationRequestContext` (creating it if necessary) for a `MacroEvaluationRequestLevel` and `BuildParameters`.
private func getSettings(for session: Session, workspaceContext: WorkspaceContext, level: MacroEvaluationRequestLevel, buildParameters: BuildParameters, purpose: SettingsPurpose) throws -> Settings {
    let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)
    switch level {
    case .defaults:
        return buildRequestContext.getCachedSettings(buildParameters)
    case .project(let guid):
        guard let project = workspaceContext.workspace.project(for: guid) else {
            throw MsgParserError.missingProject(guid: guid)
        }
        return buildRequestContext.getCachedSettings(buildParameters, project: project)
    case .target(let guid):
        guard let target = workspaceContext.workspace.target(for: guid) else {
            throw MsgParserError.missingTarget(guid: guid)
        }
        return buildRequestContext.getCachedSettings(buildParameters, target: target)
    }
}

/// Returns a `Settings` object for a `MacroEvaluationRequestContext`, either looking it up using a handle, or getting one (creating it if necessary) for a `MacroEvaluationRequestLevel` and `BuildParameters`.
private func getSettings(for session: Session, workspaceContext: WorkspaceContext, requestContext: MacroEvaluationRequestContext, purpose: SettingsPurpose) throws -> Settings {
    switch requestContext {
    case .settingsHandle(let string):
        // We have a Settings handle because this request came from a scope.
        return try session.settings(for: string)
    case .components(let level, let buildParameters):
        // We were passed components to use to look up the Settings.
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let buildParameters = try BuildParameters(from: buildParameters)
        return try getSettings(for: session, workspaceContext: workspaceContext, level: level, buildParameters: buildParameters, purpose: purpose)
    }
}

private struct MacroEvaluationMsg: MessageHandler {
    func handle(request: Request, message: MacroEvaluationRequest) async throws -> MacroEvaluationResponse {
        // We get the Settings to use for evaluation from the session.
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let settings = try getSettings(for: session, workspaceContext: workspaceContext, requestContext: message.context, purpose: .build)

        // Create the lookup block for evaluation.
        let lookup: ((MacroDeclaration) -> MacroExpression?)?
        if let overrides = message.overrides {
            // For each key-value paid in the overrides dictionary, we need to look up the MacroDeclaration for the key, and parse the value as a MacroExpression.
            // FIXME: I'm not sure what sort of error handling we should have here: If we can't find a declaration for a key, should we fail the lookup, or just ignore it?  (Presently we ignore it.)  If we can't parse a value, should we fail the lookup, or just ignore it?  (Presently we ignore it.)
            let lookupOverrides: [MacroDeclaration: MacroExpression] = {
                var result = [MacroDeclaration: MacroExpression]()
                for (key, value) in overrides {
                    if let macroDefn = settings.userNamespace.lookupMacroDeclaration(key) {
                        let parsedExpr = settings.userNamespace.parseStringList(value)
                        result[macroDefn] = parsedExpr
                    }
                }
                return result
            }()
            lookup = lookupOverrides.count > 0 ? { macro in
                return lookupOverrides[macro]
            } : nil
        }
        else {
            lookup = nil
        }

        // Based on the contents of the request, perform the lookup and return the appropriate result.
        let scope = settings.globalScope
        switch message.request {
        case .macro(let macroName):
            // Look up the macro name.
            guard let macroDefn = settings.userNamespace.lookupMacroDeclaration(macroName) else {
                return MacroEvaluationResponse(result: .error("no macro definition '\(macroName)'"))
            }
            // Evaluate the macro as the type we were asked for.
            switch message.resultType {
            case .string:
                let result: String = scope.evaluateAsString(macroDefn, lookup: lookup)
                return MacroEvaluationResponse(result: .string(result))
            case .stringList:
                if let macroDefn = macroDefn as? StringListMacroDeclaration {
                    let result: [String] = scope.evaluate(macroDefn, lookup: lookup)
                    return MacroEvaluationResponse(result: .stringList(result))
                } else if let macroDefn = macroDefn as? PathListMacroDeclaration {
                    let result: [String] = scope.evaluate(macroDefn, lookup: lookup)
                    return MacroEvaluationResponse(result: .stringList(result))
                }
                else {
                    // This is not a macro string list definition, so evaluate it as a string and return it as a single-element array.
                    let result: String = scope.evaluateAsString(macroDefn, lookup: lookup)
                    return MacroEvaluationResponse(result: .stringList([result]))
                }
            }
        case .stringExpression(let expr):
            // Parse and evaluate the expression as the type we were asked for.
            switch message.resultType {
            case .string:
                let parsedExpr = settings.userNamespace.parseString(expr)
                let result: String = scope.evaluate(parsedExpr, lookup: lookup)
                return MacroEvaluationResponse(result: .string(result))
            case .stringList:
                let parsedExpr = settings.userNamespace.parseStringList(expr)
                let result: [String] = scope.evaluate(parsedExpr, lookup: lookup)
                return MacroEvaluationResponse(result: .stringList(result))
            }
        case .stringListExpression(let expr):
            // Parse and evaluate the expression as the type we were asked for.
            switch message.resultType {
            case .string:
                return MacroEvaluationResponse(result: .error("cannot evaluate a string list as a string"))
            case .stringList:
                let parsedExpr = settings.userNamespace.parseStringList(expr)
                let result: [String] = scope.evaluate(parsedExpr, lookup: lookup)
                return MacroEvaluationResponse(result: .stringList(result))
            }

        case .stringExpressionArray(let exprArray):
            if message.resultType != .stringList {
                return MacroEvaluationResponse(result: .error("cannot support resultType '\(message.resultType)' for string array"))
            }
            let result: [String] = exprArray.map { expr in
                let parsedExpr = settings.userNamespace.parseString(expr)
                return scope.evaluate(parsedExpr, lookup: lookup)
            }
            return MacroEvaluationResponse(result: .stringList(result))
        }
    }
}

/// Handle a request for all macros and values to export from a `Settings` object.
private struct AllExportedMacrosAndValuesMsg: MessageHandler {
    func handle(request: Request, message: AllExportedMacrosAndValuesRequest) async throws -> AllExportedMacrosAndValuesResponse {
        // We get the Settings to use from the session.
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let settings = try getSettings(for: session, workspaceContext: workspaceContext, requestContext: message.context, purpose: .build)

        // Get the list of setting names and evaluated values.  We use the same algorithm as is used to export settings to shell script build phases.
        let exportedMacrosAndValues = computeScriptEnvironment(.shellScriptPhase, scope: settings.globalScope, settings: settings, workspaceContext: workspaceContext)

        return AllExportedMacrosAndValuesResponse(result: exportedMacrosAndValues)
    }
}

/// Handle a request for information for the build settings editor..
private struct BuildSettingsEditorInfoMsg: MessageHandler {
    func handle(request: Request, message: BuildSettingsEditorInfoRequest) async throws -> BuildSettingsEditorInfoResponse {
        // We get the Settings to use from the session.
        let session = try request.session(for: message)
        guard let workspaceContext = session.workspaceContext else {
            throw MsgParserError.missingWorkspaceContext
        }
        let settings = try getSettings(for: session, workspaceContext: workspaceContext, requestContext: message.context, purpose: .editor)

        // Get the info from the Settings object.
        let info = settings.infoForBuildSettingsEditor

        return BuildSettingsEditorInfoResponse(result: info)
    }
}


// MARK: Testing & Debugging Commands

private struct ExecuteCommandLineToolMsg: MessageHandler {
    private static let toolQueue = ActorLock()

    func handle(request: Request, message: ExecuteCommandLineToolRequest) throws -> VoidResponse {
        _Concurrency.Task<Void, Never> {
            await Self.toolQueue.withLock {
                guard let buildService = request.service as? BuildService else {
                    request.service.send(message.replyChannel, ErrorResponse("service object is not of type BuildService"))
                    request.service.send(message.replyChannel, BoolResponse(false))
                    return
                }
                let (core, diagnostics) = await buildService.sharedCore(developerPath: message.developerPath.map { .xcode($0) })
                guard let core else {
                    for diagnostic in diagnostics where diagnostic.behavior == .error {
                        request.service.send(message.replyChannel, ErrorResponse(diagnostic.formatLocalizedDescription(.messageOnly)))
                    }
                    request.service.send(message.replyChannel, BoolResponse(false))
                    return
                }
                let result = await executeInternalTool(core: core, commandLine: message.commandLine, workingDirectory: message.workingDirectory, stdoutHandler: {
                    request.service.send(message.replyChannel, StringResponse($0))
                }, stderrHandler: {
                    request.service.send(message.replyChannel, ErrorResponse($0))
                })
                request.service.send(message.replyChannel, BoolResponse(result))
            }
        }

        // FIXME: We shouldn't need to send a reply here, but this infrastructure is actually quite broken right now and leaks handlers if not.
        return VoidResponse()
    }
}

extension Request {
    var buildService: BuildService {
        return service as! BuildService
    }
}

// MARK: Utilities

private struct PingHandler: MessageHandler {
    func handle(request: Request, message: PingRequest) throws -> PingResponse {
        return PingResponse()
    }
}

private struct SetConfigItem: MessageHandler {
    func handle(request: Request, message: SetConfigItemRequest) throws -> VoidResponse {
        UserDefaults.set(key: message.key, value: message.value)
        return VoidResponse()
    }
}

private struct ClearAllCaches: MessageHandler {
    func handle(request: Request, message: ClearAllCachesRequest) throws -> VoidResponse {
        SWBUtil.clearAllHeavyCaches()
        return VoidResponse()
    }
}

// MARK: ServiceExtension Support

public struct ServiceSessionMessageHandlers: ServiceExtension {
    public init() {}

    public func register(_ service: Service) {
        service.registerMessageHandler(CreateSessionHandler.self)
        service.registerMessageHandler(ListSessionsHandler.self)
        service.registerMessageHandler(WaitForQuiescenceHandler.self)
        service.registerMessageHandler(DeleteSessionHandler.self)

        service.registerMessageHandler(SetSessionSystemInfoMsg.self)
        service.registerMessageHandler(SetSessionUserInfoMsg.self)
        service.registerMessageHandler(SetSessionUserPreferencesMsg.self)
        service.registerMessageHandler(DeveloperPathHandler.self)
    }
}

public struct ServicePIFMessageHandlers: ServiceExtension {
    public init() {}

    public func register(_ service: Service) {
        service.registerMessageHandler(SetSessionPIFMsg.self)
        service.registerMessageHandler(TransferSessionPIFMsg.self)
        service.registerMessageHandler(TransferSessionPIFObjectsMsg.self)
        service.registerMessageHandler(TransferSessionPIFObjectsLegacyMsg.self)
        service.registerMessageHandler(AuditSessionPIFMsg.self)
        service.registerMessageHandler(IncrementalPIFRetransmissionMsg.self)
    }
}

package struct WorkspaceModelMessageHandlers: ServiceExtension {
    package init() {}

    package func register(_ service: Service) {
        service.registerMessageHandler(SetSessionWorkspaceContainerPathMsg.self)
        service.registerMessageHandler(WorkspaceInfoMsg.self)
    }
}

public struct ActiveBuildBasicMessageHandlers: ServiceExtension {
    public init() {}

    public func register(_ service: Service) {
        service.registerMessageHandler(CreateBuildRequestMsg.self)
        service.registerMessageHandler(BuildStartRequestMsg.self)
        service.registerMessageHandler(BuildCancelRequestMsg.self)
    }
}

package struct ServiceMessageHandlers: ServiceExtension {
    package init() {}

    package func register(_ service: Service) {
        service.registerMessageHandler(PingHandler.self)
        service.registerMessageHandler(SetConfigItem.self)
        service.registerMessageHandler(ClearAllCaches.self)

        service.registerMessageHandler(GetPlatformsDumpMsg.self)
        service.registerMessageHandler(GetSDKsDumpMsg.self)
        service.registerMessageHandler(GetToolchainsDumpMsg.self)
        service.registerMessageHandler(GetSpecsDumpMsg.self)
        service.registerMessageHandler(GetStatisticsDumpMsg.self)
        service.registerMessageHandler(GetBuildSettingsDescriptionDumpMsg.self)
        service.registerMessageHandler(ExecuteCommandLineToolMsg.self)

        service.registerMessageHandler(CreateXCFrameworkHandler.self)

        service.registerMessageHandler(AppleSystemFrameworkNamesHandler.self)
        service.registerMessageHandler(ProductTypeSupportsMacCatalystHandler.self)

        service.registerMessageHandler(GetIndexingFileSettingsMsg.self)
        service.registerMessageHandler(GetIndexingHeaderInfoMsg.self)
        service.registerMessageHandler(BuildDescriptionTargetInfoMsg.self)
        service.registerMessageHandler(GetPreviewInfoMsg.self)
        service.registerMessageHandler(GetPreviewTargetDependencyInfoMsg.self)
        service.registerMessageHandler(GetDocumentationInfoMsg.self)
        service.registerMessageHandler(GetLocalizationInfoMsg.self)

        service.registerMessageHandler(DescribeSchemesMsg.self)
        service.registerMessageHandler(DescribeProductsMsg.self)
        service.registerMessageHandler(DescribeArchivableProductsMsg.self)
        service.registerMessageHandler(ComputeDependencyClosureMsg.self)
        service.registerMessageHandler(ComputeDependencyGraphMsg.self)
        service.registerMessageHandler(DumpBuildDependencyInfoMsg.self)
        
        service.registerMessageHandler(MacroEvaluationMsg.self)
        service.registerMessageHandler(AllExportedMacrosAndValuesMsg.self)
        service.registerMessageHandler(BuildSettingsEditorInfoMsg.self)

        service.registerMessageHandler(ProvisioningTaskInputsMsg.self)

        service.registerMessageHandler(ClientExchangeResponseMsg<ExternalToolExecutionResponse>.self)

        // TODO: Delete once all clients are no longer calling the public APIs which invoke this message
        service.registerMessageHandler(AvailableAppExtensionPointIdentifiersHandler.self)
        service.registerMessageHandler(MacCatalystUnavailableFrameworkNamesHandler.self)
    }
}

extension _Concurrency.TaskPriority {
    init?(buildRequestQoS qos: SWBQoS) {
        switch qos {
        case .userInteractive, .userInitiated:
            self = .userInitiated
        case .default:
            self = .medium
        case .utility:
            self = .utility
        case .background:
            self = .background
        default:
            return nil
        }
    }
}

extension Session {
    fileprivate func withInfoOperation(operation: InfoOperation, buildRequest: BuildRequest, requestForReply: Request, lock: ActorLock, _ work: @escaping @Sendable () async -> any Message) {
        withInfoOperation(operation: operation, qos: buildRequest.qos, requestForReply: requestForReply, lock: lock, work)
    }

    fileprivate func withInfoOperation(operation: InfoOperation, qos: SWBQoS, requestForReply: Request, lock: ActorLock, _ work: @escaping @Sendable () async -> any Message) {
        registerInfoOperation(operation)
        operation.addTask(_Concurrency.Task<Void, Never>(priority: .init(buildRequestQoS: qos)) {
            await lock.withLock {
                let message = await work()
                unregisterInfoOperation(operation)
                requestForReply.reply(message)
            }
        })
    }
}
