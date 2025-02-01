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

public import struct SWBProtocol.BuildOperationTaskEnded
public import SWBUtil

/// Represents an abstract "activity" that occurs on behalf of the build. This may be a build task (subprocess execution) corresponding to Swift Build's `Task` abstractions, or a another non-task activity that occurs during the build planning process.
public struct ActivityID: RawRepresentable, Sendable, Hashable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

extension ActivityID {
    @TaskLocal public static var buildDescriptionActivity: ActivityID? = nil
}

public protocol ActivityReporter {
    /// Sends a started event for the specified activity.
    ///
    /// Must be paired with a corresponding `endActivity` call, though using `withActivity` is preferred where possible.
    func beginActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?) -> ActivityID

    /// Sends an ended event for the specified activity.
    ///
    /// Must be paired with a corresponding `beginActivity` call, though using `withActivity` is preferred where possible.
    func endActivity(id: ActivityID, signature: ByteString, status: BuildOperationTaskEnded.Status)

    func emit(data: [UInt8], for activity: ActivityID, signature: ByteString)
    func emit(diagnostic: Diagnostic, for activity: ActivityID, signature: ByteString)

    /// If any errors were reported to this delegate.
    var hadErrors: Bool { get }
}

public extension ActivityReporter {
    /// Convenience function which invokes `block` between calls to `beginActivity` and `endActivity`.
    func withActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?, block: (ActivityID) throws -> BuildOperationTaskEnded.Status) rethrows {
        let id = beginActivity(ruleInfo: ruleInfo, executionDescription: executionDescription, signature: signature, target: target, parentActivity: parentActivity)
        do {
            let status = try block(id)
            endActivity(id: id, signature: signature, status: status)
        } catch {
            let isCancelled = error is CancellationError
            endActivity(id: id, signature: signature, status: isCancelled ? .cancelled : .failed)
            throw error
        }
    }

    func withActivity(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?, block: (ActivityID) async throws -> BuildOperationTaskEnded.Status) async rethrows {
        let id = beginActivity(ruleInfo: ruleInfo, executionDescription: executionDescription, signature: signature, target: target, parentActivity: parentActivity)
        do {
            let status = try await block(id)
            endActivity(id: id, signature: signature, status: status)
        } catch {
            let isCancelled = error is CancellationError
            endActivity(id: id, signature: signature, status: isCancelled ? .cancelled : .failed)
            throw error
        }
    }

    /// Convenience function which invokes `block` between calls to `beginActivity` and `endActivity`.
    @discardableResult func withActivity<T>(ruleInfo: String, executionDescription: String, signature: ByteString, target: ConfiguredTarget?, parentActivity: ActivityID?, block: (ActivityID) async throws -> T) async rethrows -> T {
        let id = beginActivity(ruleInfo: ruleInfo, executionDescription: executionDescription, signature: signature, target: target, parentActivity: parentActivity)
        do {
            let result = try await block(id)
            endActivity(id: id, signature: signature, status: hadErrors ? .failed : .succeeded)
            return result
        } catch {
            let isCancelled = error is CancellationError
            endActivity(id: id, signature: signature, status: isCancelled ? .cancelled : .failed)
            throw error
        }
    }
}
