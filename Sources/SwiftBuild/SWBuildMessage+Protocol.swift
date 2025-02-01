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

import Foundation

import SWBProtocol
import SWBUtil

extension SwiftBuildMessage {
    init(_ message: PlanningOperationWillStart) {
        self = .planningOperationStarted(.init(planningOperationID: message.planningOperationHandle))
    }

    init(_ message: PlanningOperationDidFinish) {
        self = .planningOperationCompleted(.init(planningOperationID: message.planningOperationHandle))
    }

    init(_ message: BuildOperationReportBuildDescription) {
        self = .reportBuildDescription(.init(buildDescriptionID: message.buildDescriptionID))
    }

    init(_ message: BuildOperationReportPathMap) {
        self = try! .reportPathMap(.init(copiedPathMap: .init(message.copiedPathMap), generatedFilesPathMap: .init(message.generatedFilesPathMap)))
    }

    init(_ message: BuildOperationTargetPreparedForIndex) {
        self = .preparedForIndex(.init(targetGUID: message.targetGUID, resultInfo: .init(timestamp: message.info.timestamp)))
    }

    init(_ message: BuildOperationBacktraceFrameEmitted) {
        self = .backtraceFrame(.init(message))
    }

    init(_ message: BuildOperationStarted) {
        // FIXME: Supply real values for this; right now it's fine because Xcode doesn't use these, but SwiftPM does
        self = .buildStarted(.init(baseDirectory: .root, derivedDataPath: nil))
    }

    init(_ message: BuildOperationEnded) {
        let metrics: BuildOperationMetrics?
        if let messageMetrics = message.metrics, !messageMetrics.counters.isEmpty {
            metrics = .init(clangCacheHits: messageMetrics.counters[.clangCacheHits] ?? 0,
                            clangCacheMisses: messageMetrics.counters[.clangCacheMisses] ?? 0,
                            swiftCacheHits: messageMetrics.counters[.swiftCacheHits] ?? 0,
                            swiftCacheMisses: messageMetrics.counters[.swiftCacheMisses] ?? 0)
        } else {
            metrics = nil
        }
        self = .buildCompleted(.init(result: .init(message.status), metrics: metrics))
    }

    init(_ message: BuildOperationPreparationCompleted) {
        self = .preparationComplete(.init())
    }

    init(_ message: BuildOperationProgressUpdated) {
        self = .didUpdateProgress(.init(message: message.statusMessage, percentComplete: message.percentComplete, showInLog: message.showInLog, targetName: message.targetName))
    }

    init(_ message: BuildOperationTargetUpToDate) {
        self = .targetUpToDate(TargetUpToDateInfo(guid: message.guid))
    }

    init(_ message: BuildOperationTargetStarted) {
        self = .targetStarted(.init(targetID: message.id, targetGUID: message.guid, targetName: message.info.name, type: .init(message.info.typeName), projectName: message.info.projectInfo.name, projectPath: try! AbsolutePath(validating: message.info.projectInfo.path), projectIsPackage: message.info.projectInfo.isPackage, projectNameIsUniqueInWorkspace: message.info.projectInfo.isNameUniqueInWorkspace, configurationName: message.info.configurationName, configurationIsDefault: message.info.configurationIsDefault, sdkroot: message.info.sdkroot))
    }

    init(_ message: BuildOperationTargetEnded) {
        self = .targetComplete(.init(targetID: message.id))
    }

    init(_ message: BuildOperationTaskUpToDate) {
        self = .taskUpToDate(.init(targetID: message.targetID, taskSignature: message.signature.unsafeStringValue, parentTaskID: message.parentID))
    }

    init(_ message: BuildOperationTaskStarted) {
        self = .taskStarted(.init(taskID: message.id, targetID: message.targetID, taskSignature: message.info.signature.unsafeStringValue, parentTaskID: message.parentID, ruleInfo: message.info.ruleInfo, interestingPath: try! message.info.interestingPath.map { try AbsolutePath(validating: $0.str) } ?? nil, commandLineDisplayString: message.info.commandLineDisplayString, executionDescription: message.info.executionDescription, serializedDiagnosticsPaths: try! message.info.serializedDiagnosticsPaths.map { try AbsolutePath(validating: $0.str) }))
    }

    init(_ message: BuildOperationTaskEnded) {
        self = .taskComplete(.init(taskID: message.id, taskSignature: message.signature.rawValue.unsafeStringValue, result: .init(message.status), signalled: message.signalled, metrics: message.metrics.map { .init($0) }))
    }
}

extension Array where Element == SwiftBuildMessage {
    init(_ message: BuildOperationConsoleOutputEmitted) {
        self = [
            .output(.init(message)),
            {
                // FIXME: How to encode potentially non-UTF8 strings?
                let dataString = String(decoding: message.data, as: UTF8.self)
                if let targetID = message.targetID {
                    return .targetOutput(.init(targetID: targetID, data: dataString))
                } else if let taskID = message.taskID {
                    return .taskOutput(.init(taskID: taskID, data: dataString))
                } else {
                    return .buildOutput(.init(data: dataString))
                }
            }()
        ]
    }

    init(_ message: BuildOperationDiagnosticEmitted) {
        self = [
            .diagnostic(.init(message)),
            {
                // Also add the legacy version of the message
                switch message.locationContext {
                case let .task(taskID, signature, targetID):
                    return .taskDiagnostic(.init(taskID: taskID, taskSignature: signature.rawValue.unsafeStringValue, targetID: targetID, message: message.message))
                case let .globalTask(taskID, signature):
                    return .taskDiagnostic(.init(taskID: taskID, taskSignature: signature.rawValue.unsafeStringValue, targetID: nil, message: message.message))
                case let .target(targetID):
                    return .targetDiagnostic(.init(targetID: targetID, message: message.message))
                case .global:
                    return .buildDiagnostic(.init(message: message.message))
                }
            }()
        ]
    }
}

fileprivate extension Dictionary where Key == AbsolutePath, Value == AbsolutePath {
    init(_ other: [String: String]) throws {
        self = try Dictionary(uniqueKeysWithValues: other.map {
            try (AbsolutePath(validating: $0.key), AbsolutePath(validating: $0.value))
        })
    }
}

extension SwiftBuildMessage.TargetStartedInfo.Kind {
    init(_ type: BuildOperationTargetType) {
        switch type {
        case .aggregate:
            self = .aggregate
        case .external:
            self = .external
        case .packageProduct:
            self = .packageProduct
        case .standard:
            self = .native
        }
    }
}

extension SwiftBuildMessage.TaskCompleteInfo.Result {
    init(_ status: BuildOperationTaskEnded.Status) {
        switch status {
        case .succeeded:
            self = .success
        case .cancelled:
            self = .cancelled
        case .failed:
            self = .failed
        }
    }
}

extension SwiftBuildMessage.TaskCompleteInfo.Metrics {
    init(_ status: BuildOperationTaskEnded.Metrics) {
        self.init(utime: status.utime, stime: status.stime, maxRSS: status.maxRSS, wcStartTime: status.wcStartTime, wcDuration: status.wcDuration)
    }
}

extension SwiftBuildMessage.BuildCompletedInfo.Result {
    init(_ status: BuildOperationEnded.Status) {
        switch status {
        case .succeeded:
            self = .ok
        case .cancelled:
            self = .cancelled
        case .failed:
            self = .failed
        }
    }
}

extension SwiftBuildMessage.DiagnosticInfo {
    init(_ message: BuildOperationDiagnosticEmitted) {
        self = .init(kind: .init(message.kind), location: .init(message.location), locationContext: .init(message.locationContext), locationContext2: .init(message.locationContext), component: .init(message.component), message: message.message, optionName: message.optionName, appendToOutputStream: message.appendToOutputStream, childDiagnostics: message.childDiagnostics.map { .init($0) }, sourceRanges: message.sourceRanges.map { .init($0) }, fixIts: message.fixIts.map { .init($0) })
    }
}

extension SwiftBuildMessage.OutputInfo {
    init(_ message: BuildOperationConsoleOutputEmitted) {
        let locationContext: SwiftBuildMessage.LocationContext
        let locationContext2: SwiftBuildMessage.LocationContext2
        if let taskID = message.taskID {
            if let targetID = message.targetID {
                locationContext = .task(taskID: taskID, targetID: targetID)
            } else {
                locationContext = .globalTask(taskID: taskID)
            }
            locationContext2 = .init(targetID: message.targetID, taskSignature: message.taskSignature?.rawValue.unsafeStringValue)
        } else if let targetID = message.targetID {
            locationContext = .target(targetID: targetID)
            locationContext2 = .init(targetID: targetID, taskSignature: nil)
        } else {
            locationContext = .global
            locationContext2 = .init(targetID: nil, taskSignature: nil)
        }
        self = .init(data: Data(message.data), locationContext: locationContext, locationContext2: locationContext2)
    }
}

extension SwiftBuildMessage.DiagnosticInfo.Kind {
    init(_ behavior: BuildOperationDiagnosticEmitted.Kind) {
        switch behavior {
        case .error:
            self = .error
        case .warning:
            self = .warning
        case .note:
            self = .note
        case .remark:
            self = .remark
        }
    }
}

extension SwiftBuildMessage.DiagnosticInfo.Location {
    init(_ location: Diagnostic.Location) {
        switch location {
        case .unknown:
            self = .unknown
        case let .path(path, .textual(line, column)):
            self = .path(path.str, fileLocation: .textual(line: line, column: column))
        case let .path(path, .object(identifier)):
            self = .path(path.str, fileLocation: .object(identifier: identifier))
        case let .path(path, nil):
            self = .path(path.str, fileLocation: nil)
        case let .buildSettings(names):
            self = .buildSettings(names: names)
        case let .buildFiles(buildFiles, targetGUID):
            self = .buildFiles(buildFiles.map { .init($0) }, targetGUID: targetGUID)
        }
    }
}

extension SwiftBuildMessage.LocationContext {
    init(_ locationContext: BuildOperationDiagnosticEmitted.LocationContext) {
        switch locationContext {
        case let .task(taskID, _, targetID):
            self = .task(taskID: taskID, targetID: targetID)
        case let .globalTask(taskID, _):
            self = .globalTask(taskID: taskID)
        case let .target(targetID):
            self = .target(targetID: targetID)
        case .global:
            self = .global
        }
    }
}

extension SwiftBuildMessage.LocationContext2 {
    init(_ locationContext: BuildOperationDiagnosticEmitted.LocationContext) {
        switch locationContext {
        case let .task(_, signature, targetID):
            self.init(targetID: targetID, taskSignature: signature.rawValue.unsafeStringValue)
        case let .globalTask(_, signature):
            self.init(targetID: nil, taskSignature: signature.rawValue.unsafeStringValue)
        case let .target(targetID):
            self.init(targetID: targetID, taskSignature: nil)
        case .global:
            self.init(targetID: nil, taskSignature: nil)
        }
    }
}

extension SwiftBuildMessage.DiagnosticInfo.Component {
    init(_ component: Component) {
        switch component {
        case .default:
            self = .default
        case .packageResolution:
            self = .packageResolution
        case .targetIntegrity:
            self = .targetIntegrity
        case let .clangCompiler(categoryName):
            self = .clangCompiler(categoryName: categoryName)
        case .targetMissingUserApproval:
            self = .targetMissingUserApproval
        }
    }
}

extension SwiftBuildMessage.DiagnosticInfo.Location.BuildFileAndPhase {
    init(_ buildFileAndPhase: Diagnostic.Location.BuildFileAndPhase) {
        self.buildFileGUID = buildFileAndPhase.buildFileGUID
        self.buildPhaseGUID = buildFileAndPhase.buildPhaseGUID
    }
}

extension SwiftBuildMessage.DiagnosticInfo.SourceRange {
    init(_ sourceRange: Diagnostic.SourceRange) {
        self = .init(path: sourceRange.path.str, startLine: sourceRange.startLine, startColumn: sourceRange.startColumn, endLine: sourceRange.endLine, endColumn: sourceRange.endColumn)
    }
}

extension SwiftBuildMessage.DiagnosticInfo.FixIt {
    init(_ fixIt: Diagnostic.FixIt) {
        self = .init(sourceRange: .init(fixIt.sourceRange), textToInsert: fixIt.textToInsert)
    }
}
