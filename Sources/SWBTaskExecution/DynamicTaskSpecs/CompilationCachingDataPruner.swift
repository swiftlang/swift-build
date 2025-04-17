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
import SWBProtocol
package import SWBUtil
package import SWBCAS
import Foundation

package struct ClangCachingPruneDataTaskKey: Hashable, Serializable, CustomDebugStringConvertible, Sendable {
    let path: Path
    let casOptions: CASOptions

    init(path: Path, casOptions: CASOptions) {
        self.path = path
        self.casOptions = casOptions
    }

    package func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serializeAggregate(2) {
            serializer.serialize(path)
            serializer.serialize(casOptions)
        }
    }

    package init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        path = try deserializer.deserialize()
        casOptions = try deserializer.deserialize()
    }

    package var debugDescription: String {
        "<ClangCachingPruneDataTaskKey path=\(path) casOptions=\(casOptions)>"
    }
}

/// Manages the growth of the on-disk CAS by setting a size limit and pruning its data when necessary.
/// Each CAS instance will be attempted to be pruned once per build, but this happens concurrently
/// with the rest of the build and in a lower QoS priority. It is expected to have one pruning action
/// per used toolchain.
package final class CompilationCachingDataPruner: Sendable {
    /// Using a serial queue for doing the pruning actions, and with lower priority; no other task depends on them.
    private let queue: SWBQueue = .init(label: "SWBBuildService.CompilationCachingDataPruner", qos: .utility)
    private let group: SWBDispatchGroup = .init()

    private struct State: Sendable {
        var prunedCASes: Set<ClangCachingPruneDataTaskKey> = []
        var pendingActions: Int = 0
    }

    private let state: LockedValue<State> = .init(State())

    deinit {
        precondition(state.withLock { $0.pendingActions } == 0)
    }

    private func startedAction() {
        group.enter()
        state.withLock { $0.pendingActions += 1 }
    }

    private func finishedAction() {
        state.withLock { $0.pendingActions -= 1 }
        group.leave()
    }

    package func pruneCAS(
        _ casDBs: ClangCASDatabases,
        key: ClangCachingPruneDataTaskKey,
        activityReporter: any ActivityReporter,
        fileSystem fs: any FSProxy
    ) {
        let casOpts = key.casOptions
        guard casOpts.limitingStrategy != .discarded else {
            return // No need to prune, CAS directory is getting deleted.
        }
        let inserted = state.withLock { $0.prunedCASes.insert(key).inserted }
        guard inserted else {
            return // already pruned
        }

        startedAction()
        let serializer = MsgPackSerializer()
        key.serialize(to: serializer)
        let signatureCtx = InsecureHashContext()
        signatureCtx.add(string: "ClangCachingPruneData")
        signatureCtx.add(bytes: serializer.byteString)
        let signature = signatureCtx.signature

        let casPath = casOpts.casPath.str
        let libclangPath = key.path.str

        // Avoiding the swift concurrency variant because it may lead to starvation when `waitForCompletion()`
        // blocks on such tasks. Before using a swift concurrency task here make sure there's no deadlock
        // when setting `LIBDISPATCH_COOPERATIVE_POOL_STRICT`.
        queue.async {
            activityReporter.withActivity(
                ruleInfo: "ClangCachingPruneData \(casPath) \(libclangPath)",
                executionDescription: "Clang caching pruning \(casPath) using \(libclangPath)",
                signature: signature,
                target: nil,
                parentActivity: nil)
            { activityID in
                let status: BuildOperationTaskEnded.Status
                do {
                    let dbSize = try casDBs.getOndiskSize()
                    let sizeLimit = try computeCASSizeLimit(casOptions: casOpts, dbSize: dbSize, fileSystem: fs)
                    if let dbSize, let sizeLimit, sizeLimit < dbSize {
                        activityReporter.emit(
                            diagnostic: Diagnostic(
                                behavior: .note,
                                location: .unknown,
                                data: DiagnosticData("cache size (\(dbSize)) larger than size limit (\(sizeLimit))")
                            ),
                            for: activityID,
                            signature: signature
                        )
                    }
                    try casDBs.setOndiskSizeLimit(sizeLimit ?? 0)
                    try casDBs.pruneOndiskData()
                    status = .succeeded
                } catch {
                    activityReporter.emit(
                        diagnostic: Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData(error.localizedDescription)),
                        for: activityID,
                        signature: signature
                    )
                    status = .failed
                }
                return status
            }
            self.finishedAction()
        }
    }

    package func pruneCAS(
        _ casDBs: SwiftCASDatabases,
        key: ClangCachingPruneDataTaskKey,
        activityReporter: any ActivityReporter,
        fileSystem fs: any FSProxy
    ) {
        let casOpts = key.casOptions
        guard casOpts.limitingStrategy != .discarded else {
            return // No need to prune, CAS directory is getting deleted.
        }
        let inserted = state.withLock { $0.prunedCASes.insert(key).inserted }
        guard inserted else {
            return // already pruned
        }

        startedAction()
        let serializer = MsgPackSerializer()
        key.serialize(to: serializer)
        let signatureCtx = InsecureHashContext()
        signatureCtx.add(string: "SwiftCachingPruneData")
        signatureCtx.add(bytes: serializer.byteString)
        let signature = signatureCtx.signature

        let casPath = casOpts.casPath.str
        let swiftscanPath = key.path.str

        // Avoiding the swift concurrency variant because it may lead to starvation when `waitForCompletion()`
        // blocks on such tasks. Before using a swift concurrency task here make sure there's no deadlock
        // when setting `LIBDISPATCH_COOPERATIVE_POOL_STRICT`.
        queue.async {
            activityReporter.withActivity(
                ruleInfo: "SwiftCachingPruneData \(casPath) \(swiftscanPath)",
                executionDescription: "Swift caching pruning \(casPath) using \(swiftscanPath)",
                signature: signature,
                target: nil,
                parentActivity: nil)
            { activityID in
                let status: BuildOperationTaskEnded.Status
                do {
                    let dbSize = try casDBs.getStorageSize()
                    let sizeLimit = try computeCASSizeLimit(casOptions: casOpts, dbSize: dbSize.map{Int($0)}, fileSystem: fs)
                    if let dbSize, let sizeLimit, sizeLimit < dbSize {
                        activityReporter.emit(
                            diagnostic: Diagnostic(
                                behavior: .note,
                                location: .unknown,
                                data: DiagnosticData("cache size (\(dbSize)) larger than size limit (\(sizeLimit))")
                            ),
                            for: activityID,
                            signature: signature
                        )
                    }
                    try casDBs.setSizeLimit(Int64(sizeLimit ?? 0))
                    try casDBs.prune()
                    status = .succeeded
                } catch {
                    activityReporter.emit(
                        diagnostic: Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData(error.localizedDescription)),
                        for: activityID,
                        signature: signature
                    )
                    status = .failed
                }
                return status
            }
            self.finishedAction()
        }
    }

    package func pruneCAS(
        _ toolchainCAS: ToolchainCAS,
        key: ClangCachingPruneDataTaskKey,
        activityReporter: any ActivityReporter,
        fileSystem fs: any FSProxy
    ) {
        let casOpts = key.casOptions
        guard casOpts.limitingStrategy != .discarded else {
            return // No need to prune, CAS directory is getting deleted.
        }
        let inserted = state.withLock { $0.prunedCASes.insert(key).inserted }
        guard inserted else {
            return // already pruned
        }

        startedAction()
        let serializer = MsgPackSerializer()
        key.serialize(to: serializer)
        let signatureCtx = InsecureHashContext()
        signatureCtx.add(string: "ClangCachingPruneData")
        signatureCtx.add(bytes: serializer.byteString)
        let signature = signatureCtx.signature

        let casPath = casOpts.casPath.str
        let path = key.path.str

        // Avoiding the swift concurrency variant because it may lead to starvation when `waitForCompletion()`
        // blocks on such tasks. Before using a swift concurrency task here make sure there's no deadlock
        // when setting `LIBDISPATCH_COOPERATIVE_POOL_STRICT`.
        queue.async {
            activityReporter.withActivity(
                ruleInfo: "ClangCachingPruneData \(casPath) \(path)",
                executionDescription: "Pruning \(casPath) using \(path)",
                signature: signature,
                target: nil,
                parentActivity: nil)
            { activityID in
                let status: BuildOperationTaskEnded.Status
                do {
                    let dbSize = (try? toolchainCAS.getOnDiskSize()).map { Int($0) }
                    let sizeLimit = try computeCASSizeLimit(casOptions: casOpts, dbSize: dbSize, fileSystem: fs).map { Int64($0) }
                    if let dbSize, let sizeLimit, sizeLimit < dbSize {
                        activityReporter.emit(
                            diagnostic: Diagnostic(
                                behavior: .note,
                                location: .unknown,
                                data: DiagnosticData("cache size (\(dbSize)) larger than size limit (\(sizeLimit))")
                            ),
                            for: activityID,
                            signature: signature
                        )
                    }
                    try toolchainCAS.setOnDiskSizeLimit(sizeLimit ?? 0)
                    try toolchainCAS.prune()
                    status = .succeeded
                } catch {
                    activityReporter.emit(
                        diagnostic: Diagnostic(behavior: .error, location: .unknown, data: DiagnosticData(error.localizedDescription)),
                        for: activityID,
                        signature: signature
                    )
                    status = .failed
                }
                return status
            }
            self.finishedAction()
        }
    }

    package func waitForCompletion() async {
        await group.wait(queue: .global())
    }
}

fileprivate func computeCASSizeLimit(
    casOptions: CASOptions,
    dbSize: Int?,
    fileSystem fs: any FSProxy
) throws -> Int? {
    guard let dbSize else { return nil }
    switch casOptions.limitingStrategy {
    case .discarded:
        return nil
    case .maxSizeBytes(let size):
        return size
    case .maxPercentageOfAvailableSpace(var percent):
        guard percent > 0 else { return nil }
        percent = min(percent, 100)

        guard let freeSpace = try fs.getFreeDiskSpace(casOptions.casPath) else {
            return nil
        }
        let availableSpace = dbSize + freeSpace
        return availableSpace * percent / 100
    }
}
