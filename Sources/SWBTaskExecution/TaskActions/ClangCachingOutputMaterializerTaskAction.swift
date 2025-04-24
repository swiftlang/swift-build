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

public import SWBUtil
public import SWBCore
import Foundation

/// Used only when remote caching is enabled for downloading a compilation output,
/// using its ID, into the local CAS.
public final class ClangCachingOutputMaterializerTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "clang-caching-output-materializer"
    }

    private let key: ClangCachingOutputMaterializerTaskKey

    package init(key: ClangCachingOutputMaterializerTaskKey) {
        self.key = key
        super.init()
    }

    /// Network task so avoid blocking or being restricted by the execution lanes.
    override public var shouldExecuteDetached: Bool {
        return true
    }

    override public func performTaskAction(
        _ task: any ExecutableTask,
        dynamicExecutionDelegate: any DynamicTaskExecutionDelegate,
        executionDelegate: any TaskExecutionDelegate,
        clientDelegate: any TaskExecutionClientDelegate,
        outputDelegate: any TaskOutputDelegate
    ) async -> CommandResult {
        let clangModuleDependencyGraph = dynamicExecutionDelegate.operationContext.clangModuleDependencyGraph
        do  {
            guard let casDBs = try clangModuleDependencyGraph.getCASDatabases(
                libclangPath: key.libclangPath,
                casOptions: key.casOptions
            ) else {
                throw StubError.error("unable to use CAS databases")
            }

            let obj: ClangCASObject?
            do {
                obj = try await casDBs.loadObject(casID: key.casID)
            } catch {
                guard !key.casOptions.enableStrictCASErrors else { throw error }
                outputDelegate.warning(error.localizedDescription)
                obj = nil
            }
            if obj == nil {
                if key.casOptions.enableDiagnosticRemarks {
                    outputDelegate.note("missing CAS object: \(key.casID)")
                }
            }
            return .succeeded
        } catch {
            outputDelegate.error(error.localizedDescription)
            return .failed
        }
    }

    public override func cancelDetached() {
        // FIXME: Cancellation.
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(2)
        serializer.serialize(key)
        super.serialize(to: serializer)
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.key = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}
