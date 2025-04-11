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

import SWBCore
import SWBUtil
import Synchronization

/// Tracks the XCFramework usage across the build plan. This allows the usage information to be cached during task planning.
final class XCFrameworkContext: Sendable {
    private struct Key: Hashable, Sendable {
        let path: Path
        let guid: ConfiguredTarget.GUID
    }

    struct XCFrameworkCopyConfiguration: Hashable, Sendable {
        /// Path of the `.xcframework` itself.
        package let path: Path
        package let platform: String
        package let environment: String?
        package let outputDirectory: Path
        package let libraryPath: Path
        package let outputs: [Path]
        package let expectedSignature: String?
    }

    private let workspaceContext: WorkspaceContext
    private let buildRequestContext: BuildRequestContext

    init(workspaceContext: WorkspaceContext, buildRequestContext: BuildRequestContext) {
        self.workspaceContext = workspaceContext
        self.buildRequestContext = buildRequestContext
    }

    private struct State {
        /// - Remark: This must only be modified during the `.taskGeneration` phase, where `targetPathKeys` is should no longer be changing.
        var copyConfigurations: [Key: XCFrameworkCopyConfiguration] = [:]

        var isFrozen = false
    }

    private let state = SWBMutex<State>(.init())

    /// Adds an xcframework to the cache.
    /// - Remark: This must only be used during the `.planning` phase.
    func add(_ path: Path, for target: ConfiguredTarget, expectedSignature: String?, _ block: (XCFramework) -> (XCFramework.Library, Path)?) throws {
        try state.withLock { state in
            precondition(!state.isFrozen)

            let xcframework = try buildRequestContext.getCachedXCFramework(at: path)

            if let (library, outputDirectory) = block(xcframework) {
                let outputs = try xcframework.copy(library: library, from: path, to: outputDirectory, fs: workspaceContext.fs, dryRun: true)
                state.copyConfigurations[Key(path: path, guid: target.guid)] = XCFrameworkCopyConfiguration(path: path, platform: library.supportedPlatform, environment: library.platformVariant, outputDirectory: outputDirectory, libraryPath: library.libraryPath, outputs: outputs, expectedSignature: expectedSignature)
            }
        }
    }

    /// Returns the list of output files from copying the XCFrameworks associated with the given `target`.
    /// - Remark: This must only be used during the `.taskGeneration` phase, where `targetPathKeys` is should no longer be changing.
    func outputFiles(xcframeworkPath: Path, target: ConfiguredTarget) -> [Path]? {
        return state.withLock { state in
            precondition(state.isFrozen)
            return state.copyConfigurations[Key(path: xcframeworkPath, guid: target.guid)]?.outputs
        }
    }

    /// Returns the list of output files from copying XCFrameworks associated with the given `target`.
    /// - Remark: This must only be used during the `.taskGeneration` phase, where `targetPathKeys` is should no longer be changing.
    func outputFiles(for target: ConfiguredTarget) -> [Path] {
        return state.withLock { state in
            precondition(state.isFrozen)
            return state.copyConfigurations.flatMap { (key, config) in key.guid == target.guid ? config.outputs : [] }
        }
    }

    /// Returns the set of metadata objects pertaining to the XCFrameworks to be copied into the build directory for the whole workspace.
    /// - Remark: This must only be used during the `.taskGeneration` phase, where `targetPathKeys` is should no longer be changing.
    var copyConfigurations: Set<XCFrameworkCopyConfiguration> {
        return state.withLock { state in
            precondition(state.isFrozen)
            return Set(state.copyConfigurations.values)
        }
    }

    func freeze() {
        return state.withLock { state in
            precondition(!state.isFrozen)
            state.isFrozen = true
        }
    }
}
