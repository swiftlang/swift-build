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
import SWBUtil
import Foundation

#if canImport(os)
import os
#endif

/// Manages uploading compilation caching outputs in the background, when a remote cache is enabled.
/// The network tasks are managed using Swift concurrency, without blocking execution lanes
/// or being constrained by them.
///
/// FIXME: Ideally the uploading tasks would not block build completion, for example when doing
/// `xcodebuild test` uploading tasks could continue in the background while the tests start running.
/// This would require designing a way for the uploading tasks to be reported and entered in the result bundle
/// without being tied to a particular build.
///
/// FIXME: Implement cancellation functionality.
package final class CompilationCachingUploader {
    private let group: SWBDispatchGroup = .init()

    private let lock: Lock = .init()
    private var uploadedKeys: Set<String> = []
    private var pendingUploads: Int = 0

    deinit {
        precondition(pendingUploads == 0)
    }

    private func startedUpload() {
        group.enter()
        lock.withLock { pendingUploads += 1 }
    }

    private func finishedUpload() {
        lock.withLock { pendingUploads -= 1 }
        group.leave()
    }

    /// Schedule a cached compilation for uploading. The call will return immediately and the
    /// upload action will be performed in the background.
    /// If the `cacheKey` was already scheduled for uploading before the operation is a no-op.
    /// This is thread-safe.
    package func upload(
        clangCompilation: ClangCASCachedCompilation,
        cacheKey: String,
        enableDiagnosticRemarks: Bool,
        enableStrictCASErrors: Bool,
        activityReporter: any ActivityReporter
    ) {
        let inserted = lock.withLock { uploadedKeys.insert(cacheKey).inserted }
        guard inserted else {
            return // already uploaded
        }

        startedUpload()
        let signatureCtx = InsecureHashContext()
        signatureCtx.add(string: "ClangCachingUpload")
        signatureCtx.add(string: cacheKey)
        let signature = signatureCtx.signature

        let activityID = activityReporter.beginActivity(
            ruleInfo: "ClangCachingUpload \(cacheKey)",
            executionDescription: "Clang caching upload key \(cacheKey)",
            signature: signature,
            target: nil,
            parentActivity: nil
        )
        if enableDiagnosticRemarks {
            for output in clangCompilation.getOutputs() {
                activityReporter.emit(
                    diagnostic: Diagnostic(behavior: .note, location: .unknown, data: DiagnosticData("uploaded CAS output \(output.name): \(output.casID)")),
                    for: activityID,
                    signature: signature
                )
            }
        }

        // Avoiding the swift concurrency variant because it may lead to starvation when `waitForCompletion()`
        // blocks on such tasks. Before using a swift concurrency task here make sure there's no deadlock
        // when setting `LIBDISPATCH_COOPERATIVE_POOL_STRICT`.
        clangCompilation.makeGlobalAsync { error in
            let status: BuildOperationTaskEnded.Status
            if let error {
                activityReporter.emit(
                    diagnostic: Diagnostic(behavior: enableStrictCASErrors ? .error : .warning, location: .unknown, data: DiagnosticData(error.localizedDescription)),
                    for: activityID,
                    signature: signature
                )
                status = enableStrictCASErrors ? .failed : .succeeded
            } else {
                status = .succeeded
            }
            activityReporter.endActivity(
                id: activityID,
                signature: signature,
                status: status
            )
            self.finishedUpload()
        }
    }

    /// Schedule upload for swift compilation output
    package func upload(
        swiftCompilation: SwiftCachedCompilation,
        cacheKey: String,
        enableDiagnosticRemarks: Bool,
        enableStrictCASErrors: Bool,
        activityReporter: any ActivityReporter
    ) {
        let inserted = lock.withLock { uploadedKeys.insert(cacheKey).inserted }
        guard inserted else {
            return // already uploaded
        }

        startedUpload()
        let signatureCtx = InsecureHashContext()
        signatureCtx.add(string: "SwiftCachingUpload")
        signatureCtx.add(string: cacheKey)
        let signature = signatureCtx.signature

        let activityID = activityReporter.beginActivity(
            ruleInfo: "SwiftCachingUpload \(cacheKey)",
            executionDescription: "Swift caching upload key \(cacheKey)",
            signature: signature,
            target: nil,
            parentActivity: nil
        )

        do {
            if enableDiagnosticRemarks {
                for output in try swiftCompilation.getOutputs() {
                    activityReporter.emit(
                        diagnostic: Diagnostic(behavior: .note,
                                               location: .unknown,
                                               data: DiagnosticData("uploaded CAS output \(output.kindName): \(output.casID)")),
                        for: activityID,
                        signature: signature
                    )
                }
            }
        } catch {
            // failed to print remarks. warn about the returned error
            activityReporter.emit(
                diagnostic: Diagnostic(behavior: enableStrictCASErrors ? .error : .warning, location: .unknown, data: DiagnosticData(error.localizedDescription)),
                for: activityID,
                signature: signature
            )
        }

        // Avoiding the swift concurrency variant because it may lead to starvation when `waitForCompletion()`
        // blocks on such tasks. Before using a swift concurrency task here make sure there's no deadlock
        // when setting `LIBDISPATCH_COOPERATIVE_POOL_STRICT`.
        swiftCompilation.makeGlobal { error in
            let status: BuildOperationTaskEnded.Status
            if let error {
                activityReporter.emit(
                    diagnostic: Diagnostic(behavior: enableStrictCASErrors ? .error : .warning, location: .unknown, data: DiagnosticData(error.localizedDescription)),
                    for: activityID,
                    signature: signature
                )
                status = enableStrictCASErrors ? .failed : .succeeded
            } else {
                status = .succeeded
            }
            activityReporter.endActivity(
                id: activityID,
                signature: signature,
                status: status
            )
            self.finishedUpload()
        }
    }

    package func waitForCompletion() async {
        await group.wait(queue: .global())
    }
}
