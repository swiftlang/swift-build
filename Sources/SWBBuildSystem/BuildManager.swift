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

import struct Foundation.UUID

package import SWBCore
package import SWBTaskConstruction
package import SWBTaskExecution
import SWBUtil

/// Manages the set of active build operations.
///
/// There is typically a single shared manager for one service, so that the manager can coordinate build operations which are executing across multiple connected sessions.
package actor BuildManager {
    /// Active build operations, keyed by their UUID.
    private var operations = [UUID: any BuildSystemOperation]()

    /// A cache of active build systems, by database path (databases cannot be shared by multiple sessions currently).
    ///
    /// FIXME: We would like this to be automatically invalidate when the build description goes away, but this currently shouldn't ever be a major leak because we store at most one per database path.
    private let cachedBuildSystems: any BuildSystemCache

    /// Public initializer (so external clients can create new BuildManagers).
    package init() {
        self.cachedBuildSystems = HeavyCache<Path, SystemCacheEntry>(maximumSize: UserDefaults.buildDescriptionInMemoryCacheSize, evictionPolicy: .default(totalCostLimit: UserDefaults.buildDescriptionInMemoryCostLimit, willEvictCallback: { entry in
            // Capture the path to a local variable so that the buildDescription instance isn't retained by OSLog's autoclosure message parameter.
            let buildDatabasePath = entry.buildDescription?.buildDatabasePath
            #if canImport(os)
            OSLog.log("Evicted cached build system for '\(buildDatabasePath?.str ?? "<unknown>")'")
            #endif
        }))
    }

    /// Enqueue a build operation.
    ///
    /// The build will not actually be initiated until it has been requested to start.
    package nonisolated func enqueue(request: BuildRequest, buildRequestContext: BuildRequestContext, workspaceContext: WorkspaceContext, description: BuildDescription, operationDelegate: any BuildOperationDelegate, clientDelegate: any ClientDelegate) -> BuildOperation {

        let buildOnlyThesePaths: [Path]?
        switch request.buildCommand {
        case .generateAssemblyCode(let buildOnlyTheseFiles):
            buildOnlyThesePaths = buildOnlyTheseFiles
        case .generatePreprocessedFile(let buildOnlyTheseFiles):
            buildOnlyThesePaths = buildOnlyTheseFiles
        case .singleFileBuild(let buildOnlyTheseFiles):
            buildOnlyThesePaths = buildOnlyTheseFiles
        default:
            buildOnlyThesePaths = nil
        }

        let buildOutputMap: [String:String]?
        if let buildOnlyThesePaths {
            buildOutputMap = {
                var outputMap: [String: String] = [:]
                for target in request.buildTargets {
                    for buildOnlyThisPath in buildOnlyThesePaths {
                        for output in buildRequestContext.computeOutputPaths(for: buildOnlyThisPath, workspace: workspaceContext.workspace, target: target, command: request.buildCommand, parameters: request.parameters) {
                            if let existing = outputMap[output] {
                                // This shouldn't ever happen in practice, but we don't have a good way to emit an error from here.
                                assertionFailure("\(output) unexpectedly produced by both \(existing) and \(buildOnlyThisPath.str)")
                                return nil
                            }
                            outputMap[output] = buildOnlyThisPath.str
                        }
                    }
                }
                return outputMap
            }()
        } else {
            buildOutputMap = nil
        }

        let nodesToBuild = description.buildNodesToPrepareForIndex(buildRequest: request, buildRequestContext: buildRequestContext, workspaceContext: workspaceContext)

        return BuildOperation(request, buildRequestContext, description, environment: workspaceContext.userInfo?.processEnvironment, operationDelegate, clientDelegate, cachedBuildSystems, persistent: true, buildOutputMap: buildOutputMap, nodesToBuild: nodesToBuild, workspace: workspaceContext.workspace, core: workspaceContext.core, userPreferences: workspaceContext.userPreferences)
    }

    package nonisolated func enqueueClean(request buildRequest: BuildRequest, buildRequestContext: BuildRequestContext, workspaceContext: WorkspaceContext, style: BuildLocationStyle, operationDelegate: any BuildOperationDelegate, dependencyResolverDelegate: (any TargetDependencyResolverDelegate)?) -> CleanOperation {
        CleanOperation(buildRequest: buildRequest, buildRequestContext: buildRequestContext, workspaceContext: workspaceContext, style: style, delegate: operationDelegate, cachedBuildSystems: cachedBuildSystems, dependencyResolverDelegate: dependencyResolverDelegate)
    }

    /// Starts the build operation and suspends until its completion.
    package func runBuild(_ operation: any BuildSystemOperation) async {
        // Add the operation to the set of started operations, keyed by its UUID (which is what clients use whenever referencing it).
        precondition(operations[operation.uuid] == nil, "build already started")
        operations[operation.uuid] = operation

        // Enqueue the build to run.
        //
        // We currently are willing to enqueue any number of concurrent builds, with the expectation that the lower level build system will handle scheduling decisions across all active builds.
        //
        // FIXME: Make the lower-level build system actually do this, or do something else here (like dispatch one build at a time).
        // Execute the build.
        await operation.build()

        // Once the build is complete, de-register it.
        operations[operation.uuid] = nil
    }
}

/// The client delegate support delegation to the client for both task planning and task execution.
package protocol ClientDelegate: TaskPlanningClientDelegate, TaskExecutionClientDelegate {
}
