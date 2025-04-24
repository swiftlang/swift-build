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

package import SWBCore
package import SWBTaskConstruction
package import SWBTaskExecution
package import SWBUtil
package import struct SWBProtocol.BuildDescriptionID
package import struct SWBProtocol.BuildOperationTaskEnded
package import struct SWBProtocol.TargetDependencyRelationship
import Synchronization

/// An empty delegate implementation.
package final class MockTestBuildDescriptionConstructionDelegate: BuildDescriptionConstructionDelegate, Sendable {
    package let diagnosticContext: DiagnosticContextData

    package func diagnosticsEngine(for target: ConfiguredTarget?) -> DiagnosticProducingDelegateProtocolPrivate<DiagnosticsEngine> {
        .init(diagnosticsEngines.withLock { $0.getOrInsert(target, { DiagnosticsEngine() }) })
    }

    package var diagnostics: [ConfiguredTarget? : [Diagnostic]] {
        diagnosticsEngines.withLock { $0.mapValues { $0.diagnostics } }
    }

    package var hadErrors: Bool {
        diagnosticsEngines.withLock { $0.contains(where: { _, engine in engine.hasErrors }) }
    }

    package let cancelled = false

    private let forPerf: Bool
    private let _manifest = SWBMutex<TestManifest?>(nil)
    package var manifest: TestManifest? {
        _manifest.withLock { $0 }
    }

    package func updateProgress(statusMessage: String, showInLog: Bool) {}

    package func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID { .init(rawValue: -1) }
    package func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status) { }
    package func emit(data: [UInt8], for activity: ActivityID, signature: ByteString) { }
    package func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString) {
        diagnosticsEngine(for: nil).emit(diagnostic) // FIXME: Technically this should be a "global task" diagnostic
    }

    package func emit(_ diagnostic: Diagnostic) {
        diagnosticsEngine(for: nil).emit(diagnostic)
    }

    package func buildDescriptionCreated(_ buildDescriptionID: BuildDescriptionID) {}

    private let diagnosticsEngines = LockedValue<[ConfiguredTarget?: DiagnosticsEngine]>(.init())

    /// - parameter forPerf: Pass `true` if this delegate is for a performance test.  This will skip recording the manifest to the delegate, as that could take significant time.
    package init(forPerf: Bool = false) {
        self.forPerf = forPerf
        self.diagnosticContext = DiagnosticContextData(target: nil)
    }

    package func recordManifest(targetDefinitions: [String: ByteString], toolDefinitions: [String: ByteString], nodeDefinitions: [String: ByteString], commandDefinitions: [String: ByteString]) throws {
        guard !forPerf else {
            return
        }
        try _manifest.withLock { manifest in
            manifest = try TestManifest(targetDefinitions: targetDefinitions, toolDefinitions: toolDefinitions, nodeDefinitions: nodeDefinitions, commandDefinitions: commandDefinitions)
        }
    }
}

/// A representation of the manifest data for testing purposes.
package struct TestManifest: Sendable {
    package let targetDefinitions: [String: PropertyListItem]
    package let toolDefinitions: [String: PropertyListItem]
    package let nodeDefinitions: [String: PropertyListItem]
    package let commandDefinitions: [String: PropertyListItem]

    package init(targetDefinitions: [String: ByteString], toolDefinitions: [String: ByteString], nodeDefinitions: [String: ByteString], commandDefinitions: [String: ByteString]) throws {
        self.targetDefinitions = try targetDefinitions.mapValues({ try PropertyList.fromJSONData($0) })
        self.toolDefinitions = try toolDefinitions.mapValues({ try PropertyList.fromJSONData($0) })
        self.nodeDefinitions = try nodeDefinitions.mapValues({ try PropertyList.fromJSONData($0) })
        self.commandDefinitions = try commandDefinitions.mapValues({ try PropertyList.fromJSONData($0) })
    }

}

extension BuildDescription {
    /// Convenience testing method which omits the `capturedBuildInfo:` parameter.
    static package func construct(workspace: Workspace, tasks: [any PlannedTask], path: Path, signature: BuildDescriptionSignature, buildCommand: BuildCommand, diagnostics: [ConfiguredTarget?: [Diagnostic]] = [:], indexingInfo: [(forTarget: ConfiguredTarget?, path: Path, indexingInfo: any SourceFileIndexingInfo)] = [], fs: any FSProxy = localFS, bypassActualTasks: Bool = false, moduleSessionFilePath: Path? = nil, invalidationPaths: [Path] = [], recursiveSearchPathResults: [RecursiveSearchPathResolver.CachedResult] = [], copiedPathMap: [String: String] = [:], rootPathsPerTarget: [ConfiguredTarget:[Path]] = [:], moduleCachePathsPerTarget: [ConfiguredTarget: [Path]] = [:], staleFileRemovalIdentifierPerTarget: [ConfiguredTarget: String] = [:], settingsPerTarget: [ConfiguredTarget: Settings] = [:], delegate: any BuildDescriptionConstructionDelegate, targetDependencies: [TargetDependencyRelationship] = [], definingTargetsByModuleName: [String: OrderedSet<ConfiguredTarget>] = [:]) async throws -> BuildDescription? {
        return try await construct(workspace: workspace, tasks: tasks, path: path, signature: signature, buildCommand: buildCommand, diagnostics: diagnostics, indexingInfo: indexingInfo, fs: fs, bypassActualTasks: bypassActualTasks, moduleSessionFilePath: moduleSessionFilePath, invalidationPaths: invalidationPaths, recursiveSearchPathResults: recursiveSearchPathResults, copiedPathMap: copiedPathMap, rootPathsPerTarget: rootPathsPerTarget, moduleCachePathsPerTarget: moduleCachePathsPerTarget, staleFileRemovalIdentifierPerTarget: staleFileRemovalIdentifierPerTarget, settingsPerTarget: settingsPerTarget, delegate: delegate, targetDependencies: targetDependencies, definingTargetsByModuleName: definingTargetsByModuleName, capturedBuildInfo: nil, userPreferences: .defaultForTesting)
    }
}

extension BuildDescriptionManager {
    package func getNewOrCachedBuildDescription(_ request: BuildPlanRequest, bypassActualTasks: Bool = false, clientDelegate: any TaskPlanningClientDelegate, constructionDelegate: any BuildDescriptionConstructionDelegate) async throws -> BuildDescriptionRetrievalInfo? {
        let descRequest = BuildDescriptionRequest.newOrCached(request, bypassActualTasks: bypassActualTasks, useSynchronousBuildDescriptionSerialization: true)
        return try await getNewOrCachedBuildDescription(descRequest, clientDelegate: clientDelegate, constructionDelegate: constructionDelegate)
    }
}
