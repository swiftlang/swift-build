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

import SWBProtocol
import SWBUtil

public enum SwiftBuildServicePIFObjectType: Sendable {
    case workspace
    case project
    case target

    var name: String {
        switch self {
        case .workspace:
            return "workspace"
        case .project:
            return "project"
        case .target:
            return "target"
        }
    }
}

/// This class encapsulates a unique session connection to the inferior build service process.
///
/// The state for each individual session is separated, and generally a unique session is used for each separate workspace, project, etc. that a client may want to build
public final class SWBBuildServiceSession: Sendable {
    /// The service this session is connected to.
    internal let service: SWBBuildService

    /// The name of the session.
    public let name: String

    /// The unique ID that was provided by the service, to refer to the session.
    public let uid: String

    /// An opaque identifier representing the lifetime of the specific service connection instance with which this session was created.
    private let connectionUUID: Foundation.UUID

    /// An object that keeps track of build operations and macro evaluation scopes created by the session in order to ensure they are properly torn down when the session is closed.
    ///
    /// For macro evaluation scopes, the session will register each newly created scope with the tracker. If the client manually discards the scope, it will be removed from the tracker by the session. If the client does not manually discard their scopes, they will be cleaned up by the tracker when the session is closed.
    ///
    /// For build operations, the tracker implements a generic background operation queue. Closures are enqueued to a stream, and consumed and awaited on a background task. Closing the session awaits that background taskto ensure all closures are awaited before continuing with teardown.
    private actor SessionResourceTracker {
        private var awaitableBuildOperations: AsyncStreamController<SWBBuildOperation, Never>
        private let cancellableBuildOperationsHolder = CancellableBuildOperationsHolder()

        private actor CancellableBuildOperationsHolder {
            private var cancellableBuildOperations: [Foundation.UUID: SWBBuildOperation] = [:]

            func insert(_ operation: SWBBuildOperation) {
                cancellableBuildOperations[operation.buildUUID] = operation
            }

            func finalize(_ operation: SWBBuildOperation) {
                cancellableBuildOperations.removeValue(forKey: operation.buildUUID)
            }

            func cancelAll() {
                let operations = cancellableBuildOperations
                cancellableBuildOperations = [:]
                for (_, operation) in operations {
                    if operation.state != .cancelled {
                        operation.cancel()
                    }
                }
            }
        }

        init() {
            awaitableBuildOperations = AsyncStreamController { [cancellableBuildOperationsHolder] stream in
                for await operation in stream {
                    await operation.waitForCompletion()
                    await cancellableBuildOperationsHolder.finalize(operation)
                }
            }
        }

        func enqueue(_ operation: SWBBuildOperation) async {
            let queuedResult = awaitableBuildOperations.yield(operation)
            switch queuedResult {
            case .enqueued:
                // The enqueued operation is going to be awaited by our operationAwaiter: AsyncStreamController.
                await cancellableBuildOperationsHolder.insert(operation)
            case .terminated:
                // If we've already begun shutdown, await the operation immediately to prevent a potential race where a build operation could be started after session shutdown and not awaited. In that case starting the build operation will simply "block" (await) until the operation has completed.
                if operation.state != .cancelled {
                    operation.cancel()
                }
                await operation.waitForCompletion()
            case .dropped:
                assertionFailure("unreachable")
                fallthrough
            @unknown default:
                break
            }
        }

        func invalidateAll() async throws {
            awaitableBuildOperations.finish()
            await cancellableBuildOperationsHolder.cancelAll()
            await awaitableBuildOperations.wait()
        }
    }

    private let sessionResourceTracker = SessionResourceTracker()

    private let closed = LockedValue(false)

    init(name: String, uid: String, service: SWBBuildService) {
        // Check parameters.
        precondition(name != "")
        precondition(uid != "")

        self.service = service
        self.name = name
        self.uid = uid
        self.connectionUUID = service.connectionUUID
    }

    deinit {
        closed.withLock { closed in
            if !closed {
                #if os(Windows)
                // FIXME: This is getting hit sometimes in the test suite
                print("Expected SWBBuildServiceSession to be closed before deinit")
                #else
                assertionFailure("Expected SWBBuildServiceSession to be closed before deinit")
                #endif
            }
        }
    }

    /// Whether or not the underlying service subprocess is currently terminated or a previous termination has invalidated the session.
    public var terminated: Bool {
        return service.terminated || service.connectionUUID != connectionUUID
    }

    /// Wait for background I/O operations to finish (for testing).
    @_spi(Testing) public func waitForQuiescence() async throws {
        try await self.service.waitForQuiescence(sessionHandle: uid)
    }

    /// Close the session and release any associated resources.
    ///
    /// It is an error to allow the session to be deallocated without being closed.
    public func close() async throws {
        var errors: [any Error] = []
        do {
            try await sessionResourceTracker.invalidateAll()
        } catch {
            errors.append(error)
        }
        do {
            try await self.service.deleteSession(sessionHandle: uid)
        } catch {
            errors.append(error)
        }
        closed.withLock { $0 = true }
        for error in errors {
            throw error
        }
    }

    /// Add a build request, and return an object that can be used to observe and to control it.  The provided delegate will be queried for any additional inputs required during the build operation.
    /// - note: This method does not _start_ the build operation, which must subsequently be done by calling ``SWBBuildOperation/start()`` on the received build operation object.
    @_disfavoredOverload
    public func createBuildOperation(request: SWBBuildRequest, delegate: any SWBPlanningOperationDelegate) async throws -> SWBBuildOperation {
        try await createBuildOperation(request: request, delegate: delegate, onlyCreateBuildDescription: false)
    }

    @_disfavoredOverload
    public func createBuildOperationForBuildDescriptionOnly(request: SWBBuildRequest, delegate: any SWBPlanningOperationDelegate) async throws -> SWBBuildOperation {
        try await createBuildOperation(request: request, delegate: delegate, onlyCreateBuildDescription: true)
    }

    internal func trackBuildOperation(_ operation: SWBBuildOperation) async {
        await sessionResourceTracker.enqueue(operation)
    }

    private func createBuildOperation(request: SWBBuildRequest, delegate: any SWBPlanningOperationDelegate, onlyCreateBuildDescription: Bool) async throws -> SWBBuildOperation {
        // Allocate a new SWBBuildOperation object that we can return to the client to use for observing and controlling the build.  As we start getting replies from Swift Build, we will keep it informed, and it will in turn tell all of its observers what’s going on.
        return try await SWBBuildOperation(session: self, delegate: delegate, request: request, onlyCreateBuildDescription: onlyCreateBuildDescription)
    }

    public func generateIndexingFileSettings(for request: SWBBuildRequest, targetID: String, filePath: String?, outputPathOnly: Bool, delegate: any SWBIndexingDelegate) async throws -> SWBIndexingFileSettings {
        guard let msg: IndexingFileSettingsResponse = try await handleDelegateMessageOnChannel(makeMessage: { [uid] in IndexingFileSettingsRequest(sessionHandle: uid, responseChannel: $0, request: request.messagePayloadRepresentation, targetID: targetID, filePath: filePath, outputPathOnly: outputPathOnly) }, delegate: delegate) else {
            throw StubError.error("The indexing operation was cancelled.")
        }

        precondition(targetID == msg.targetID)

        let plist = try PropertyList.fromBytes(msg.data.bytes)
        guard let array = plist.arrayValue else {
            throw StubError.error("Expected an array value")
        }
        let dicts = try array.map { item -> [String: PropertyListItem] in
            guard let dict = item.dictValue else {
                throw StubError.error("Expected an dictionary value")
            }
            return dict
        }
        return try SWBIndexingFileSettings(sourceFileBuildInfos: dicts.map { try Dictionary($0) })
    }

    @_disfavoredOverload
    @available(*, deprecated, renamed: "generateIndexingFileSettings(for:targetID:filePath:outputPathOnly:delegate:)", message: "Use the overload returning SWBIndexingInfo")
    public func generateIndexingInfo(for request: SWBBuildRequest, targetID: String, filePath: String?, outputPathOnly: Bool, delegate: any SWBIndexingDelegate) async throws -> [[String: SWBPropertyListItem]] {
        try await generateIndexingFileSettings(for: request, targetID: targetID, filePath: filePath, outputPathOnly: outputPathOnly, delegate: delegate).sourceFileBuildInfos
    }

    public func generateIndexingHeaderInfo(for request: SWBBuildRequest, targetID: String, delegate: any SWBIndexingDelegate) async throws -> SWBIndexingHeaderInfo {
        guard let msg: IndexingHeaderInfoResponse = try await handleDelegateMessageOnChannel(makeMessage: { [uid] in IndexingHeaderInfoRequest(sessionHandle: uid, responseChannel: $0, request: request.messagePayloadRepresentation, targetID: targetID) }, delegate: delegate) else {
            throw StubError.error("The indexing operation was cancelled.")
        }

        precondition(targetID == msg.targetID)

        return try SWBIndexingHeaderInfo(
            productName: msg.productName,
            copiedPathMap: Dictionary(uniqueKeysWithValues: msg.copiedPathMap.map { (try AbsolutePath(validating: $0.key), try AbsolutePath(validating: $0.value)) }))
    }

    /// Generate information about the documentation that will be built for a given build request.
    ///
    /// This API is used to get a list of all the documentation that a build request will build, if any at all, and the location where that built documentation will be written.
    /// It's used by IDEDocumentation to keep track of all the built documentation in the current workspace, so that documentation can be displayed in the Doc Viewer when the workspace is open.
    ///
    /// The user facing aspect of this feature is that when a developer opens the Doc Viewer, they will see the all built documentation for all everything in that workspace. Since the Doc Viewer will
    /// only display documentation that has already been built, this API is called _after_ a build has completed, requesting the documentation information for the build operation configuration that
    /// just finished. Since this build operation configuration was just built, it will be cached and doesn't need to be recomputed.
    ///
    /// The information about what documentation will be built and where it will be written is attached to the documentation compiler task as a custom payload. If the planned build doesn't have any
    /// documentation tasks, then the response to the message will return an empty array.
    public func generateDocumentationInfo(for request: SWBBuildRequest, delegate: any SWBDocumentationDelegate) async throws -> SWBDocumentationInfo {
        guard let msg: DocumentationInfoResponse = try await handleDelegateMessageOnChannel(makeMessage: { [uid] in DocumentationInfoRequest(sessionHandle: uid, responseChannel: $0, request: request.messagePayloadRepresentation) }, delegate: delegate) else {
            throw StubError.error("The documentation info operation was cancelled.")
        }

        return SWBDocumentationInfo(builtDocumentationBundles: msg.output.map {
            SWBDocumentationBundleInfo(outputPath: $0.outputPath.normalize().str, targetIdentifier: $0.targetIdentifier)
        })
    }

    /// Generate and return information about the localizable content of a given build request.
    ///
    /// - Note: `buildRequest` must include the `buildDescriptionID` of a historical build.
    ///
    /// This API is used by the IDELocalization infrastructure to get an accurate picture of various things relevant to localization in a particular build, such as inputs, outputs, the target closure, etc.
    ///
    /// One primary use of this feature is determining which stringsdata files to consult when performing an XCStrings sync after a successful build.
    ///
    /// The info is provided by two mechanisms:
    /// 1. Output .stringsdata files anywhere in the generated task graph will be recognized.
    /// 2. Individual task specs get an opportunity to provide additional localization info.
    ///
    /// - Parameters:
    ///   - buildRequest: The build request to collect localization info for. `buildDescriptionID` must be set.
    ///   - targetIdentifiers: An optional filter of target GUIDs to return info for.
    ///   - delegate: An object that can perform delegate certain planning delegate tasks.
    public func generateLocalizationInfo(for buildRequest: SWBBuildRequest, targetIdentifiers: Set<String>? = nil, delegate: any SWBLocalizationDelegate) async throws -> SWBLocalizationInfo {
        guard let msg: LocalizationInfoResponse = try await handleDelegateMessageOnChannel(makeMessage: { [uid] in LocalizationInfoRequest(sessionHandle: uid, responseChannel: $0, request: buildRequest.messagePayloadRepresentation, targetIdentifiers: targetIdentifiers) }, delegate: delegate) else {
            throw StubError.error("The localization info operation was cancelled.")
        }

        // We got our localization info.
        var targetInfos = [String: SWBLocalizationTargetInfo]()
        for payload in msg.targetInfos {
            let xcstrings = payload.compilableXCStringsPaths.map { $0.normalize().str }
            var stringsdata = [SWBLocalizationBuildPortion: Set<String>]()
            for (buildPortion, paths) in payload.producedStringsdataPaths {
                stringsdata[SWBLocalizationBuildPortion(effectivePlatformName: buildPortion.effectivePlatformName, variant: buildPortion.variant, architecture: buildPortion.architecture)] = Set(paths.map({ $0.normalize().str }))
            }
            targetInfos[payload.targetIdentifier] = SWBLocalizationTargetInfo(compilableXCStringsPaths: Set(xcstrings), stringsdataPathsByBuildPortion: stringsdata)
        }

        return SWBLocalizationInfo(infoByTarget: targetInfos)
    }

    /// Provides a list of target GUIDs that a build description covers. Providing a build description ID is a requirement.
    ///
    /// Note that the order of the list is non-deterministic.
    public func generateBuildDescriptionTargetInfo(for request: SWBBuildRequest) async throws -> SWBBuildDescriptionTargetInfo {
        guard let msg: StringListResponse = try await handleDelegateMessageOnChannel(makeMessage: { [uid] in BuildDescriptionTargetInfoRequest(sessionHandle: uid, responseChannel: $0, request: request.messagePayloadRepresentation) }, delegate: nil) else {
            throw StubError.error("The build description target operation was cancelled.")
        }

        return SWBBuildDescriptionTargetInfo(targetGUIDs: msg.value)
    }

    public func dumpBuildDependencyInfo(for request: SWBBuildRequest, to outputPath: String) async throws {
        guard let _: VoidResponse = try await handleDelegateMessageOnChannel(makeMessage: { [uid] in DumpBuildDependencyInfoRequest(sessionHandle: uid, responseChannel: $0, request: request.messagePayloadRepresentation, outputPath: outputPath) }, delegate: nil) else {
            throw StubError.error("The build dependency info dump was cancelled.")
        }

        return
    }

    public func generatePreviewInfo(for request: SWBBuildRequest, targetID: String, sourceFile: String, thunkVariantSuffix: String, delegate: any SWBPreviewDelegate) async throws -> [SWBPreviewInfo] {
        guard let msg: PreviewInfoResponse = try await handleDelegateMessageOnChannel(makeMessage: { [uid] in PreviewInfoRequest(sessionHandle: uid, responseChannel: $0, request: request.messagePayloadRepresentation, targetID: targetID, sourceFile: Path(sourceFile), thunkVariantSuffix: thunkVariantSuffix) }, delegate: delegate) else {
            throw StubError.error("The preview info operation was cancelled.")
        }

        precondition([targetID] == msg.targetIDs)
        return try msg.output.map { try SWBPreviewInfo($0) }
    }

    @available(*, deprecated, renamed: "generatePreviewTargetDependencyInfo(for:targetIDs:delegate:)", message: "Use the method that takes multiple target IDs.")
    public func generatePreviewTargetDependencyInfo(
        for request: SWBBuildRequest,
        targetID: String,
        delegate: any SWBPreviewDelegate
    ) async throws -> [SWBPreviewTargetDependencyInfo] {
        try await generatePreviewTargetDependencyInfo(for: request, targetIDs: [targetID], delegate: delegate)
    }

    public func generatePreviewTargetDependencyInfo(
        for request: SWBBuildRequest,
        targetIDs: [String],
        delegate: any SWBPreviewDelegate
    ) async throws -> [SWBPreviewTargetDependencyInfo] {
        guard let msg: PreviewInfoResponse = try await handleDelegateMessageOnChannel(makeMessage: { [uid] in PreviewTargetDependencyInfoRequest(sessionHandle: uid, responseChannel: $0, request: request.messagePayloadRepresentation, targetIDs: targetIDs) }, delegate: delegate) else {
            throw StubError.error("The preview target dependency info operation was cancelled.")
        }

        precondition(targetIDs == msg.targetIDs)
        return try msg.output.map { try SWBPreviewTargetDependencyInfo($0) }
    }

    public func describeSchemes(input: [SWBSchemeInput]) async throws -> [SWBSchemeDescription] {
        let response: DescribeSchemesResponse = try await handleProductPlannerMessage(makeMessage: { DescribeSchemesRequest(sessionHandle: self.uid, responseChannel: $0, input: input.map(SchemeInput.init)) })
        return response.schemes.map(SWBSchemeDescription.init)
    }

    public func describeProducts(input: SWBActionInput, platformName: String) async throws -> [SWBProductDescription] {
        let response: DescribeProductsResponse = try await handleProductPlannerMessage(makeMessage: { DescribeProductsRequest(sessionHandle: self.uid, responseChannel: $0, input: .init(input), platformName: platformName) })
        return response.products.map(SWBProductDescription.init)
    }

    public func describeArchivableProducts(input: [SWBSchemeInput]) async throws -> [SWBProductTupleDescription] {
        let response: DescribeArchivableProductsResponse = try await handleProductPlannerMessage(makeMessage: { DescribeArchivableProductsRequest(sessionHandle: self.uid, responseChannel: $0, input: input.map(SchemeInput.init)) })
        return response.products.map(SWBProductTupleDescription.init)
    }

    public func computeDependencyClosure(targetGUIDs: [String], buildParameters: SWBBuildParameters, includeImplicitDependencies: Bool) async throws -> [String] {
        try await service.send(request: ComputeDependencyClosureRequest(sessionHandle: uid, targetGUIDs: targetGUIDs, buildParameters: buildParameters.messagePayloadRepresentation, includeImplicitDependencies: includeImplicitDependencies, dependencyScope: .workspace)).value
    }

    public func computeDependencyGraph(targetGUIDs: [SWBTargetGUID], buildParameters: SWBBuildParameters, includeImplicitDependencies: Bool) async throws -> [SWBTargetGUID: [SWBTargetGUID]] {
        var result: [SWBTargetGUID: [SWBTargetGUID]] = [:]
        for (key, value) in try await service.send(request: ComputeDependencyGraphRequest(sessionHandle: uid, targetGUIDs: targetGUIDs.map { TargetGUID(rawValue: $0.rawValue) }, buildParameters: buildParameters.messagePayloadRepresentation, includeImplicitDependencies: includeImplicitDependencies, dependencyScope: .workspace)).adjacencyList {
            result[SWBTargetGUID(rawValue: key.rawValue)] = value.map { SWBTargetGUID(rawValue: $0.rawValue) }
        }
        return result
    }

    public func computeDependencyClosure(targetGUIDs: [String], buildParameters: SWBBuildParameters, includeImplicitDependencies: Bool, dependencyScope: SWBDependencyScope) async throws -> [String] {
        try await service.send(request: ComputeDependencyClosureRequest(sessionHandle: uid, targetGUIDs: targetGUIDs, buildParameters: buildParameters.messagePayloadRepresentation, includeImplicitDependencies: includeImplicitDependencies, dependencyScope: dependencyScope.messagePayload)).value
    }

    public func computeDependencyGraph(targetGUIDs: [SWBTargetGUID], buildParameters: SWBBuildParameters, includeImplicitDependencies: Bool, dependencyScope: SWBDependencyScope) async throws -> [SWBTargetGUID: [SWBTargetGUID]] {
        var result: [SWBTargetGUID: [SWBTargetGUID]] = [:]
        for (key, value) in try await service.send(request: ComputeDependencyGraphRequest(sessionHandle: uid, targetGUIDs: targetGUIDs.map { TargetGUID(rawValue: $0.rawValue) }, buildParameters: buildParameters.messagePayloadRepresentation, includeImplicitDependencies: includeImplicitDependencies, dependencyScope: dependencyScope.messagePayload)).adjacencyList {
            result[SWBTargetGUID(rawValue: key.rawValue)] = value.map { SWBTargetGUID(rawValue: $0.rawValue) }
        }
        return result
    }


    // MARK: Macro evaluation


    // Helper methods to send a macro evaluation request and handle the response.

    /// Dispatch a macro evaluation request expecting a string response.
    private func sendMacroEvaluationStringRequest(_ session: SWBBuildServiceSession, _ request: MacroEvaluationRequest) async throws -> String {
        switch try await session.service.send(request: request).result {
        case .string(let value):
            return value
        case .stringList(let value):
            throw SWBMacroEvaluationError(message: "expected string but got string list '\(value)' for macro evaluation request: \(request.request)")
        case .error(let error):
            throw SWBMacroEvaluationError(message: error)
        }
    }

    /// Dispatch a macro evaluation request expecting a string list response.
    private func sendMacroEvaluationStringListRequest(_ session: SWBBuildServiceSession, _ request: MacroEvaluationRequest) async throws -> [String] {
        switch try await session.service.send(request: request).result {
        case .string(let value):
            throw SWBMacroEvaluationError(message: "expected string list but got string '\(value)' for macro evaluation request: \(request.request)")
        case .stringList(let value):
            return value
        case .error(let error):
            throw SWBMacroEvaluationError(message: error)
        }
    }


    // Public methods to perform macro evaluations for a level and build parameters.

    public func evaluateMacroAsString(_ macro: String, level: SWBMacroEvaluationLevel, buildParameters: SWBBuildParameters, overrides: [String : String]?) async throws -> String {
        let parameters = buildParameters.messagePayloadRepresentation
        let request = MacroEvaluationRequest(sessionHandle: uid, context: .components(level: level.toSWBRequest, buildParameters: parameters), request: .macro(macro), overrides: overrides, resultType: .string)
        return try await sendMacroEvaluationStringRequest(self, request)
    }

    public func evaluateMacroAsStringList(_ macro: String, level: SWBMacroEvaluationLevel, buildParameters: SWBBuildParameters, overrides: [String : String]?) async throws -> [String] {
        let parameters = buildParameters.messagePayloadRepresentation
        let request = MacroEvaluationRequest(sessionHandle: uid, context: .components(level: level.toSWBRequest, buildParameters: parameters), request: .macro(macro), overrides: overrides, resultType: .stringList)
        return try await sendMacroEvaluationStringListRequest(self, request)
    }

    public func evaluateMacroAsBoolean(_ macro: String, level: SWBMacroEvaluationLevel, buildParameters: SWBBuildParameters, overrides: [String : String]?) async throws -> Bool {
        let parameters = buildParameters.messagePayloadRepresentation
        let request = MacroEvaluationRequest(sessionHandle: uid, context: .components(level: level.toSWBRequest, buildParameters: parameters), request: .macro(macro), overrides: overrides, resultType: .string)
        return try await sendMacroEvaluationStringRequest(self, request) == "YES"
    }

    public func evaluateMacroExpressionAsString(_ expr: String, level: SWBMacroEvaluationLevel, buildParameters: SWBBuildParameters, overrides: [String : String]?) async throws -> String {
        let parameters = buildParameters.messagePayloadRepresentation
        let request = MacroEvaluationRequest(sessionHandle: uid, context: .components(level: level.toSWBRequest, buildParameters: parameters), request: .stringExpression(expr), overrides: overrides, resultType: .string)
        return try await sendMacroEvaluationStringRequest(self, request)
    }

    public func evaluateMacroExpressionAsStringList(_ expr: String, level: SWBMacroEvaluationLevel, buildParameters: SWBBuildParameters, overrides: [String : String]?) async throws -> [String] {
        let parameters = buildParameters.messagePayloadRepresentation
        let request = MacroEvaluationRequest(sessionHandle: uid, context: .components(level: level.toSWBRequest, buildParameters: parameters), request: .stringExpression(expr), overrides: overrides, resultType: .stringList)
        return try await sendMacroEvaluationStringListRequest(self, request)
    }

    public func evaluateMacroExpressionArrayAsStringList(_ expr: [String], level: SWBMacroEvaluationLevel, buildParameters: SWBBuildParameters, overrides: [String : String]?) async throws -> [String] {
        let parameters = buildParameters.messagePayloadRepresentation
        let request = MacroEvaluationRequest(sessionHandle: uid, context: .components(level: level.toSWBRequest, buildParameters: parameters), request: .stringExpressionArray(expr), overrides: overrides, resultType: .stringList)
        return try await sendMacroEvaluationStringListRequest(self, request)
    }


    // MARK: Other methods to get information about macros

    public func allExportedMacroNamesAndValues(level: SWBMacroEvaluationLevel, buildParameters: SWBBuildParameters) async throws -> [String : String] {
        let parameters = buildParameters.messagePayloadRepresentation
        return try await service.send(request: AllExportedMacrosAndValuesRequest(sessionHandle: uid, context: .components(level: level.toSWBRequest, buildParameters: parameters))).result
    }


    // MARK: Build settings editor support


    public func buildSettingsEditorInfo(level: SWBMacroEvaluationLevel, buildParameters: SWBBuildParameters) async throws -> SWBBuildSettingsEditorInfo {
        let parameters = buildParameters.messagePayloadRepresentation
        return SWBBuildSettingsEditorInfo(from: try await service.send(request: BuildSettingsEditorInfoRequest(sessionHandle: uid, context: .components(level: level.toSWBRequest, buildParameters: parameters))).result)
    }


    /// Loads the workspace at the specified container path.
    ///
    /// The container path may be:
    /// - An Xcode workspace (.xcworkspace)
    /// - An Xcode project (.xcodeproj)
    /// - Path to a directory containing a Package.swift file
    /// - A JSON-PIF document (.json or .pif)
    public func loadWorkspace(containerPath: String) async throws {
        _ = try await service.send(request: SetSessionWorkspaceContainerPathRequest(sessionHandle: uid, containerPath: containerPath))
    }

    /// Send a PIF property list.
    public func sendPIF(_ pif: SWBPropertyListItem) async throws {
        let pifContents = try pif.propertyListItem.asJSONFragment().bytes
        _ = try await service.send(request: SetSessionPIFRequest(sessionHandle: uid, pifContents: pifContents))
    }

    /// Send a PIF property list incrementally to the service.
    ///
    /// The service will call back to the client to look up the PIF data for each object that the service does not have and requires to be transferred, and this method will be called to send that object to the service.
    ///
    /// - parameter workspaceSignature: The signature of the workspace to send.
    /// - parameter auditPIF: if not nil, this should be a complete PIF which is sent to the service to compare against the PIF the service has received from us, the client.
    /// - parameter lookup: A closure for looking up additional objects to send (called on an unspecified thread).
    public func sendPIF(workspaceSignature: String, auditPIF: SWBPropertyListItem? = nil, lookupObject lookup: @Sendable @escaping (SwiftBuildServicePIFObjectType, String) async throws -> SWBPropertyListItem) async throws {
        var message: any IncrementalPIFMessage = TransferSessionPIFRequest(sessionHandle: self.uid, workspaceSignature: workspaceSignature)
        var hasSentAuditRequest = false

        while true {
            let asPIFResponse = try await service.send(request: message)

            // Check if the transfer is complete.
            if asPIFResponse.isComplete {
                return
            }

            if let auditPIF, !hasSentAuditRequest {
                // If we have an audit PIF and haven't sent it yet, do that first, before sending missing objects.
                // FIXME: The way this currently works, if the service thinks it already has a complete PIF but is wrong, then it will never call back to us to send the audit PIF. We should find a way to send it the audit PIF no matter what it thinks.
                let pifContents = try auditPIF.propertyListItem.asJSONFragment().bytes
                message = AuditSessionPIFRequest(sessionHandle: self.uid, pifContents: pifContents)
                hasSentAuditRequest = true
            } else {
                message = await constructIncrementalPIFReply(asPIFResponse, lookup)
            }
        }
    }

    /// Construct reply for incremental PIF transfer based on the PIF transfer session response.
    private func constructIncrementalPIFReply(_ pifResponse: TransferSessionPIFResponse, _ lookup: @Sendable @escaping (SwiftBuildServicePIFObjectType, String) async throws -> SWBPropertyListItem) async -> any IncrementalPIFMessage {
        do {
            return try await withThrowingTaskGroup(of: [UInt8].self) { group in
                for missingObject in pifResponse.missingObjects {
                    group.addTask {
                        let object = try await lookup(SwiftBuildServicePIFObjectType(missingObject.type), missingObject.signature)
                        return try object.propertyListItem.asJSONFragment().bytes
                    }
                }

                return try await TransferSessionPIFObjectsLegacyRequest(sessionHandle: self.uid, objects: group.reduce(into: [], { $0.append($1) }))
            }
        } catch {
            return IncrementalPIFLookupFailureRequest(sessionHandle: self.uid, diagnostic: "\(error)")
        }
    }

    // FIXME: Get stronger typing in the lookup method.
    //
    /// Transfer a workspace via PIF from the client, incrementally.
    ///
    /// This method will call back to the client to look up the PIF data for each object that the service does not have and requires to be transferred.
    ///
    /// - parameter workspaceSignature: The signature of the workspace to send.
    /// - parameter lookup: A closure for looking up additional objects to send (called on an unspecified thread).
    private func transfer(workspaceSignature: String, lookupObject lookup: @escaping (SwiftBuildServicePIFObjectType, String) -> any Serializable) async throws {
        var message: any IncrementalPIFMessage = TransferSessionPIFRequest(sessionHandle: self.uid, workspaceSignature: workspaceSignature)

        while true {
            let asPIFResponse = try await service.send(request: message)

            // Check if the transfer is complete.
            if asPIFResponse.isComplete {
                return
            }

            // Otherwise, send all of the missing objects.
            var additionalObjects: [TransferSessionPIFObjectsRequest.ObjectData] = []
            for missingObject in asPIFResponse.missingObjects {
                let object = lookup(SwiftBuildServicePIFObjectType(missingObject.type), missingObject.signature)
                // FIXME: This is wasteful, we should be able to just encode it all in one go.
                let serializer = MsgPackSerializer()
                object.serialize(to: serializer)
                additionalObjects.append(.init(pifType: missingObject.type, signature: missingObject.signature, data: serializer.byteString))
            }
            message = TransferSessionPIFObjectsRequest(sessionHandle: self.uid, objects: additionalObjects)
        }
    }

    public func workspaceInfo() async throws -> SWBWorkspaceInfo {
        try await SWBWorkspaceInfo(service.send(request: WorkspaceInfoRequest(sessionHandle: uid)).workspaceInfo)
    }

    /// Get the `DEVELOPER_DIR` path.
    public func developerPath() async throws -> String {
        try await service.send(request: DeveloperPathRequest(sessionHandle: uid)).value
    }

    /// Set the session system information.
    public func setSystemInfo(_ systemInfo: SWBSystemInfo) async throws {
        _ = try await service.send(request: SetSessionSystemInfoRequest(sessionHandle: uid, operatingSystemVersion: Version(systemInfo.operatingSystemVersion), productBuildVersion: systemInfo.productBuildVersion, nativeArchitecture: systemInfo.nativeArchitecture))
    }

    /// Set the session user information.
    public func setUserInfo(_ userInfo: SWBUserInfo) async throws {
        _ = try await service.send(request: SetSessionUserInfoRequest(sessionHandle: self.uid, user: userInfo.userName, group: userInfo.groupName, uid: userInfo.uid, gid: userInfo.gid, home: userInfo.homeDirectory, processEnvironment: userInfo.processEnvironment, buildSystemEnvironment: userInfo.buildSystemEnvironment))
    }

    @available(*, deprecated, renamed: "setUserPreferences(enableDebugActivityLogs:enableBuildDebugging:enableBuildSystemCaching:activityTextShorteningLevel:usePerConfigurationBuildLocations:allowsExternalToolExecution:)")
    public func setUserPreferences(enableDebugActivityLogs: Bool, enableBuildDebugging: Bool, enableBuildSystemCaching: Bool, activityTextShorteningLevel: Int, usePerConfigurationBuildLocations: Bool?) async throws {
        _ = try await service.send(request: SetSessionUserPreferencesRequest(sessionHandle: self.uid, enableDebugActivityLogs: enableDebugActivityLogs, enableBuildDebugging: enableBuildDebugging, enableBuildSystemCaching: enableBuildSystemCaching, activityTextShorteningLevel: ActivityTextShorteningLevel(rawValue: activityTextShorteningLevel) ?? .default, usePerConfigurationBuildLocations: usePerConfigurationBuildLocations))
    }

    public func setUserPreferences(enableDebugActivityLogs: Bool, enableBuildDebugging: Bool, enableBuildSystemCaching: Bool, activityTextShorteningLevel: Int, usePerConfigurationBuildLocations: Bool?, allowsExternalToolExecution: Bool) async throws {
        _ = try await service.send(request: SetSessionUserPreferencesRequest(sessionHandle: self.uid, enableDebugActivityLogs: enableDebugActivityLogs, enableBuildDebugging: enableBuildDebugging, enableBuildSystemCaching: enableBuildSystemCaching, activityTextShorteningLevel: ActivityTextShorteningLevel(rawValue: activityTextShorteningLevel) ?? .default, usePerConfigurationBuildLocations: usePerConfigurationBuildLocations, allowsExternalToolExecution: allowsExternalToolExecution))
    }
}

extension SWBBuildServiceSession {
    private func handleDelegateMessageOnChannel<T: Message>(makeMessage: @Sendable @escaping (UInt64) -> any SessionChannelMessage, delegate: (any SWBPlanningOperationDelegate)?) async throws -> T? {
        let replyChannel = service.openChannel()

        // Creates a session message using the `makeMessage` closure and send it on the provided channel.
        let response = await replyChannel.send(makeMessage)
        switch response {
        case is VoidResponse:
            // Request was received successfully, continue on to handle the channel messages.
            break
        default:
            throw StubError.error("Unexpected message: \(response)")
        }

        // Enumerate the infinite stream of channel reply messages; we'll return once we receive a message of our expected type or some other message type indicating a failure or cancellation.
        for await msgOpt in replyChannel.stream {
            switch msgOpt {
            case let msg as T:
                return msg
            case is VoidResponse:
                return nil
            case let msg as ErrorResponse:
                throw StubError.error(msg.description)
            case is PlanningOperationWillStart, is PlanningOperationDidFinish:
                continue
            case let msg as GetProvisioningTaskInputsRequest:
                await handle(message: msg, session: self, delegate: delegate)
                continue
            case let msg as ExternalToolExecutionRequest:
                await handle(message: msg, session: self, delegate: delegate)
                continue
            default:
                break
            }

            throw StubError.error("Unexpected message: \(msgOpt.map(String.init(describing:)) ?? "<nil>")")
        }

        // NOTE: If any GetProvisioningTaskInputsRequest/ExternalToolExecutionRequest messages are received, cancellation may result in them never receiving a reply, which could result in background operations hanging. We should find a way to handle that better.

        // nil indicates Task cancellation (we broke out of the loop)
        return nil
    }

    private func handleProductPlannerMessage<T: Message>(makeMessage: @Sendable @escaping (UInt64) -> any SessionChannelMessage) async throws -> T {
        guard let msg: T = try await handleDelegateMessageOnChannel(makeMessage: makeMessage, delegate: nil) else {
            throw StubError.error("The describe operation was cancelled.")
        }
        return msg
    }
}

// MARK: Convenience extensions for marshalling build parameters

// FIXME: We have moved the base objects to Swift, but we need to do more work to be able to use the native Swift objects here -- we can't simply expect them to be re-exported from SwiftBuild.framework, since they live in a separate module we do not want to install.

extension SWBBuildTaskStyle {
    var messagePayloadRepresentation: BuildTaskStyleMessagePayload {
        switch self {
        case .buildOnly:
            return .buildOnly
        case .buildAndRun:
            return .buildAndRun
        }
    }
}

extension SWBBuildLocationStyle {
    var messagePayloadRepresentation: BuildLocationStyleMessagePayload {
        switch self {
        case .regular:
            return .regular
        case .legacy:
            return .legacy
        }
    }
}

extension SWBPreviewStyle {
    var messagePayloadRepresentation: PreviewStyleMessagePayload {
        switch self {
        case .dynamicReplacement:
            return .dynamicReplacement
        case .xojit:
            return .xojit
        }
    }
}

extension SWBBuildCommand {
    var messagePayloadRepresentation: BuildCommandMessagePayload {
        switch command {
        case let .build(style, skipDependencies):
            return .build(style: style.messagePayloadRepresentation, skipDependencies: skipDependencies)
        case let .buildFiles(paths: paths, action: action):
            switch action {
            case .compile:
                return .singleFileBuild(buildOnlyTheseFiles: paths)
            case .preprocess:
                return .generatePreprocessedFile(buildOnlyTheseFiles: paths)
            case .assemble:
                return .generateAssemblyCode(buildOnlyTheseFiles: paths)
            }
        case let .prepareForIndexing(buildOnlyTheseTargets, enableIndexBuildArena):
            return .prepareForIndexing(buildOnlyTheseTargets: buildOnlyTheseTargets, enableIndexBuildArena: enableIndexBuildArena)
        case .migrate:
            return .migrate
        case let .cleanBuildFolder(style):
            return .cleanBuildFolder(style: style.messagePayloadRepresentation)
        case let .preview(style):
            return .preview(style: style.messagePayloadRepresentation)
        }
    }
}

extension SWBSchemeCommand {
    var messagePayloadRepresentation: SchemeCommandMessagePayload {
        switch self {
        case .archive:
            return .archive
        case .launch:
            return .launch
        case .profile:
            return .profile
        case .test:
            return .test
        }
    }
}

extension SWBBuildQoS {
    var messagePayloadRepresentation: BuildQoSMessagePayload {
        switch self {
        case .background:
            return .background
        case .utility:
            return .utility
        case .default:
            return .default
        case .userInitiated:
            return .userInitiated
        }
    }
}

extension SWBBuildRequest {
    var messagePayloadRepresentation: BuildRequestMessagePayload {
        return BuildRequestMessagePayload(parameters: parameters.messagePayloadRepresentation, configuredTargets: configuredTargets.map{ $0.messagePayloadRepresentation }, dependencyScope: dependencyScope.messagePayload, continueBuildingAfterErrors: continueBuildingAfterErrors, hideShellScriptEnvironment: hideShellScriptEnvironment, useParallelTargets: useParallelTargets, useImplicitDependencies: useImplicitDependencies, useDryRun: useDryRun, showNonLoggedProgress: showNonLoggedProgress, recordBuildBacktraces: recordBuildBacktraces, generatePrecompiledModulesReport: generatePrecompiledModulesReport, buildPlanDiagnosticsDirPath: buildPlanDiagnosticsDirPath.map(Path.init), buildCommand: buildCommand.messagePayloadRepresentation, schemeCommand: schemeCommand?.messagePayloadRepresentation, containerPath: containerPath.map(Path.init), buildDescriptionID: buildDescriptionID, qos: qos?.messagePayloadRepresentation, jsonRepresentation: try? jsonData())
    }
}

extension SWBConfiguredTarget {
    var messagePayloadRepresentation: ConfiguredTargetMessagePayload {
        return ConfiguredTargetMessagePayload(guid: guid, parameters: parameters?.messagePayloadRepresentation)
    }
}

extension SWBBuildParameters {
    var messagePayloadRepresentation: BuildParametersMessagePayload {
        let overridesPayload = overrides.messagePayloadRepresentation
        return BuildParametersMessagePayload(action: action ?? "", configuration: configurationName, activeRunDestination: activeRunDestination.flatMap{RunDestinationInfo($0)}, activeArchitecture: activeArchitecture, arenaInfo: arenaInfo.flatMap{ArenaInfo($0)}, overrides: overridesPayload)
    }
}

fileprivate extension RunDestinationInfo {
    init(_ x: SWBRunDestinationInfo) {
        self.init(platform: x.platform, sdk: x.sdk, sdkVariant: x.sdkVariant, targetArchitecture: x.targetArchitecture, supportedArchitectures: OrderedSet(x.supportedArchitectures), disableOnlyActiveArch: x.disableOnlyActiveArch, hostTargetedPlatform: x.hostTargetedPlatform)
    }
}

fileprivate extension ArenaInfo {
    init(_ x: SWBArenaInfo) {
        self.init(derivedDataPath: Path(x.derivedDataPath), buildProductsPath: Path(x.buildProductsPath), buildIntermediatesPath: Path(x.buildIntermediatesPath), pchPath: Path(x.pchPath), indexRegularBuildProductsPath: x.indexRegularBuildProductsPath.map(Path.init), indexRegularBuildIntermediatesPath: x.indexRegularBuildIntermediatesPath.map(Path.init), indexPCHPath: Path(x.indexPCHPath), indexDataStoreFolderPath: x.indexDataStoreFolderPath.map(Path.init), indexEnableDataStore: x.indexEnableDataStore)
    }
}

fileprivate extension ActionInput {
    init(_ x: SWBActionInput) {
        self.init(configurationName: x.configurationName, targetIdentifiers: x.targetIdentifiers)
    }
}

fileprivate extension SchemeInput {
    init(_ x: SWBSchemeInput) {
        self.init(name: x.name, isShared: x.isShared, isAutogenerated: x.isAutogenerated, analyze: .init(x.analyze), archive: .init(x.archive), profile: .init(x.profile), run: .init(x.run), test: .init(x.test))
    }
}

fileprivate extension SWBActionInfo {
    init(_ x: ActionInfo) {
        self.init(configurationName: x.configurationName, products: x.products.map { .init($0) }, testPlans: x.testPlans?.map { .init($0) })
    }
}

fileprivate extension SWBActionsInfo {
    init(_ x: ActionsInfo) {
        self.init(analyze: .init(x.analyze), archive: .init(x.archive), profile: .init(x.profile), run: .init(x.run), test: .init(x.test))
    }
}

fileprivate extension SWBDestinationInfo {
    init(_ x: DestinationInfo) {
        self.init(platformName: x.platformName, isSimulator: x.isSimulator)
    }
}

fileprivate extension SWBProductInfo {
    init(_ x: ProductInfo) {
        self.init(displayName: x.displayName, identifier: x.identifier, supportedDestinations: x.supportedDestinations.map { .init($0) })
    }
}

fileprivate extension SWBTestPlanInfo {
    init(_ x: TestPlanInfo) {
        self.init(displayName: x.displayName)
    }
}

fileprivate extension SWBProductDescription {
    init(_ x: ProductDescription) {
        self.init(displayName: x.displayName, productName: x.productName, identifier: x.identifier, productType: .init(x.productType), dependencies: x.dependencies?.map { .init($0) }, bundleIdentifier: x.bundleIdentifier, targetedDeviceFamilies: x.targetedDeviceFamilies?.map { .init($0) }, deploymentTarget: x.deploymentTarget.description, marketingVersion: x.marketingVersion, buildVersion: x.buildVersion, enableBitcode: x.enableBitcode, codesign: x.codesign.map { .init($0) }, team: x.team, infoPlistPath: x.infoPlistPath, iconPath: x.iconPath)
    }
}

fileprivate extension SWBProductDescription.CodesignMode {
    init(_ x: ProductDescription.CodesignMode) {
        switch x {
        case .automatic:
            self = .automatic
        case .manual:
            self = .manual
        case let .unknown(value):
            self = .unknown(value)
        }
    }
}

fileprivate extension SWBProductDescription.DeviceFamily {
    init(_ x: ProductDescription.DeviceFamily) {
        switch x {
        case .appleTV:
            self = .appleTV
        case .appleWatch:
            self = .appleWatch
        case .iPad:
            self = .iPad
        case .iPhone:
            self = .iPhone
        case let .unknown(value):
            self = .unknown(value)
        }
    }
}

fileprivate extension SWBProductDescription.ProductType {
    init(_ x: ProductDescription.ProductType) {
        switch x {
        case .app:
            self = .app
        case .appex:
            self = .appex
        case .library:
            self = .library
        case .none:
            self = .none
        case .tests:
            self = .tests
        case .tool:
            self = .tool
        case let .unknown(value):
            self = .unknown(value)
        }
    }
}

fileprivate extension SWBProductTupleDescription {
    init(_ x: ProductTupleDescription) {
        self.init(displayName: x.displayName, productName: x.productName, productType: .init(x.productType), identifier: x.identifier, team: x.team, bundleIdentifier: x.bundleIdentifier, destination: .init(x.destination), containingSchemes: x.containingSchemes, iconPath: x.iconPath)
    }
}

fileprivate extension SWBSchemeDescription {
    init(_ x: SchemeDescription) {
        self.init(name: x.name, disambiguatedName: x.disambiguatedName, isShared: x.isShared, isAutogenerated: x.isAutogenerated, actions: .init(x.actions))
    }
}

fileprivate extension SWBPreviewInfo {
    init(_ previewInfo: PreviewInfoMessagePayload) throws {
        self.sdkRoot = previewInfo.context.sdkRoot
        self.sdkVariant = previewInfo.context.sdkVariant
        self.buildVariant = previewInfo.context.buildVariant
        self.architecture = previewInfo.context.architecture
        self.pifGUID = previewInfo.context.pifGUID
        switch previewInfo.kind {
        case let .thunkInfo(previewInfo):
            self.compileCommandLine = previewInfo.compileCommandLine
            self.linkCommandLine = previewInfo.linkCommandLine
            self.thunkSourceFile = previewInfo.thunkSourceFile.str
            self.thunkObjectFile = previewInfo.thunkObjectFile.str
            self.thunkLibrary = previewInfo.thunkLibrary.str
        case .targetDependencyInfo:
            throw StubError.error("Unexpected response type for request")
        }
    }
}

fileprivate extension SWBPreviewTargetDependencyInfo {
    init(_ previewInfo: PreviewInfoMessagePayload) throws {
        self.sdkRoot = previewInfo.context.sdkRoot
        self.sdkVariant = previewInfo.context.sdkVariant
        self.buildVariant = previewInfo.context.buildVariant
        self.architecture = previewInfo.context.architecture
        self.pifGUID = previewInfo.context.pifGUID
        switch previewInfo.kind {
        case .thunkInfo:
            throw StubError.error("Unexpected response type for request")
        case let .targetDependencyInfo(targetDependencyInfo):
            self.objectFileInputMap = targetDependencyInfo.objectFileInputMap
            self.linkCommandLine = targetDependencyInfo.linkCommandLine
            self.linkerWorkingDirectory = targetDependencyInfo.linkerWorkingDirectory
            self.swiftEnableOpaqueTypeErasure = targetDependencyInfo.swiftEnableOpaqueTypeErasure
            self.swiftUseIntegratedDriver = targetDependencyInfo.swiftUseIntegratedDriver
            self.enableJITPreviews = targetDependencyInfo.enableJITPreviews
            self.enableDebugDylib = targetDependencyInfo.enableDebugDylib
            self.enableAddressSanitizer = targetDependencyInfo.enableAddressSanitizer
            self.enableThreadSanitizer = targetDependencyInfo.enableThreadSanitizer
            self.enableUndefinedBehaviorSanitizer = targetDependencyInfo.enableUndefinedBehaviorSanitizer
        }
    }
}

extension SWBSettingsOverrides {
    var messagePayloadRepresentation: SettingsOverridesMessagePayload {
        return SettingsOverridesMessagePayload(synthesized: synthesized?.table ?? [:], commandLine: commandLine?.table ?? [:], commandLineConfigPath: commandLineConfigPath.map(Path.init), commandLineConfig: commandLineConfig?.table ?? [:], environmentConfigPath: environmentConfigPath.map(Path.init), environmentConfig: environmentConfig?.table ?? [:], toolchainOverride: toolchainOverride)
    }
}

extension SwiftBuildServicePIFObjectType {
    init(_ type: PIFObjectType) {
        switch type {
        case .workspace:
            self = .workspace
        case .project:
            self = .project
        case .target:
            self = .target
        }
    }
}
