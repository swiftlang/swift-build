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

import struct Foundation.Date
import class Foundation.JSONEncoder

package import SWBCore
import SWBLibc
package import SWBTaskConstruction
package import SWBUtil
package import struct SWBProtocol.BuildDescriptionID
package import struct SWBProtocol.BuildOperationTaskEnded
import SWBMacro
import Synchronization

/// An enum describing from where the build description was retrieved, for testing purposes.
package enum BuildDescriptionRetrievalSource {
    /// A new build description was constructed.
    case new
    /// The build description was cached in memory.
    case inMemoryCache
    /// The build description was loaded from serialized form on disk.
    case onDiskCache
}

/// A structure describing how the build description was retrieved, for testing purposes.
package struct BuildDescriptionRetrievalInfo {
    /// The `BuildDescription` returned.
    package let buildDescription: BuildDescription
    /// The source of the `BuildDescription`.
    package let source: BuildDescriptionRetrievalSource
    /// The size of the in-memory cache after the description was retrieved (so, if this was the first description retrieved, the size will be '1').
    package let inMemoryCacheSize: Int
    /// The location of the build description cache file on disk.  If not loaded from disk, then this is where the description was (or will be) written to.
    package let onDiskCachePath: Path

    package init(buildDescription: BuildDescription, source: BuildDescriptionRetrievalSource, inMemoryCacheSize: Int, onDiskCachePath: Path) {
        self.buildDescription = buildDescription
        self.source = source
        self.inMemoryCacheSize = inMemoryCacheSize
        self.onDiskCachePath = onDiskCachePath
    }

    /// The size of the on-disk cache, queried via the filesystem when this function is called.
    package func onDiskCacheSize(fs: any FSProxy) -> Int {
        let all = (try? fs.listdir(onDiskCachePath.dirname)) ?? []
        return all.filter({ $0.hasSuffix(BuildDescription.bundleExtension) }).count
    }
}

/// Controls the non-deterministic eviction policy of the cache. Note that this is distinct from deterministic _pruning_ (due to TTL or size limits).
package enum BuildDescriptionMemoryCacheEvictionPolicy: Sendable, Hashable {
    /// Never evict due to memory pressure.
    case never

    /// Default `NSCache` eviction behaviors.
    case `default`(totalCostLimit: Int)
}

/// This class is responsible for the construction and management of BuildDescriptions.
///
/// It is intended to manage the construction of descriptions for incoming build requests (or other operations requiring a complete build description), and to work with the build descriptions to efficiently cache the results.
package final class BuildDescriptionManager: Sendable {
    static let descriptionsRequested = Statistic("BuildDescriptionManager.descriptionRequests",
        "The number of build descriptions which were requested.")
    static let descriptionsComputed = Statistic("BuildDescriptionManager.descriptionsComputed",
        "The number of build descriptions which were computed.")
    static let descriptionsLoaded = Statistic("BuildDescriptionManager.descriptionsLoaded",
        "The number of build descriptions which were loaded from disk.")

    /// The queue used to serialize access to the on-disk description cache.
    /// Right now this is only used to write the serialized cached descriptions to disk on a background thread and to remove them from disk, but not to read them or to access the index.  In order for this to be a problem, this description would need to be evicted from the in-memory cache and a new request for this description would need to come in before the description has been written.  A further refinement of this could involve ensuring that the in-memory copy never gets evicted until the on-disk copy has been written, or providing more sophisticated read/white synchronization of the individual on-disk cache items.
    private let onDiskCacheAccessQueue = SWBQueue(label: "SWBTaskExecution.BuildDescriptionManager.onDiskCacheAccessQueue", qos: UserDefaults.undeterminedQoS, autoreleaseFrequency: .workItem)

    /// The FS to use.
    private let fs: any FSProxy

    /// The number of cached build descriptions to retain on memory and in serialized form on disk.
    private let maxCacheSize: (inMemory: Int, onDisk: Int)

    /// The in-memory cache of build descriptions.
    private let inMemoryCachedBuildDescriptions: HeavyCache<BuildDescriptionSignature, BuildDescription>

    /// The last build plan request. Used to generate a diff of the current plan for debugging purposes.
    private let lastBuildPlanRequest: SWBMutex<BuildPlanRequest?> = .init(nil)

    /// The last build plan request for the workspace build description. Used to generate a diff of the current plan
    /// for debugging purposes.
    private let lastIndexBuildPlanRequest: SWBMutex<BuildPlanRequest?> = .init(nil)

    /// The last workspace build description generated for the index arena.
    ///
    /// Separated from the regular cache as the index assumes that requests for build settings are fast once this is
    /// loaded, so it shouldn't ever be removed.
    private let lastIndexWorkspaceDescription: SWBMutex<BuildDescription?> = .init(nil)

    package init(fs: any FSProxy, buildDescriptionMemoryCacheEvictionPolicy: BuildDescriptionMemoryCacheEvictionPolicy, maxCacheSize: (inMemory: Int, onDisk: Int) = (4, 4)) {
        self.fs = fs
        self.inMemoryCachedBuildDescriptions = withHeavyCacheGlobalState(isolated: buildDescriptionMemoryCacheEvictionPolicy == .never) {
            HeavyCache(maximumSize: maxCacheSize.inMemory, evictionPolicy: {
                switch buildDescriptionMemoryCacheEvictionPolicy {
                case .never:
                    .never
                case .default(let totalCostLimit):
                    .default(totalCostLimit: totalCostLimit, willEvictCallback: { buildDescription in
                        // Capture the path to a local variable so that the buildDescription instance isn't retained by OSLog's autoclosure message parameter.
                        let packagePath = buildDescription.packagePath
                        #if canImport(os)
                        OSLog.log("Evicted cached build description at '\(packagePath.str)'")
                        #endif
                    })
                }
            }())
        }
        self.maxCacheSize = maxCacheSize
    }

    package func waitForBuildDescriptionSerialization() async {
        await onDiskCacheAccessQueue.sync { }
    }

    /// Construct the appropriate build plan for a plan request.
    ///
    /// NOTE: This is primarily accessible for performance testing purposes, actual clients should prefer to access via the cached methods.
    ///
    /// - Returns: The build plan, or nil if cancelled during construction.
    package static func constructBuildPlan(_ planRequest: BuildPlanRequest, _ clientDelegate: any TaskPlanningClientDelegate, constructionDelegate: any BuildDescriptionConstructionDelegate, descriptionPath: Path) async -> BuildPlan? {
        return await BuildPlan(planRequest: planRequest, taskPlanningDelegate: BuildSystemTaskPlanningDelegate(buildDescriptionPath: descriptionPath, clientDelegate, constructionDelegate: constructionDelegate, qos: planRequest.buildRequest.qos, fileSystem: localFS))
    }


    /// Construct the build description to use for a particular workspace and request.
    ///
    /// NOTE: This is primarily accessible for performance testing purposes, actual clients should prefer to access via the cached methods.
    ///
    /// - Returns: A build description, or nil if cancelled.
    package static func constructBuildDescription(_ planRequest: BuildPlanRequest, signature: BuildDescriptionSignature, inDirectory cacheDir: Path? = nil, fs: any FSProxy, bypassActualTasks: Bool = false, clientDelegate: any TaskPlanningClientDelegate, constructionDelegate: any BuildDescriptionConstructionDelegate) async throws -> BuildDescription? {
        return try await planRequest.buildRequestContext.keepAliveSettingsCache {
            if constructionDelegate.cancelled {
                return nil
            }

            // Compute the path to store the build description.
            let descriptionPath = try cacheDir ?? BuildDescriptionManager.cacheDirectory(planRequest).join("XCBuildData")

            // Construct the build plan for this operation.
            let delegate = BuildSystemTaskPlanningDelegate(buildDescriptionPath: BuildDescription.buildDescriptionPackagePath(inDir: descriptionPath, signature: signature), clientDelegate, constructionDelegate: constructionDelegate, qos: planRequest.buildRequest.qos, fileSystem: fs)
            guard let plan = await BuildPlan(planRequest: planRequest, taskPlanningDelegate: delegate) else {
                return nil
            }

            // Write out diagnostics files to the file system, if we've been asked to do so.
            if let buildPlanDiagPath = planRequest.buildRequest.buildPlanDiagnosticsDirPath {
                try plan.write(to: buildPlanDiagPath, fs: fs)
            }

            return try await constructBuildDescription(plan, planRequest: planRequest, signature: signature, inDirectory: descriptionPath, fs: fs, bypassActualTasks: bypassActualTasks, planningDiagnostics: delegate.diagnostics, delegate: constructionDelegate)
        }
    }

    /// Construct the build description to use for a particular workspace and request.
    ///
    /// NOTE: This is primarily accessible for performance testing purposes, actual clients should prefer to access via the cached methods.
    ///
    /// - Returns: A build description, or nil if cancelled.
    package static func constructBuildDescription(_ plan: BuildPlan, planRequest: BuildPlanRequest, signature: BuildDescriptionSignature, inDirectory path: Path, fs: any FSProxy, bypassActualTasks: Bool = false, planningDiagnostics: [ConfiguredTarget?: [Diagnostic]], delegate: any BuildDescriptionConstructionDelegate) async throws -> BuildDescription? {
        BuildDescriptionManager.descriptionsComputed.increment()

        // Compute the default configuration name, platform and root paths per target
        var staleFileRemovalIdentifierPerTarget = [ConfiguredTarget?: String]()
        var settingsPerTarget = [ConfiguredTarget:Settings]()
        var rootPathsPerTarget = [ConfiguredTarget:[Path]]()
        var moduleCachePathsPerTarget = [ConfiguredTarget: [Path]]()
        let buildGraph = planRequest.buildGraph

        // Add the SFR identifier for target-independent tasks.
        staleFileRemovalIdentifierPerTarget[nil] = plan.staleFileRemovalTaskIdentifier(for: nil)

        for target in buildGraph.allTargets {
            let settings = planRequest.buildRequestContext.getCachedSettings(target.parameters, target: target.target)
            rootPathsPerTarget[target] = [
                settings.globalScope.evaluate(BuiltinMacros.DSTROOT),
                settings.globalScope.evaluate(BuiltinMacros.OBJROOT),
                settings.globalScope.evaluate(BuiltinMacros.SYMROOT),
            ]

            moduleCachePathsPerTarget[target] = [
                settings.globalScope.evaluate(BuiltinMacros.MODULE_CACHE_DIR),
                Path(settings.globalScope.evaluate(BuiltinMacros.SWIFT_EXPLICIT_MODULES_OUTPUT_PATH)),
                Path(settings.globalScope.evaluate(BuiltinMacros.CLANG_EXPLICIT_MODULES_OUTPUT_PATH)),
            ]

            staleFileRemovalIdentifierPerTarget[target] = plan.staleFileRemovalTaskIdentifier(for: target)
            settingsPerTarget[target] = settings
        }

        let definingTargetsByModuleName = {
            var definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>] = [:]
            for target in buildGraph.allTargets {
                let settings = planRequest.buildRequestContext.getCachedSettings(target.parameters, target: target.target)
                let moduleInfo = plan.globalProductPlan.getModuleInfo(target)
                let specLookupContext = SpecLookupCtxt(specRegistry: planRequest.workspaceContext.core.specRegistry, platform: settings.platform)
                let buildingAnySwiftSourceFiles = (target.target as? BuildPhaseTarget)?.sourcesBuildPhase?.containsSwiftSources(planRequest.workspaceContext.workspace, specLookupContext, settings.globalScope, settings.filePathResolver) ?? false
                if buildingAnySwiftSourceFiles {
                    let swiftModuleName = settings.globalScope.evaluate(BuiltinMacros.SWIFT_MODULE_NAME)
                    definingTargetsByModuleName[swiftModuleName, default: []].append(target)
                }
                for clangModuleName in moduleInfo?.knownClangModuleNames ?? [] {
                    definingTargetsByModuleName[clangModuleName, default: []].append(target)
                }
            }
            return definingTargetsByModuleName
        }()

        // Only capture build information if it was requested.
        let capturedBuildInfo: CapturedBuildInfo?
        if planRequest.workspaceContext.userInfo?.processEnvironment["CAPTURED_BUILD_INFO_DIR"] != nil {
            // Capture the info about this build.
            capturedBuildInfo = CapturedBuildInfo(buildGraph, settingsPerTarget)
        } else {
            capturedBuildInfo = nil
        }

        // Create the build description.
        return try await BuildDescription.construct(workspace: buildGraph.workspaceContext.workspace, tasks: plan.tasks, path: path, signature: signature, buildCommand: planRequest.buildRequest.buildCommand, diagnostics: planningDiagnostics, indexingInfo: [], fs: fs, bypassActualTasks: bypassActualTasks, targetsBuildInParallel: buildGraph.targetsBuildInParallel, emitFrontendCommandLines: plan.emitFrontendCommandLines, moduleSessionFilePath: planRequest.workspaceContext.getModuleSessionFilePath(planRequest.buildRequest.parameters), invalidationPaths: plan.invalidationPaths, recursiveSearchPathResults: plan.recursiveSearchPathResults, copiedPathMap: plan.copiedPathMap, rootPathsPerTarget: rootPathsPerTarget, moduleCachePathsPerTarget: moduleCachePathsPerTarget, staleFileRemovalIdentifierPerTarget: staleFileRemovalIdentifierPerTarget, settingsPerTarget: settingsPerTarget, delegate: delegate, targetDependencies: buildGraph.targetDependenciesByGuid, definingTargetsByModuleName: definingTargetsByModuleName, capturedBuildInfo: capturedBuildInfo, userPreferences: buildGraph.workspaceContext.userPreferences)
    }

    /// Encapsulates the two ways `getNewOrCachedBuildDescription` can be called, whether we want to retrieve or create a build description based on a plan or whether we have an explicit build description ID that we want to retrieve and we don't need to create a new one.
    ///
    /// During normal operation (outside of tests), this should always be called on `queue`.
    package enum BuildDescriptionRequest {
        /// Retrieve or create a build description based on a build plan.
        case newOrCached(BuildPlanRequest, bypassActualTasks: Bool, useSynchronousBuildDescriptionSerialization: Bool)
        /// Retrieve an existing build description, build planning has been avoided. If the build description is not available then `getNewOrCachedBuildDescription` will fail.
        case cachedOnly(BuildDescriptionID, request: BuildRequest, buildRequestContext: BuildRequestContext, workspaceContext: WorkspaceContext)

        var buildRequest: BuildRequest {
            switch self {
            case .newOrCached(let planRequest, _, _): return planRequest.buildRequest
            case .cachedOnly(_, let request, _, _): return request
            }
        }

        var buildRequestContext: BuildRequestContext {
            switch self {
            case .newOrCached(let planRequest, _, _): return planRequest.buildRequestContext
            case .cachedOnly(_, _, let buildRequestContext, _): return buildRequestContext
            }
        }

        var planRequest: BuildPlanRequest? {
            switch self {
            case .newOrCached(let planRequest, _, _): return planRequest
            case .cachedOnly: return nil
            }
        }

        var workspaceContext: WorkspaceContext {
            switch self {
            case .newOrCached(let planRequest, _, _): return planRequest.workspaceContext
            case .cachedOnly(_, _, _, let workspaceContext): return workspaceContext
            }
        }

        /// True if we only need to retrieve an existing build description that was created earlier.
        var isForCachedOnly: Bool {
            if case .cachedOnly = self {
                return true
            } else {
                return false
            }
        }

        var isForIndex: Bool {
            return buildRequest.enableIndexBuildArena
        }

        var isIndexWorkspaceDescription: Bool {
            return isForIndex && buildRequest.parameters.activeRunDestination == nil
        }

        func signature(cacheDir: Path) throws -> BuildDescriptionSignature {
            switch self {
            case .newOrCached(let planRequest, _, _): return try BuildDescriptionSignature.buildDescriptionSignature(planRequest, cacheDir: cacheDir)
            case .cachedOnly(let buildDescriptionID, _, _, _):  return BuildDescriptionSignature.buildDescriptionSignature(buildDescriptionID)
            }
        }
    }

    private func getCachedBuildDescription(request: BuildDescriptionRequest, signature: BuildDescriptionSignature, constructionDelegate: any BuildDescriptionConstructionDelegate) -> BuildDescription? {
        var description: BuildDescription?
        if let lastDescription = lastIndexWorkspaceDescription.withLock({ $0 }), lastDescription.signature == signature {
            description = lastDescription
        } else if let inMemoryDescription = inMemoryCachedBuildDescriptions[signature] {
            description = inMemoryDescription
        } else {
            description = nil
        }

        guard let description, description.isValidFor(request: request, managerFS: fs) else {
            return nil
        }

        return description
    }

    /// Returns a build description info struct for a particular workspace and request. This method is primarily intended for testing, as the struct contains information about whether a cached instance was used.
    package func getNewOrCachedBuildDescription(_ request: BuildDescriptionRequest, clientDelegate: any TaskPlanningClientDelegate, constructionDelegate: any BuildDescriptionConstructionDelegate) async throws -> BuildDescriptionRetrievalInfo? {
        BuildDescriptionManager.descriptionsRequested.increment()

        // May perform settings construction and take 25-30ms uncached
        let parentCacheDir = try BuildDescriptionManager.cacheDirectory(request)

        if !request.isForCachedOnly {
            // Make sure the top-level build directory is appropriately tagged with our extended attribute if we created it.
            _ = CreateBuildDirectoryTaskAction.createBuildDirectory(at: parentCacheDir, fs: fs)
        }

        let cacheDir = parentCacheDir.join("XCBuildData")
        let signature: BuildDescriptionSignature = try request.signature(cacheDir: cacheDir)
        if request.workspaceContext.userPreferences.enableDebugActivityLogs {
            constructionDelegate.updateProgress(statusMessage: "Build description signature is \(signature.unsafeStringValue)", showInLog: true)
        }
        let buildDescriptionPath = BuildDescription.buildDescriptionPackagePath(inDir: cacheDir, signature: signature)

        let buildDescription: BuildDescription
        let source: BuildDescriptionRetrievalSource

        // Attempt to load from the in-memory cache
        if let inMemoryDescription = getCachedBuildDescription(request: request, signature: signature, constructionDelegate: constructionDelegate) {
            constructionDelegate.updateProgress(statusMessage: request.workspaceContext.userPreferences.activityTextShorteningLevel == .full ? "Using in-memory description" : "Using build description from memory", showInLog: request.workspaceContext.userPreferences.enableDebugActivityLogs)
            buildDescription = inMemoryDescription
            source = .inMemoryCache
        } else {
            // No in-memory build description, attempt to load it from the on-disk cache, and fallback to building
            // otherwise.
            do {
                (buildDescription, source) = try await constructionDelegate.withActivity(ruleInfo: "CreateBuildDescription", executionDescription: "Create build description", signature: signature, target: nil, parentActivity: nil) { activity in
                    return try await ActivityID.$buildDescriptionActivity.withValue(activity) {
                        return try await loadBuildDescription(request: request, signature: signature, onDiskPath: buildDescriptionPath, clientDelegate: clientDelegate, constructionDelegate: constructionDelegate, activity: activity)
                    }
                }
            } catch is CancellationError {
                return nil
            }

            // Update in-memory cache (since we either loaded it off disk or created a new description).
            // Do this at elevated priority to ensure any cache evictions that insertion will perform are done promptly and don't delay other work.
            await _Concurrency.Task(priority: .userInitiated) {
                if request.isIndexWorkspaceDescription {
                    lastIndexWorkspaceDescription.withLock {
                        $0 = buildDescription
                    }
                } else {
                    inMemoryCachedBuildDescriptions[signature] = buildDescription
                }
            }.value
        }

        // Touch the serialized file to denote its use (if we didn't just create it)
        if source != .new {
            if UserDefaults.useSynchronousBuildDescriptionSerialization || request.workspaceContext.userPreferences.enableBuildDebugging {
                await onDiskCacheAccessQueue.sync {
                    try? self.fs.touch(buildDescription.packagePath)
                }
            } else {
                // This is background even though it's a cheap operation because serialization happens on this queue within `loadBuildDescription` (which we called above), and because this is a serial queue, the touching of the package path will occur after serialization has completed.
                onDiskCacheAccessQueue.async(qos: .background) { [weak buildDescription] in
                    // Weak-capture buildDescription so we don't potentially deinit a BuildDescription on a background (lowest!) QoS queue if it happens to be the last reference when this block is deallocated, since this block is run in the background out of band. This could result in elevated memory usage as slow build description deallocations pile up.
                    guard let buildDescription else { return }
                    try? self.fs.touch(buildDescription.packagePath)
                }
            }
        }

        return BuildDescriptionRetrievalInfo(buildDescription: buildDescription, source: source, inMemoryCacheSize: inMemoryCachedBuildDescriptions.count, onDiskCachePath: buildDescriptionPath)
    }

    /// Returns a build description for a particular workspace and request.
    ///
    /// - Returns: A build description, or nil if cancelled.
    package func getBuildDescription(_ request: BuildPlanRequest, bypassActualTasks: Bool = false, useSynchronousBuildDescriptionSerialization: Bool = false, clientDelegate: any TaskPlanningClientDelegate, constructionDelegate: any BuildDescriptionConstructionDelegate) async throws -> BuildDescription? {
        let descRequest = BuildDescriptionRequest.newOrCached(request, bypassActualTasks: bypassActualTasks, useSynchronousBuildDescriptionSerialization: useSynchronousBuildDescriptionSerialization)
        let retrievalInfo = try await getNewOrCachedBuildDescription(descRequest, clientDelegate: clientDelegate, constructionDelegate: constructionDelegate)
        return retrievalInfo?.buildDescription
    }

    /// Returns the path in which the`XCBuildData` directory will live. That location is uses to cache build descriptions for a particular workspace and request, the manifest, and the `build.db` database for llbuild.
    package static func cacheDirectory(_ request: BuildPlanRequest) throws -> Path {
        return try cacheDirectory(request.buildRequest, buildRequestContext: request.buildRequestContext, workspaceContext: request.workspaceContext)
    }

    /// Returns the path in which the`XCBuildData` directory will live. That location is uses to cache build descriptions for a particular workspace and request, the manifest, and the `build.db` database for llbuild.
    package static func cacheDirectory(_ request: BuildDescriptionRequest) throws -> Path {
        return try cacheDirectory(request.buildRequest, buildRequestContext: request.buildRequestContext, workspaceContext: request.workspaceContext)
    }

    /// Returns the path in which the`XCBuildData` directory will live. That location is uses to cache build descriptions for a particular workspace and request, the manifest, and the `build.db` database for llbuild.
    package static func cacheDirectory(_ request: BuildRequest, buildRequestContext: BuildRequestContext, workspaceContext: WorkspaceContext) throws -> Path {
        // Make this more efficient for index queries if the index build arena is enabled.
        if request.enableIndexBuildArena, let arena = request.parameters.arena {
            return arena.buildIntermediatesPath
        }

        // Get settings for the sole project if there is only one, otherwise the workspace-global settings.
        let settings: Settings = {
            if let onlyProject = workspaceContext.workspace.projects.only {
                return buildRequestContext.getCachedSettings(request.parameters, project: onlyProject)
            }
            // FIXME: For project-style builds (no workspace arena), we shouldn't grab the first project, because "first" doesn't have any special meaning. Ideally we'd pick the top-level project specifically. However, that is not currently possible due to the fact that the PIF is flattened. So we preserve existing behavior for now to avoid breaking the non-workspace, nested-projects use case.
            if let firstProject = workspaceContext.workspace.projects.first, !(request.parameters.arena?.buildIntermediatesPath.isAbsolute ?? false) {
                return buildRequestContext.getCachedSettings(request.parameters, project: firstProject)
            }
            return buildRequestContext.getCachedSettings(request.parameters)
        }()

        // This is an override to specifically enable a legacy build location workflow for some projects (rdar://52005109). It should not be leveraged, relied upon, or in any way considered a good thing to build upon.
        let overrideDir = settings.globalScope.evaluate(BuiltinMacros.BUILD_DESCRIPTION_CACHE_DIR)
        if !overrideDir.isEmpty {
            return Path(overrideDir)
        }

        // NOTE: The way that `Path()` works is that any absolute paths provided via `join()` will essentially disregard the path information before it. This is subtle and *is* relied upon here by other places in the build system where `OBJROOT` is provided as an absolute path
        let objroot = settings.globalScope.evaluate(BuiltinMacros.SRCROOT).join(settings.globalScope.evaluate(BuiltinMacros.OBJROOT))
        if objroot.isAbsolute {
            return objroot
        }

        // Fall back to the arena info if the objroot wasn't absolute. This can happen if we have a Settings for a workspace and SRCROOT therefore isn't absolute itself.
        if let arena = request.parameters.arena {
            guard arena.buildIntermediatesPath.isAbsolute else {
                throw StubError.error("The workspace arena does not have an absolute build intermediates path to contain the build cache directory.")
            }
            return arena.buildIntermediatesPath
        }

        throw StubError.error("There is no workspace arena to determine the build cache directory path.")
    }

    private func loadBuildDescription(request: BuildDescriptionRequest, signature: BuildDescriptionSignature, onDiskPath: Path, clientDelegate: any TaskPlanningClientDelegate, constructionDelegate: any BuildDescriptionConstructionDelegate, activity: ActivityID) async throws -> (buildDescription: BuildDescription, source: BuildDescriptionRetrievalSource) {
        let userPreferences = request.workspaceContext.userPreferences
        let messageShortening = userPreferences.activityTextShorteningLevel


        if messageShortening != .full || userPreferences.enableDebugActivityLogs {
            constructionDelegate.updateProgress(statusMessage: "Attempting to load build description from disk", showInLog: request.workspaceContext.userPreferences.enableDebugActivityLogs)
        }

        let taskActionRegistry = try await TaskActionRegistry(pluginManager: request.workspaceContext.core.pluginManager)
        do {
            let onDiskDesc = try loadSerializedBuildDescription(onDiskPath, workspaceContext: request.workspaceContext, signature: signature, taskActionRegistry: taskActionRegistry)
            if onDiskDesc.isValidFor(request: request, managerFS: fs) {
                constructionDelegate.updateProgress(statusMessage: messageShortening == .full ? "Using on-disk description" : "Using build description from disk", showInLog: request.workspaceContext.userPreferences.enableDebugActivityLogs)
                BuildDescriptionManager.descriptionsLoaded.increment()
                return (buildDescription: onDiskDesc, source: .onDiskCache)
            }
        } catch {
            if request.isForCachedOnly {
                // Trying to load a specific build description so just report the error to the caller.
                throw error
            }
        }

        // Output the difference in signatures for debugging if we already had a build plan
        if request.workspaceContext.userPreferences.enableDebugActivityLogs,
           !request.isForIndex || request.isIndexWorkspaceDescription {
            let lastBuildPlanRequest = request.isForIndex ? lastIndexBuildPlanRequest.withLock({ $0 }) : lastBuildPlanRequest.withLock({ $0 })
            if let planRequest = request.planRequest, let lastBuildPlanRequest = lastBuildPlanRequest {
                do {
                    if let diff = try BuildDescriptionSignature.compareBuildDescriptionSignatures(planRequest, lastBuildPlanRequest, onDiskPath) {
                        constructionDelegate.emit(Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("New build description required because the signature changed"), childDiagnostics: [
                            Diagnostic(behavior: .note, location: .path(diff.previousSignaturePath), data: DiagnosticData("Previous signature: \(diff.previousSignaturePath.str)")),
                            Diagnostic(behavior: .note, location: .path(diff.currentSignaturePath), data: DiagnosticData("Current signature: \(diff.currentSignaturePath.str)")),
                        ]))
                    }
                } catch {
                    constructionDelegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("\(error)")))
                }
            }

            if request.isForIndex {
                self.lastIndexBuildPlanRequest.withLock {
                    $0 = request.planRequest
                }
            } else {
                self.lastBuildPlanRequest.withLock {
                    $0 = request.planRequest
                }
            }
        }

        // Unable to load from disk, create a new description
        guard case let .newOrCached(request, bypassActualTasks, useSynchronousBuildDescriptionSerialization) = request else {
            preconditionFailure("entered build construction path but request was for existing cached description")
        }

        constructionDelegate.updateProgress(statusMessage: messageShortening == .full ? "Constructing description" : "Constructing build description", showInLog: request.workspaceContext.userPreferences.enableDebugActivityLogs)
        guard let newDesc = try await BuildDescriptionManager.constructBuildDescription(request, signature: signature, inDirectory: onDiskPath.dirname, fs: fs, bypassActualTasks: bypassActualTasks, clientDelegate: clientDelegate, constructionDelegate: constructionDelegate) else {
            throw CancellationError()
        }

        // Serialize and write the build description and related content to disk and purge any old descriptions. We do this on a background thread since this is just caching the description and nothing cares about the saved form until something comes in to ask for it and we don't already have it in memory.
        //
        // For performance measurement purposes, we have a user default to force serializing the build description synchronously. We also use synchronous build description serialization if explicitly asked, or if build debugging is enabled, so the build description is written out in time for us to save it to the copy-aside directory just after the build is started (see `BuildOperation.build()`).
        if useSynchronousBuildDescriptionSerialization || UserDefaults.useSynchronousBuildDescriptionSerialization || request.workspaceContext.userPreferences.enableBuildDebugging {
            await onDiskCacheAccessQueue.sync {
                self.serializeBuildDescription(newDesc, request: request, taskActionRegistry: taskActionRegistry)
                self.purgeOld(currentBuildDescriptionPath: newDesc.packagePath)
            }
        } else {
            onDiskCacheAccessQueue.async(qos: .background) { [weak newDesc] in
                // Weak-capture newDesc so we don't potentially deinit a BuildDescription on a background (lowest!) QoS queue if it happens to be the last reference when this block is deallocated, since this block is run in the background out of band. This could result in elevated memory usage as slow build description deallocations pile up.
                guard let newDesc else { return }
                self.serializeBuildDescription(newDesc, request: request, taskActionRegistry: taskActionRegistry)
                self.purgeOld(currentBuildDescriptionPath: newDesc.packagePath)
            }
        }

        constructionDelegate.emit(data: Array("Build description signature: \(newDesc.signature.asString)\n".utf8), for: activity, signature: newDesc.signature)
        constructionDelegate.emit(data: Array("Build description path: \(newDesc.packagePath.str)\n".utf8), for: activity, signature: newDesc.signature)

        return (buildDescription: newDesc, source: .new)
    }

    private func serializeBuildDescription(_ buildDescription: BuildDescription, request: BuildPlanRequest, taskActionRegistry: TaskActionRegistry) {
        // Serialize the build description.
        let delegate = BuildDescriptionSerializerDelegate(taskActionRegistry: taskActionRegistry)
        let taskStoreSerializer = MsgPackSerializer(delegate: delegate)
        delegate.taskActionRegistry.withSerializationContext {
            taskStoreSerializer.serialize(buildDescription.taskStore)
        }
        let serializer = MsgPackSerializer(delegate: delegate)
        delegate.taskActionRegistry.withSerializationContext {
            serializer.serialize(buildDescription)
        }

        // Also get the target build graph's display representation.  In the future we would like to emit structured data (e.g. JSON) here instead, although perhaps with the display string embedded in it for human readability.
        let buildGraphString = request.buildGraph.dependencyGraphDiagnostic.formatLocalizedDescription(.debugWithoutBehaviorAndLocation)

        // Write the data to disk.
        do {
            try self.fs.createDirectory(buildDescription.packagePath)
            // The build description is the most important thing to write it first.
            try self.fs.write(buildDescription.serializedBuildDescriptionPath, contents: serializer.byteString)

            try self.fs.write(buildDescription.taskStorePath, contents: taskStoreSerializer.byteString)

            // Data which isn't essential - e.g. supporting artifacts - so we write them last because it's not a critical issue if they fail.
            try self.fs.write(buildDescription.targetGraphPath, contents: ByteString(encodingAsUTF8: buildGraphString))

            if let buildRequestJSON = request.buildRequest.jsonRepresentation {
                try self.fs.write(buildDescription.buildRequestPath, contents: ByteString(buildRequestJSON))
            }
        }
        catch {
            // Ignore errors - the failure case is that the description will be recreated for a later build if it's not still in memory.  This is a performance hit, but should only occur in strange cases (e.g., the cache directory is not writable, the disk is full, etc.) and is not (I hope) worth nagging the user about.
        }
    }

    /// Loads and returns a build description at the given path for a particular workspace. Throws a `DeserializerError` if it could not be read/deserialized.
    private func loadSerializedBuildDescription(_ path: Path, workspaceContext: WorkspaceContext, signature: BuildDescriptionSignature, taskActionRegistry: TaskActionRegistry) throws -> BuildDescription {
        let delegate = BuildDescriptionDeserializerDelegate(workspace: workspaceContext.workspace, platformRegistry: workspaceContext.core.platformRegistry, sdkRegistry: workspaceContext.core.sdkRegistry, specRegistry: workspaceContext.core.specRegistry, taskActionRegistry: taskActionRegistry)
        let taskStoreContents = try fs.read(path.join("task-store.msgpack"))
        let taskStoreDeserializer = MsgPackDeserializer(taskStoreContents, delegate: delegate)
        let taskStore: FrozenTaskStore = try delegate.taskActionRegistry.withSerializationContext {
            try taskStoreDeserializer.deserialize()
        }
        delegate.taskStore = taskStore
        let byteString = try fs.read(path.join("description.msgpack"))
        let deserializer = MsgPackDeserializer(byteString, delegate: delegate)
        let buildDescription: BuildDescription = try delegate.taskActionRegistry.withSerializationContext {
            try deserializer.deserialize()
        }

        // Correctness check: If the signature of the description we deserialized is different from the one we expected, then something has gone wrong.
        guard buildDescription.signature == signature else {
            throw DeserializerError.unexpectedValue("the signature of the deserialized description was not the expected one")
        }

        return buildDescription
    }

    /// Purge any old build descriptions and associated files, only keeping up to the maximum allowed cache size (`maxCacheSize.disk`).
    /// - remark: We don't pass in a delegate here because there's not really anything the user can do if we were unable to remove a build description, so reporting it isn't helpful.
    private func purgeOld(currentBuildDescriptionPath: Path) {
        let cacheDir = currentBuildDescriptionPath.dirname

        let allFiles: [String] = (try? fs.listdir(cacheDir)) ?? []
        var descriptions: [(description: String, modTime: Date)] = []
        for file in allFiles {
            guard file.hasSuffix(BuildDescription.bundleExtension) else {
                continue
            }

            let path = cacheDir.join(file)
            let stat = try? fs.getFileInfo(path)

            // If the stat failed, assume it's old
            let modTime = stat?.modificationDate ?? Date.distantPast

            descriptions.append((file, modTime))
        }

        guard descriptions.count > maxCacheSize.onDisk else {
            // Fewer descriptions than the allowed cache size, no need to remove any
            return
        }

        // Purge the oldest descriptions (outside of the allowed cache size)
        descriptions.sort(by: { a, b in a.modTime > b.modTime })
        let toPurge = Set(descriptions.suffix(from: maxCacheSize.onDisk).map { cacheDir.join($0.description) })
        for path in toPurge {
            // We don't report failures to remove a build description since they aren't user-actionable, and also the build request may have already been completed and therefore there is no usable diagnostic delegate to report it to (c.f. rdar://105457284).
            try? fs.removeDirectory(path)
        }
    }
}


// MARK:


/// The delegate for planning BuildSystem compatible tasks.
private final class BuildSystemTaskPlanningDelegate: TaskPlanningDelegate {
    private let diagnosticsEngines = LockedValue<[ConfiguredTarget?: DiagnosticsEngine]>([:])

    /// Queue for synchronizing access to shared state.
    let queue: SWBQueue

    let constructionDelegate: any BuildDescriptionConstructionDelegate

    let descriptionPath: Path

    let fileSystem: any FSProxy

    init(buildDescriptionPath: Path, _ clientDelegate: any TaskPlanningClientDelegate, constructionDelegate: any BuildDescriptionConstructionDelegate, qos: SWBQoS, fileSystem: any FSProxy) {
        self.descriptionPath = buildDescriptionPath
        self.clientDelegate = clientDelegate
        self.constructionDelegate = constructionDelegate
        self.queue = SWBQueue(label: "SWBTaskExecution.BuildSystemTaskPlanningDelegate.queue", qos: qos, autoreleaseFrequency: .workItem)
        self.fileSystem = fileSystem
    }

    // TaskPlanningDelegate

    func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        // Should this simply plumb through to the construction delegate?
        return .init(diagnosticsEngines.withLock { $0.getOrInsert(target, { DiagnosticsEngine() }) })
    }

    var diagnosticContext: DiagnosticContextData {
        // Should this simply plumb through to the construction delegate?
        return .init(target: nil)
    }

    var diagnostics: [ConfiguredTarget?: [Diagnostic]] {
        // Should this simply plumb through to the construction delegate?
        return diagnosticsEngines.withLock { $0.mapValues { $0.diagnostics } }
    }

    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID {
        constructionDelegate.beginActivity(ruleInfo: ruleInfo, executionDescription: executionDescription, signature: signature, target: target, parentActivity: parentActivity)
    }

    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) {
        constructionDelegate.endActivity(id: id, signature: signature, status: status)
    }

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) {
        constructionDelegate.emit(data: data, for: activity, signature: signature)
    }

    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
        constructionDelegate.emit(diagnostic: diagnostic, for: activity, signature: signature)
    }

    var hadErrors: Bool {
        constructionDelegate.hadErrors
    }

    var cancelled: Bool {
        return constructionDelegate.cancelled
    }

    func updateProgress(statusMessage: String, showInLog: Bool) {
        constructionDelegate.updateProgress(statusMessage: statusMessage, showInLog: showInLog)
    }

    func createVirtualNode(_ name: String) -> PlannedVirtualNode {
        return MakePlannedVirtualNode(name)
    }

    func createNode(absolutePath path: Path) -> PlannedPathNode {
        assert(path.isAbsolute)
        return MakePlannedPathNode(path)
    }

    func createDirectoryTreeNode(absolutePath path: Path) -> PlannedDirectoryTreeNode {
        return MakePlannedDirectoryTreeNode(path)
    }

    func createDirectoryTreeNode(absolutePath path: Path, excluding: [String]) -> PlannedDirectoryTreeNode {
        return MakePlannedDirectoryTreeNode(path, excluding: excluding)
    }

    func createBuildDirectoryNode(absolutePath path: Path) -> PlannedPathNode {
        createNode(absolutePath: path)
    }

    func createTask(_ builder: inout PlannedTaskBuilder) -> any PlannedTask {
        return ConstructedTask(&builder, execTask: Task(&builder))
    }

    /// Create a task that marks the entering of the group of tasks for a target.
    func createGateTask(_ inputs: [any PlannedNode], output: any PlannedNode, name: String, mustPrecede: [any PlannedTask], taskConfiguration: (inout PlannedTaskBuilder) -> Void) -> any PlannedTask {
        // Create a stub Task for the GateTask.
        var builder = PlannedTaskBuilder(type: GateTask.type, ruleInfo: ["Gate", name], commandLine: [], environment: EnvironmentBindings(), inputs: inputs, outputs: [output], mustPrecede: mustPrecede, enableSandboxing: false, repairViaOwnershipAnalysis: false)
        builder.preparesForIndexing = true
        builder.makeGate()
        taskConfiguration(&builder)
        return GateTask(&builder, execTask: Task(&builder))
    }

    package func recordAttachment(contents: SWBUtil.ByteString) -> SWBUtil.Path {
        let digester = InsecureHashContext()
        digester.add(bytes: contents)
        let path = descriptionPath.join("attachments").join(digester.signature.asString)
        do {
            try fileSystem.createDirectory(path.dirname, recursive: true)
            try fileSystem.write(path, contents: contents)
        } catch {
            constructionDelegate.emit(Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData("failed to save attachment: \(path.str)")))
        }
        return path
    }

    var taskActionCreationDelegate: any TaskActionCreationDelegate { return self }

    let clientDelegate: any TaskPlanningClientDelegate
}

extension BuildSystemTaskPlanningDelegate: TaskActionCreationDelegate {
    func createAuxiliaryFileTaskAction(_ context: AuxiliaryFileTaskActionContext) -> any PlannedTaskAction {
        return AuxiliaryFileTaskAction(context)
    }

    func createCodeSignTaskAction() -> any PlannedTaskAction {
        return CodeSignTaskAction()
    }

    func createConcatenateTaskAction() -> any PlannedTaskAction {
        return ConcatenateTaskAction()
    }

    func createCopyPlistTaskAction() -> any PlannedTaskAction {
        return CopyPlistTaskAction()
    }

    func createCopyStringsFileTaskAction() -> any PlannedTaskAction {
        return CopyStringsFileTaskAction()
    }

    func createCopyTiffTaskAction() -> any PlannedTaskAction {
        return CopyTiffTaskAction()
    }

    func createDeferredExecutionTaskAction() -> any SWBCore.PlannedTaskAction {
        return DeferredExecutionTaskAction()
    }

    func createBuildDirectoryTaskAction() -> any PlannedTaskAction {
        return CreateBuildDirectoryTaskAction()
    }

    func createSwiftHeaderToolTaskAction() -> any PlannedTaskAction {
        return SwiftHeaderToolTaskAction()
    }

    func createEmbedSwiftStdLibTaskAction() -> any PlannedTaskAction {
        return EmbedSwiftStdLibTaskAction()
    }

    func createFileCopyTaskAction(_ context: FileCopyTaskActionContext) -> any PlannedTaskAction {
        return FileCopyTaskAction(context)
    }

    func createGenericCachingTaskAction(enableCacheDebuggingRemarks: Bool, enableTaskSandboxEnforcement: Bool, sandboxDirectory: Path, extraSandboxSubdirectories: [Path], developerDirectory: Path, casOptions: CASOptions) -> any PlannedTaskAction {
        return GenericCachingTaskAction(enableCacheDebuggingRemarks: enableCacheDebuggingRemarks, enableTaskSandboxEnforcement: enableTaskSandboxEnforcement, sandboxDirectory: sandboxDirectory, extraSandboxSubdirectories: extraSandboxSubdirectories, developerDirectory: developerDirectory, casOptions: casOptions)
    }

    func createInfoPlistProcessorTaskAction(_ contextPath: Path) -> any PlannedTaskAction {
        return InfoPlistProcessorTaskAction(contextPath)
    }

    func createMergeInfoPlistTaskAction() -> any PlannedTaskAction {
        return MergeInfoPlistTaskAction()
    }

    func createLinkAssetCatalogTaskAction() -> any PlannedTaskAction {
        return LinkAssetCatalogTaskAction()
    }

    func createLSRegisterURLTaskAction() -> any PlannedTaskAction {
        return LSRegisterURLTaskAction()
    }

    func createProcessProductEntitlementsTaskAction(scope: MacroEvaluationScope, mergedEntitlements: PropertyListItem, entitlementsVariant: EntitlementsVariant, destinationPlatformName: String, entitlementsFilePath: Path?, fs: any FSProxy) -> any PlannedTaskAction {
        return ProcessProductEntitlementsTaskAction(scope: scope, fs: fs, entitlements: mergedEntitlements, entitlementsVariant: entitlementsVariant, destinationPlatformName: destinationPlatformName, entitlementsFilePath: entitlementsFilePath)
    }

    func createProcessProductProvisioningProfileTaskAction() -> any PlannedTaskAction {
        return ProcessProductProvisioningProfileTaskAction()
    }

    func createRegisterExecutionPolicyExceptionTaskAction() -> any PlannedTaskAction {
        return RegisterExecutionPolicyExceptionTaskAction()
    }

    func createValidateProductTaskAction() -> any PlannedTaskAction {
        return ValidateProductTaskAction()
    }

    func createConstructStubExecutorInputFileListTaskAction() -> any PlannedTaskAction {
        return ConstructStubExecutorInputFileListTaskAction()
    }

    func createODRAssetPackManifestTaskAction() -> any PlannedTaskAction {
        return ODRAssetPackManifestTaskAction()
    }

    func createClangCompileTaskAction() -> any PlannedTaskAction {
        return ClangCompileTaskAction()
    }

    func createClangScanTaskAction() -> any PlannedTaskAction {
        return ClangScanTaskAction()
    }

    func createSwiftDriverTaskAction() -> any PlannedTaskAction {
        return SwiftDriverTaskAction()
    }

    func createSwiftCompilationRequirementTaskAction() -> any PlannedTaskAction {
        return SwiftDriverCompilationRequirementTaskAction()
    }

    func createSwiftCompilationTaskAction() -> any PlannedTaskAction {
        return SwiftCompilationTaskAction()
    }

    func createProcessXCFrameworkTask() -> any PlannedTaskAction {
        return ProcessXCFrameworkTaskAction()
    }

    func createValidateDevelopmentAssetsTaskAction() -> any PlannedTaskAction {
        return ValidateDevelopmentAssetsTaskAction()
    }

    func createSignatureCollectionTaskAction() -> any PlannedTaskAction {
        return SignatureCollectionTaskAction()
    }

    func createClangModuleVerifierInputGeneratorTaskAction() -> any PlannedTaskAction {
        return ClangModuleVerifierInputGeneratorTaskAction()
    }

    func createProcessSDKImportsTaskAction() -> any PlannedTaskAction {
        return ProcessSDKImportsTaskAction()
    }
}

fileprivate extension BuildDescription {
    /// If the manifest backing a build description is gone, then the description is invalid. This happens, for example, if the build output directory is removed.  We also check whether the description has been invalidated due to changes to files on disk which contribute to the description.
    func isValidFor(request: BuildDescriptionManager.BuildDescriptionRequest, managerFS: any FSProxy) -> Bool {
        if request.isForCachedOnly {
            // Shortcut this since we already created the build description earlier. This makes the index queries more efficient.
            return true
        }

        // FIXME: This signature logic should be moved into the BuildDescription itself.
        let invalidationSignature = managerFS.filesSignature(invalidationPaths)
        if invalidationSignature != self.invalidationSignature {
            return false
        }

        // Validate the current recursive search path results, by reevaluating them and rerunning if they changed.
        //
        // FIXME: We could do this more optimally by also caching file system timestamp information.
        let resolver = RecursiveSearchPathResolver(fs: request.workspaceContext.fs)
        for cachedResult in recursiveSearchPathResults {
            if cachedResult.result != resolver.expandedPaths(for: cachedResult.request) {
                return false
            }
        }

        return managerFS.exists(dir) && managerFS.exists(manifestPath)
    }
}
