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
public final class SwiftCachingOutputMaterializerTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "swift-caching-output-materializer"
    }

    private let key: SwiftCachingOutputMaterializerTaskKey

    package init(key: SwiftCachingOutputMaterializerTaskKey) {
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
        let swiftModuleDependencyGraph = dynamicExecutionDelegate.operationContext.swiftModuleDependencyGraph
        do  {
            guard let cas = try swiftModuleDependencyGraph.getCASDatabases(casOptions: key.casOptions, compilerLocation: key.compilerLocation) else {
                throw StubError.error("unable to use CAS databases")
            }

            do {
                let loaded = try await cas.download(with: key.casID)
                if !loaded && key.casOptions.enableDiagnosticRemarks {
                    outputDelegate.note("cached output \(key.casID) not found")
                }
            } catch {
                guard !key.casOptions.enableStrictCASErrors else { throw error }
                outputDelegate.warning(error.localizedDescription)
                if key.casOptions.enableDiagnosticRemarks {
                    outputDelegate.note("cached output \(key.casID) downloading failed")
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

