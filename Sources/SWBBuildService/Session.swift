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
public import SWBCore
public import SWBProtocol
public import SWBServiceCore
package import SWBTaskExecution
import SWBUtil
import struct Foundation.UUID
import Synchronization

enum SessionError: Error {
    case noSettings(String)
    case differentWorkspace(WorkspaceDiff)
}

/// This class manages a unique session corresponding to a unique remote client session.
///
/// A session object manages a single workspace, but the client might elect to create multiple sessions for the same workspace.
public final class Session {
    /// A PIF transfer operation.
    final class PIFTransferOperation {
        enum Status {
            /// The operation is complete.
            case complete

            /// The operation is complete, but failed to load.
            case failed(_ error: any Error)

            /// The operation is complete, but the workspace was different than the one provided for auditing
            case auditFailed(diff: WorkspaceDiff)

            /// The operation is incomplete, and needs the listed objects.
            case incomplete(missingObjects: [(signature: String, type: PIFObjectType)])
        }

        /// The session to install into, once complete.
        unowned let session: Session

        /// The loading session.
        var loadingSession: IncrementalPIFLoader.LoadingSession

        /// The signature for the initial requested workspace.
        let workspaceSignature: String

        /// Whether the operation has already attempted a full re-transfer (in the case of errors).
        private var hasFailed = false

        /// The workspace we are trying to load, but loaded from a complete PIF rather than incrementally.
        ///
        /// May be provided by the client to optionally audit the incremental PIF loading, ensuring the results
        /// match what we would get from a complete reload of the PIF.
        private var comparisonWorkspace: SWBCore.Workspace?

        fileprivate init(session: Session, workspaceSignature: String) {
            self.session = session
            self.workspaceSignature = workspaceSignature
            self.loadingSession = session.incrementalPIFLoader.startLoading(workspaceSignature: workspaceSignature)
        }

        /// Cancel the loading operation.
        func cancel() {
            // Clear the active operation.
            session.currentPIFTransferOperation = nil
        }

        /// Continue the operation, either completing it if all data is transferred, or reporting on the remaining objects to transfer.
        func continueOperation() -> Status {
            let missingObjects = Array(loadingSession.missingObjects)
            if missingObjects.isEmpty {
                // If we have all the objects, attempt to load the workspace and install the context.
                do {
                    try complete()
                    return .complete
                } catch SessionError.differentWorkspace(let diff) {
                    log("error: The incremental PIF transfer did not produce the right contents. Left = incremental, right = full:\n\(diff)")
                    return .auditFailed(diff: diff)
                } catch {
                    // If we were unable to load the objects, we may have a corrupt cache. Since this would never heal itself, we handle this by forcing a cache clear and retransfer before giving up.
                    if !hasFailed {
                        log("forcing incremental PIF cache clear after loading error: \(error)")
                        hasFailed = true
                        session.incrementalPIFLoader.clearCache()
                        self.loadingSession = session.incrementalPIFLoader.startLoading(workspaceSignature: workspaceSignature)
                        return continueOperation()
                    }

                    return .failed(error)
                }
            } else {
                return .incomplete(missingObjects: missingObjects)
            }
        }

        func setComparisonPIF(objects data: PropertyListItem) throws {
            let signature = try PIFLoader.extractWorkspaceSignature(objects: data)
            let loader = PIFLoader(data: data, namespace: session.incrementalPIFLoader.userNamespace)
            comparisonWorkspace = try loader.load(workspaceSignature: signature)
        }

        /// Complete the loading operation.
        private func complete() throws {
            defer {
                // Always clear the active operation, regardless of whether loading succeeds.
                // However, only do this if we've already failed after clearing the cache
                // and re-trying in case of cache corruption (see `continueOperation()`),
                // because if we clear the session now, when re-transfer is attempted, it
                // will not be able to find the operation and will fail stating that no
                // transfer operation is in progress.
                if hasFailed {
                    session.currentPIFTransferOperation = nil
                }
            }

            let workspace = try self.loadingSession.load()
            session.workspaceContext = WorkspaceContext(core: session.core, workspace: workspace, processExecutionCache: ProcessExecutionCache())

            // If the client provided a full workspace to compare against (the "audit PIF"), we should make sure that the workspace we built incrementally matches it.
            if let comparisonWorkspace = self.comparisonWorkspace {
                let diff = workspace.diff(against: comparisonWorkspace)
                if diff.hasChanges {
                    throw SessionError.differentWorkspace(diff)
                }
            }

            // Clear the current operation if we really did succeed (implies hasFailed is false).
            session.currentPIFTransferOperation = nil
        }
    }

    private static let sessionCount = SWBMutex(0)

    /// The core used by this session.
    let core: Core

    /// The name of the session.
    let name: String

    /// The unique ID of the session.
    let UID: String

    /// The active workspace session
    public internal(set) var workspaceContext: WorkspaceContext?

    /// The incremental PIF loader.
    private let incrementalPIFLoader: IncrementalPIFLoader

    /// The active PIF loading session, if any.
    var currentPIFTransferOperation: PIFTransferOperation?

    /// The shared build description manager.
    package let buildDescriptionManager = BuildDescriptionManager(fs: SWBUtil.localFS, buildDescriptionMemoryCacheEvictionPolicy: .default(totalCostLimit: UserDefaults.buildDescriptionInMemoryCostLimit), maxCacheSize: (inMemory: UserDefaults.buildDescriptionInMemoryCacheSize, onDisk: UserDefaults.buildDescriptionOnDiskCacheSize))

    /// Create a new session.
    ///
    /// - Parameters:
    ///   - core: The core to use.
    ///   - name: The name of the session, for debugging purposes.
    ///   - cachePath: If provided, a path to use for persistent data caches.
    init(_ core: Core, _ name: String, cachePath: Path?) {
        self.core = core
        self.name = name
        self.incrementalPIFLoader = IncrementalPIFLoader(internalNamespace: core.specRegistry.internalMacroNamespace, cachePath: cachePath?.join("PIFCache"))

        // Allocate a session ID.
        UID = Session.sessionCount.withLock { sessionCount in
            defer { sessionCount += 1 }
            return "S\(sessionCount)"
        }
    }

    deinit {
        // These registries should always be cleared by a call from the client side in SWBBuildServiceSession.SessionResourceTracker.invalidateAll(), so if one of these assertions fails, then something likely has gone wrong in that code path.
        assert(registeredSettings.isEmpty, "deinit of Session while it still had \(registeredSettings.count) registered Settings objects")
        assert(activePlanningOperations.isEmpty, "deinit of Session while it still had \(activePlanningOperations.count) active PlanningOperations")
        assert(activeClientExchanges.isEmpty, "deinit of Session while it still had \(activeClientExchanges.count) active ClientExchanges")
    }

    /// Start a PIF synchronization operation.
    ///
    /// - Returns: The operation, or nil of one was already in progress.
    func startPIFTransfer(workspaceSignature: String) -> PIFTransferOperation? {
        if currentPIFTransferOperation != nil {
            return nil
        }

        let operation = PIFTransferOperation(session: self, workspaceSignature: workspaceSignature)
        currentPIFTransferOperation = operation
        return operation
    }

    /// Clears any cache that incremental PIF loader holds and starts the PIF transfer operation.
    func startPristinePIFTransfer(workspaceSignature: String) -> PIFTransferOperation? {
        incrementalPIFLoader.clearCache()
        return startPIFTransfer(workspaceSignature: workspaceSignature)
    }


    // MARK: Support for saving macro evaluation scopes to look up by a handle (UUID).


    /// The active Settings objects being vended for use by the client.
    /// - remark: This is presently only used in `PlanningOperation` to be able to evaluate some settings after receiving provisioning inputs from the client, without having to reconstruct the `ConfiguredTarget` in that asyncronous operation.
    var registeredSettings = Registry<String, Settings>()

    /// Register a `Settings` object with the session.  This returns a handle (a `UUID` string) to the caller which it can pass to the client and which can then be used to evaluate settings using this `Settings` object.  The caller is responsible for removing this `Settings` object from the session when it is no longer needed.
    func registerSettings(_ settings: Settings) -> String {
        let uuid = UUID()
        registeredSettings[uuid.description] = settings
        return uuid.description
    }

    /// Returns the `Settings` object for the string `handle`.  If there is no such `Settings` object registered with `handle`, then it throws a `.noSettings` exception.
    func settings(for handle: String) throws -> Settings {
        guard let settings = registeredSettings[handle] else { throw SessionError.noSettings("No settings in session for handle '\(handle)'.") }
        return settings
    }

    /// Unregisters the `Settings` object for the string `handle`.  If there is no such `Settings` object registered with `handle`, then it throws a `.noSettings` exception.
    ///
    /// - Returns: The unregistered settings for the handle.
    @discardableResult
    func unregisterSettings(for handle: String) throws -> Settings {
        guard let settings = registeredSettings.removeValue(forKey: handle) else { throw SessionError.noSettings("No settings to unregister in session for handle '\(handle)'.") }
        return settings
    }


    // MARK: Planning operation support


    /// The active planning operations, if any.
    ///
    /// The client is responsible for closing these.
    //
    // FIXME: This should just map on the UUID type, not a string.
    private var activePlanningOperations = Registry<String, PlanningOperation>()

    /// Create a new planning operation.  It is the client's responsibility to instruct us to discard this session when it's done with it.
    func createPlanningOperation(request: Request, workspaceContext: WorkspaceContext, buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, delegate: any PlanningOperationDelegate) -> PlanningOperation {
        let planningOperation = PlanningOperation(request: request, session: self, workspaceContext: workspaceContext, buildRequest: buildRequest, buildRequestContext: buildRequestContext, delegate: delegate)
        activePlanningOperations[planningOperation.uuid.description] = planningOperation
        request.send(PlanningOperationWillStart(sessionHandle: UID, planningOperationHandle: planningOperation.uuid.description))
        return planningOperation
    }

    /// Get the active planning operation for `uuid`.
    func planningOperation(for uuidDescription: String) -> PlanningOperation? {
        return activePlanningOperations[uuidDescription]
    }

    /// Discard the planning operation for `uuid`.
    func discardPlanningOperation(_ uuid: UUID) {
        guard let planningOperation = activePlanningOperations.removeValue(forKey: uuid.description) else {
            fatalError("tried to discard nonexistent PlanningOperation for UUID '\(uuid)'")
        }
        planningOperation.request.send(PlanningOperationDidFinish(sessionHandle: UID, planningOperationHandle: planningOperation.uuid.description))
    }


    // MARK: Client exchange objects

    // FIXME: This should just map on the UUID type, not a string.
    //
    /// The active client exchanges.  The service creates and discards these, and is responsible for adding and removing them from the session.
    private var activeClientExchanges = Registry<String, any ClientExchange>()

    /// Add a new client exchange to the session.
    func addClientExchange(_ exchange: any ClientExchange) {
        assert(activeClientExchanges[exchange.uuid.description] == nil, "tried to register a second ClientExchange with UUID '\(exchange.uuid)'")
        activeClientExchanges[exchange.uuid.description] = exchange
    }

    /// Get the active client exchange for the UUID.
    func clientExchange(for uuidDescription: String) -> (any ClientExchange)? {
        return activeClientExchanges[uuidDescription]
    }

    /// Discard a client exchange.
    func discardClientExchange(_ exchange: any ClientExchange) -> (any ClientExchange)? {
        activeClientExchanges.removeValue(forKey: exchange.uuid.description)
    }


    // MARK: Information operation support

    /// The active information operations
    private var activeInfoOperations = Registry<Int, InfoOperation>()

    /// Registers an information operation with the session
    func registerInfoOperation(_ operation: InfoOperation) {
        activeInfoOperations[operation.id] = operation
    }

    /// Get the information operation for `uuid`
    func infoOperation(for id: Int) -> InfoOperation? {
        return activeInfoOperations[id]
    }

    /// Unregister an information operation from the session
    func unregisterInfoOperation(_ operation: InfoOperation) {
        guard activeInfoOperations.removeValue(forKey: operation.id) != nil else {
            fatalError("tried to unregister nonexistent info operation: '\(operation)'")
        }
    }

    /// Cancel ongoing information operations
    func cancelInfoOperations() {
        activeInfoOperations.forEach {
                $0.1.cancel()
        }
    }

    func cancelIndexingInfoOperations() {
        activeInfoOperations.forEach {
            if $0.1 is IndexingOperation {
                $0.1.cancel()
            }
        }
    }


    // MARK: Build operation support

    /// The active build operations
    private var activeBuilds = Registry<Int, any ActiveBuildOperation>()

    /// Returns the normal build operations, excluding the ones that are for the index.
    private var activeNormalBuilds: [any ActiveBuildOperation] {
        return activeBuilds.values.filter{ !$0.buildRequest.enableIndexBuildArena && !$0.onlyCreatesBuildDescription }
    }

    /// Returns index build operations.
    private var activeIndexBuilds: [any ActiveBuildOperation] {
        return activeBuilds.values.filter{ $0.buildRequest.enableIndexBuildArena && !$0.onlyCreatesBuildDescription }
    }

    /// Registers a build operation with the session
    public func registerActiveBuild(_ build: any ActiveBuildOperation) throws {
        // We currently don't support running multiple build operations in one session, this is just a defensive precondition.
        // But we do allow build description creation operations to run concurrently with normal builds. These are important for index queries to function properly even during a build.
        // We also allow 'prepare-for-index' build operations to run concurrently with a normal build but only one at a time. These are important for functionality in the Xcode editor to work properly, that the user directly interacts with.
        if !build.onlyCreatesBuildDescription {
            let (buildType, existingBuilds) = build.buildRequest.enableIndexBuildArena
                ? ("index", activeIndexBuilds)
                : ("normal", activeNormalBuilds)

            if !existingBuilds.isEmpty {
                throw StubError.error("unexpected attempt to have multiple concurrent \(buildType) build operations")
            }
        }

        activeBuilds[build.id] = build
    }

    func activeBuildStats() -> (all: Int, normal: Int, index: Int) {
        (activeBuilds.count, activeNormalBuilds.count, activeIndexBuilds.count)
    }

    /// Get the active build operation for `uuid`
    func activeBuild(for id: Int) -> (any ActiveBuildOperation)? {
        return activeBuilds[id]
    }

    /// Unregister a build operation from the session
    public func unregisterActiveBuild(_ build: any ActiveBuildOperation) {
        guard activeBuilds.removeValue(forKey: build.id) != nil else {
            fatalError("tried to unregister nonexistent build: '\(build)'")
        }
    }
}


/// A client exchange is used to send a request to the client and handle its response.  The service creates and discards these, and is responsible for adding and removing them from the session.
protocol ClientExchange {
    /// The stable UUID of the receiver.
    var uuid: UUID { get }
}


// Session Extensions

extension Request {
    /// Retrieve the session for the message, or throw if invalid.
    public func session<T: SessionMessage>(for message: T) throws -> Session {
        guard let session = buildService.sessionMap[message.sessionHandle] else {
            throw MsgParserError.unknownSession(handle: message.sessionHandle)
        }
        return session
    }
}
