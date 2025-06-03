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

package import SWBTestSupport
import SwiftBuild
package import SWBProtocol
import SWBTaskConstruction
@_spi(Testing) import SWBUtil
package import SWBCore
import SWBTaskExecution
package import SWBBuildSystem
package import Testing
import Foundation

extension BuildOperationTester.BuildResults {
    private func getBacktraceID(_ task: Task, sourceLocation: SourceLocation = #_sourceLocation) -> BuildOperationBacktraceFrameEmitted.Identifier? {
        guard let frameID: BuildOperationBacktraceFrameEmitted.Identifier = events.compactMap ({ (event) -> BuildOperationBacktraceFrameEmitted.Identifier? in
            guard case .emittedBuildBacktraceFrame(let frame) = event, case .task(let signature) = frame.identifier, BuildOperationTaskSignature.taskIdentifier(ByteString(encodingAsUTF8: task.identifier.rawValue)) == signature else {
                return nil
            }
            return frame.identifier
            // Iff the task is a dynamic task, there may be more than one corresponding frame if it was requested multiple times, in which case we choose the first. Non-dynamic tasks always have a 1-1 relationship with frames.
        }).sorted().first else {
            Issue.record("Did not find a single build backtrace frame for task: \(task.identifier)", sourceLocation: sourceLocation)
            return nil
        }
        return frameID
    }

    private func reconstructBacktrace(for identifier: BuildOperationBacktraceFrameEmitted.Identifier) -> SWBTaskBacktrace? {
        var collectedFrames = SWBBuildOperationCollectedBacktraceFrames()
        for event in self.events {
            if case .emittedBuildBacktraceFrame(let frame) = event {
                let wrappedFrame = SWBBuildOperationBacktraceFrame(frame)
                collectedFrames.add(frame: wrappedFrame)
            }
        }
        let backtrace = SWBTaskBacktrace(from: SWBBuildOperationBacktraceFrame.Identifier(messageIdentifier: identifier), collectedFrames: collectedFrames)
        return backtrace
    }

    package func checkBacktrace(_ identifier: BuildOperationBacktraceFrameEmitted.Identifier, _ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
        var frameDescriptions: [String] = []
        guard let backtrace = reconstructBacktrace(for: identifier) else {
            Issue.record("unable to reconstruct backtrace for \(identifier)")
            return
        }
        for frame in backtrace.frames {
            frameDescriptions.append("<category='\(frame.category)' description='\(frame.description)'>")
        }

        XCTAssertMatch(frameDescriptions, patterns, sourceLocation: sourceLocation)
    }

    package func checkBacktrace(_ task: Task, _ patterns: [StringPattern], sourceLocation: SourceLocation = #_sourceLocation) {
        if let frameID = getBacktraceID(task, sourceLocation: sourceLocation) {
            checkBacktrace(frameID, patterns, sourceLocation: sourceLocation)
        } else {
            // already recorded an issue
        }
    }

    package func checkNoTaskWithBacktraces(_ conditions: TaskCondition..., sourceLocation: SourceLocation = #_sourceLocation) {
        for matchedTask in findMatchingTasks(conditions) {
            Issue.record("found unexpected task matching conditions '\(conditions)', found: \(matchedTask)", sourceLocation: sourceLocation)

            if let frameID = getBacktraceID(matchedTask, sourceLocation: sourceLocation), let backtrace = reconstructBacktrace(for: frameID) {
                for frame in backtrace.frames {
                    Issue.record("...<category='\(frame.category)' description='\(frame.description)'>", sourceLocation: sourceLocation)
                }
            }
        }
    }

    package func checkTextualBacktrace(_ task: Task, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
        if let frameID = getBacktraceID(task, sourceLocation: sourceLocation), let backtrace = reconstructBacktrace(for: frameID) {
            #expect(backtrace.renderTextualRepresentation() == expected, sourceLocation: sourceLocation)
        } else {
            // already recorded an issue
        }
    }
}

extension BuildOperationTester {
    /// Ensure that the build is a null build.
    package func checkNullBuild(_ name: String? = nil, parameters: BuildParameters? = nil, runDestination: RunDestinationInfo?, buildRequest inputBuildRequest: BuildRequest? = nil, buildCommand: BuildCommand? = nil, schemeCommand: SchemeCommand? = .launch, persistent: Bool = false, serial: Bool = false, buildOutputMap: [String:String]? = nil, signableTargets: Set<String> = [], signableTargetInputs: [String: ProvisioningTaskInputs] = [:], clientDelegate: (any ClientDelegate)? = nil, excludedTasks: Set<String> = ["ClangStatCache", "LinkAssetCatalogSignature"], diagnosticsToValidate: Set<DiagnosticKind> = [.note, .error, .warning], sourceLocation: SourceLocation = #_sourceLocation) async throws {

        func body(results: BuildResults) throws -> Void {
            results.consumeTasksMatchingRuleTypes(excludedTasks)
            results.checkNoTaskWithBacktraces(sourceLocation: sourceLocation)

            results.checkNote(.equal("Building targets in dependency order"), failIfNotFound: false)
            results.checkNote(.prefix("Target dependency graph"), failIfNotFound: false)

            for kind in diagnosticsToValidate {
                switch kind {
                case .note:
                    results.checkNoNotes(sourceLocation: sourceLocation)

                case .warning:
                    results.checkNoWarnings(sourceLocation: sourceLocation)

                case .error:
                    results.checkNoErrors(sourceLocation: sourceLocation)

                case .remark:
                    results.checkNoRemarks(sourceLocation: sourceLocation)

                default:
                    // other kinds are ignored
                    break
                }
            }
        }

        try await UserDefaults.withEnvironment(["EnableBuildBacktraceRecording": "true"]) {
            try await checkBuild(name, parameters: parameters, runDestination: runDestination, buildRequest: inputBuildRequest, buildCommand: buildCommand, schemeCommand: schemeCommand, persistent: persistent, serial: serial, buildOutputMap: buildOutputMap, signableTargets: signableTargets, signableTargetInputs: signableTargetInputs, clientDelegate: clientDelegate, sourceLocation: sourceLocation, body: body)
        }
    }
}

extension SWBBuildOperationBacktraceFrame {
    init(_ message: BuildOperationBacktraceFrameEmitted) {
        let id = SWBBuildOperationBacktraceFrame.Identifier(messageIdentifier: message.identifier)
        let previousID = message.previousFrameIdentifier.map { SWBBuildOperationBacktraceFrame.Identifier(messageIdentifier: $0) }
        let category: SWBBuildOperationBacktraceFrame.Category
        switch message.category {
        case .ruleNeverBuilt:
            category = .ruleNeverBuilt
        case .ruleSignatureChanged:
            category = .ruleSignatureChanged
        case .ruleHadInvalidValue:
            category = .ruleHadInvalidValue
        case .ruleInputRebuilt:
            category = .ruleInputRebuilt
        case .ruleForced:
            category = .ruleForced
        case .dynamicTaskRegistration:
            category = .dynamicTaskRegistration
        case .dynamicTaskRequest:
            category = .dynamicTaskRequest
        case .none:
            category = .none
        }
        let kind: SWBBuildOperationBacktraceFrame.Kind
        switch message.kind {
        case .genericTask:
            kind = .genericTask
        case .swiftDriverJob:
            kind = .swiftDriverJob
        case .directory:
            kind = .directory
        case .file:
            kind = .file
        case .unknown:
            kind = .unknown
        case nil:
            kind = .unknown
        }
        self.init(identifier: id, previousFrameIdentifier: previousID, category: category, description: message.description, frameKind: kind)
    }
}

extension SWBBuildOperationBacktraceFrame.Identifier {
    init(messageIdentifier: BuildOperationBacktraceFrameEmitted.Identifier) {
        switch messageIdentifier {
        case .task(let signature):
            self.init(taskSignatureData: Data(signature.rawValue.bytes))!
        case .genericBuildKey(let id):
            self.init(genericBuildKey: id)
        }
    }
}
