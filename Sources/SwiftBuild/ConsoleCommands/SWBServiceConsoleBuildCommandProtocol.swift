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

// NOTE: keep this in sync with Sources/XCBuildSupport/SwiftBuildMessage.swift in SwiftPM

public import Foundation
public import SWBProjectModel

import SWBUtil

public typealias BacktraceFrameInfo = SWBBuildOperationBacktraceFrame

/// Represents a message output by Swift Build.
public enum SwiftBuildMessage {
    /// Event indicating that the service is about to start a planning operation.
    public struct PlanningOperationStartedInfo {
        public let planningOperationID: String
    }

    /// Event indicating that the service finished running a planning operation.
    public struct PlanningOperationCompletedInfo {
        public let planningOperationID: String
    }

    public struct ReportBuildDescriptionInfo {
        public let buildDescriptionID: String
    }

    public struct ReportPathMapInfo {
        public let copiedPathMap: [AbsolutePath: AbsolutePath]
        public let generatedFilesPathMap: [AbsolutePath: AbsolutePath]
    }

    /// Wrapper for information provided about a 'prepare-for-index' operation.
    public struct PreparedForIndexInfo {
        public struct ResultInfo {
            /// The timestamp of the 'prepare-for-index' marker node.
            public let timestamp: Date
        }

        public let targetGUID: String
        public let resultInfo: ResultInfo
    }

    public enum LocationContext {
        case task(taskID: Int, targetID: Int)
        case target(targetID: Int)
        case globalTask(taskID: Int)
        case global
    }

    public struct LocationContext2 {
        // Consider replacing with a target signature in the future.
        public let targetID: Int?
        public let taskSignature: String?
    }

    /// Wrapper for information provided about a diagnostic during the build.
    public struct DiagnosticInfo {
        public enum Kind: String {
            case note
            case warning
            case error
            case remark
        }

        public let kind: Kind

        public enum Location {
            public enum FileLocation {
                /// Represents an absolute line/column location within a file.
                /// - parameter line: The line number associated with the diagnostic, if known.
                /// - parameter column: The column number associated with the diagnostic, if known.
                case textual(line: Int, column: Int?)

                /// Represents a file path diagnostic location with a semantic object identifier.
                /// - parameter path: The file path associated with the diagnostic.
                /// - parameter identifier: An opaque string identifying the object.
                case object(identifier: String)
            }

            /// Represents an unknown diagnostic location.
            case unknown

            /// Represents a file diagnostic location.
            /// - parameter path: The file path associated with the diagnostic.
            /// - parameter fileLocation: The logical location within the file.
            case path(_ path: String, fileLocation: FileLocation?)

            /// Represents a build settings diagnostic location.
            /// - parameter names: The names of the build settings associated with the diagnostic.
            case buildSettings(names: [String])

            public struct BuildFileAndPhase {
                public let buildFileGUID: String
                public let buildPhaseGUID: String
            }

            /// Represents a build file diagnostic location, within a particular target and project.
            case buildFiles(_ buildFiles: [BuildFileAndPhase], targetGUID: String)
        }

        public let location: Location

        @available(*, deprecated, message: "Use locationContext2 instead")
        public let locationContext: LocationContext
        public let locationContext2: LocationContext2

        public enum Component {
            case `default`
            case packageResolution
            case targetIntegrity
            case clangCompiler(categoryName: String)
            case targetMissingUserApproval
        }

        public let component: Component
        public let message: String
        public let optionName: String?
        public let appendToOutputStream: Bool
        public let childDiagnostics: [DiagnosticInfo]

        public struct SourceRange {
            public let path: String
            public let startLine: Int
            public let startColumn: Int
            public let endLine: Int
            public let endColumn: Int
        }

        public let sourceRanges: [SourceRange]

        public struct FixIt {
            /// The location of the fix.  May be an empty location (start and end locations the same) for pure insert.
            public let sourceRange: SourceRange

            /// The new text to replace the range.  May be an empty string for pure delete.
            public let textToInsert: String
        }

        public let fixIts: [FixIt]
    }

    public struct OutputInfo {
        public let data: Data

        @available(*, deprecated, message: "Use locationContext2 instead")
        public let locationContext: LocationContext
        public let locationContext2: LocationContext2
    }

    public struct BuildStartedInfo {
        public let baseDirectory: AbsolutePath
        public let derivedDataPath: AbsolutePath?
    }

    public struct BuildDiagnosticInfo {
        public let message: String
    }

    public struct BuildOperationMetrics {
        let clangCacheHits: Int
        let clangCacheMisses: Int
        let swiftCacheHits: Int
        let swiftCacheMisses: Int
    }

    public struct BuildCompletedInfo {
        public enum Result: String {
            case ok
            case failed
            case cancelled
            case aborted
        }

        public let result: Result
        public let metrics: BuildOperationMetrics?
    }

    public struct BuildOutputInfo {
        public let data: String
    }

    /// Event indicating that the "build preparation" phase is complete.
    public struct PreparationCompleteInfo {
    }

    /// Event indicating a high-level status message and percentage completion across the entire build operation, suitable for display in a user interface.
    public struct DidUpdateProgressInfo {
        public let message: String
        public let percentComplete: Double
        public let showInLog: Bool
        public let targetName: String?
    }

    /// Event indicating that a target was already up to date and did not need to be built.
    public struct TargetUpToDateInfo {
        public let guid: PIF.GUID
    }

    /// Event indicating that a target has started building.
    public struct TargetStartedInfo {
        public enum Kind: String {
            case native = "Native"
            case aggregate = "Aggregate"
            case external = "External"
            case packageProduct = "Package Product"
        }

        /// An opaque ID to identify the target in subsequent events.
        public let targetID: Int

        /// The GUID of the target being started.
        public let targetGUID: PIF.GUID

        /// The name of the target.
        public let targetName: String

        /// The type of the target being built.
        public let type: Kind

        /// The name of the project containing the target.
        public let projectName: String

        /// The path of the project wrapper (for example, `.xcodeproj`) containing the target.
        public let projectPath: AbsolutePath

        /// Whether this project represents a Swift package.
        public let projectIsPackage: Bool

        /// Whether the project's name is unique across the whole workspace.
        ///
        /// This can be used to determine whether diagnostic messages should attempt to additionally disambiguate the project name by path.
        public let projectNameIsUniqueInWorkspace: Bool

        /// The name of the configuration chosen to build.
        public let configurationName: String

        /// Whether or not the configuration was the default one.
        public let configurationIsDefault: Bool

        /// The canonical name of the SDK in use, if any.
        public let sdkroot: String?
    }

    public struct TargetOutputInfo {
        public let targetID: Int
        public let data: String
    }

    /// Event indicating that a target has finished building.
    public struct TargetCompleteInfo {
        public let targetID: Int
    }

    /// Event indicating that a task was already up to date and did not need to be built.
    ///
    /// This method is *only* called for targets which have some tasks run; targets which are entirely up-to-date will merely receive a ``TargetUpToDateInfo`` event.
    ///
    /// Otherwise, this message will be received in the order in which the task would have been run in some valid ordering of a target's tasks.
    public struct TaskUpToDateInfo {
        public let targetID: Int?
        public let taskSignature: String
        public let parentTaskID: Int?
    }

    /// Event indicating that a task has started building.
    ///
    /// This task may be a top-level task within a target, or it may be a subtask of an existing task (if a parent ID is provided), or it may be a global task that is not associated with any target at all.
    public struct TaskStartedInfo {
        /// An opaque ID to identify the task in subsequent events.
        public let taskID: Int

        /// An opaque ID indicating the target that the task is operating on behalf of, if any.
        public let targetID: Int?

        /// A unique signature to represent this task within its target.
        ///
        /// This signature is only valid for comparing with a ``TaskUpToDateInfo`` message across build operations, and should not be inspected.
        public let taskSignature: String

        /// An opaque ID identifying the parent task, if any.
        public let parentTaskID: Int?

        /// The rule info of the task.
        public let ruleInfo: String

        /// Any interesting path related to the task, for e.g. the file being compiled.
        public let interestingPath: AbsolutePath?

        /// The string to display describing the command line, if any.
        public let commandLineDisplayString: String?

        /// The execution description.
        public let executionDescription: String

        /// The set of paths to clang-format serialized diagnostics files, if used.
        public let serializedDiagnosticsPaths: [AbsolutePath]
    }

    public struct TaskDiagnosticInfo {
        public let taskID: Int
        public let taskSignature: String
        public let targetID: Int?
        public let message: String
    }

    public struct TaskOutputInfo {
        public let taskID: Int
        public let data: String
    }

    /// Event indicating that a task has finished building.
    public struct TaskCompleteInfo {
        public enum Result: String {
            case success
            case failed
            case cancelled
        }

        public struct Metrics {
            public let utime: UInt64
            public let stime: UInt64
            public let maxRSS: UInt64
            public let wcStartTime: UInt64
            public let wcDuration: UInt64
        }

        public let taskID: Int
        public let taskSignature: String
        public let result: Result
        public let signalled: Bool
        public let metrics: Metrics?
    }

    public struct TargetDiagnosticInfo {
        public let targetID: Int
        public let message: String
    }

    case planningOperationStarted(PlanningOperationStartedInfo)
    case planningOperationCompleted(PlanningOperationCompletedInfo)
    case reportBuildDescription(ReportBuildDescriptionInfo)
    case reportPathMap(ReportPathMapInfo)
    case preparedForIndex(PreparedForIndexInfo)
    case backtraceFrame(BacktraceFrameInfo)
    case buildStarted(BuildStartedInfo)
    case buildDiagnostic(BuildDiagnosticInfo)
    case buildCompleted(BuildCompletedInfo)
    case buildOutput(BuildOutputInfo)
    case preparationComplete(PreparationCompleteInfo)
    case didUpdateProgress(DidUpdateProgressInfo)
    case targetUpToDate(TargetUpToDateInfo)
    case targetStarted(TargetStartedInfo)
    case targetOutput(TargetOutputInfo)
    case targetComplete(TargetCompleteInfo)
    case taskUpToDate(TaskUpToDateInfo)
    case taskStarted(TaskStartedInfo)
    case taskDiagnostic(TaskDiagnosticInfo)
    case taskOutput(TaskOutputInfo)
    case taskComplete(TaskCompleteInfo)
    case targetDiagnostic(TargetDiagnosticInfo)
    case diagnostic(DiagnosticInfo)
    case output(OutputInfo)
}

extension SwiftBuildMessage.DiagnosticInfo.Kind: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.DiagnosticInfo.Location.BuildFileAndPhase: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.DiagnosticInfo.Location.FileLocation: Equatable, Sendable {}

extension SwiftBuildMessage.DiagnosticInfo.Location: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case locationType

        case path
        case line
        case column
        case identifier

        case names

        case buildFiles
        case targetGUID
    }

    private enum LocationType: String, Codable {
        case unknown
        case path
        case buildSettings
        case buildFiles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(LocationType.self, forKey: .locationType) {
        case .unknown:
            self = .unknown
        case .path:
            let path = try container.decode(String.self, forKey: .path)
            let line = try container.decodeIfPresent(Int.self, forKey: .line)
            let column = try container.decodeIfPresent(Int.self, forKey: .column)
            let identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            switch (identifier, line, column) {
            case (let identifier?, nil, nil):
                self = .path(path, fileLocation: .object(identifier: identifier))
            case (nil, let line?, let column):
                self = .path(path, fileLocation: .textual(line: line, column: column))
            case (nil, nil, nil):
                self = .path(path, fileLocation: nil)
            default:
                throw DecodingError.dataCorruptedError(forKey: .path, in: container, debugDescription: "invalid path location properties")
            }
        case .buildSettings:
            let names = try container.decode([String].self, forKey: .names)
            self = .buildSettings(names: names)
        case .buildFiles:
            let buildFiles = try container.decode([BuildFileAndPhase].self, forKey: .buildFiles)
            let targetGUID = try container.decode(String.self, forKey: .targetGUID)
            self = .buildFiles(buildFiles, targetGUID: targetGUID)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknown:
            try container.encode(LocationType.unknown, forKey: .locationType)
        case let .path(path, fileLocation):
            try container.encode(LocationType.path, forKey: .locationType)
            try container.encode(path, forKey: .path)
            switch fileLocation {
            case let .textual(line, column):
                try container.encode(line, forKey: .line)
                try container.encodeIfPresent(column, forKey: .column)
            case let .object(identifier):
                try container.encode(identifier, forKey: .identifier)
            case .none:
                break
            }
        case let .buildSettings(names):
            try container.encode(LocationType.buildSettings, forKey: .locationType)
            try container.encode(names, forKey: .names)
        case let .buildFiles(buildFiles, targetGUID):
            try container.encode(LocationType.buildFiles, forKey: .locationType)
            try container.encode(buildFiles, forKey: .buildFiles)
            try container.encode(targetGUID, forKey: .targetGUID)
        }
    }
}

extension SwiftBuildMessage.LocationContext: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case locationType

        case taskID
        case targetID
    }

    private enum LocationType: String, Codable {
        case task
        case target
        case globalTask
        case global
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(LocationType.self, forKey: .locationType) {
        case .task:
            self = try .task(
                taskID: container.decode(Int.self, forKey: .taskID),
                targetID: container.decode(Int.self, forKey: .targetID))
        case .target:
            self = try .target(targetID: container.decode(Int.self, forKey: .targetID))
        case .globalTask:
            self = try .globalTask(taskID: container.decode(Int.self, forKey: .taskID))
        case .global:
            self = .global
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .task(taskID, targetID):
            try container.encode(LocationType.task, forKey: .locationType)
            try container.encode(taskID, forKey: .taskID)
            try container.encode(targetID, forKey: .targetID)
        case let .target(targetID):
            try container.encode(LocationType.target, forKey: .locationType)
            try container.encode(targetID, forKey: .targetID)
        case let .globalTask(taskID):
            try container.encode(LocationType.globalTask, forKey: .locationType)
            try container.encode(taskID, forKey: .taskID)
        case .global:
            try container.encode(LocationType.global, forKey: .locationType)
        }
    }
}

extension SwiftBuildMessage.LocationContext2: Codable, Equatable, Sendable {}

extension SwiftBuildMessage.DiagnosticInfo.Component: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case componentType
        case categoryName
    }

    private enum ComponentType: String, Codable {
        case `default`
        case packageResolution
        case targetIntegrity
        case clangCompiler
        case targetMissingUserApproval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ComponentType.self, forKey: .componentType) {
        case .`default`:
            self = .`default`
        case .packageResolution:
            self = .packageResolution
        case .targetIntegrity:
            self = .targetIntegrity
        case .clangCompiler:
            self = try .clangCompiler(categoryName: container.decode(String.self, forKey: .categoryName))
        case .targetMissingUserApproval:
            self = .targetMissingUserApproval
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .`default`:
            try container.encode(ComponentType.default, forKey: .componentType)
        case .packageResolution:
            try container.encode(ComponentType.packageResolution, forKey: .componentType)
        case .targetIntegrity:
            try container.encode(ComponentType.targetIntegrity, forKey: .componentType)
        case let .clangCompiler(categoryName):
            try container.encode(ComponentType.clangCompiler, forKey: .componentType)
            try container.encode(categoryName, forKey: .categoryName)
        case .targetMissingUserApproval:
            try container.encode(ComponentType.targetMissingUserApproval, forKey: .componentType)
        }
    }
}

extension SwiftBuildMessage.DiagnosticInfo.SourceRange: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.DiagnosticInfo.FixIt: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.DiagnosticInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.OutputInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.BuildStartedInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.BuildDiagnosticInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.BuildOperationMetrics: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.BuildCompletedInfo.Result: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.BuildCompletedInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.BuildOutputInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.TargetUpToDateInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.TaskDiagnosticInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.TargetDiagnosticInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.PreparationCompleteInfo: Codable, Equatable, Sendable {}

extension SwiftBuildMessage.DidUpdateProgressInfo: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case message
        case percentComplete
        case showInLog
        case targetName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        percentComplete = try container.decodeDoubleOrString(forKey: .percentComplete)
        showInLog = try container.decodeBoolOrString(forKey: .showInLog)
        targetName = try container.decodeIfPresent(String.self, forKey: .targetName)
    }
}

extension SwiftBuildMessage.TargetStartedInfo.Kind: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.TargetStartedInfo: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case targetID = "id"
        case targetGUID = "guid"
        case targetName = "name"
        case type
        case projectName
        case projectPath
        case projectIsPackage
        case projectNameIsUniqueInWorkspace
        case configurationName
        case configurationIsDefault
        case sdkroot
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetID = try container.decodeIntOrString(forKey: .targetID)
        targetGUID = try container.decode(PIF.GUID.self, forKey: .targetGUID)
        targetName = try container.decode(String.self, forKey: .targetName)
        type = try container.decode(Kind.self, forKey: .type)
        projectName = try container.decode(String.self, forKey: .projectName)
        projectPath = try container.decode(AbsolutePath.self, forKey: .projectPath)
        projectIsPackage = try container.decode(Bool.self, forKey: .projectIsPackage)
        projectNameIsUniqueInWorkspace = try container.decode(Bool.self, forKey: .projectNameIsUniqueInWorkspace)
        configurationName = try container.decode(String.self, forKey: .configurationName)
        configurationIsDefault = try container.decode(Bool.self, forKey: .configurationIsDefault)
        sdkroot = try container.decodeIfPresent(String.self, forKey: .sdkroot)
    }
}

extension SwiftBuildMessage.TargetOutputInfo: Codable, Equatable, Sendable {}

extension SwiftBuildMessage.TargetCompleteInfo: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case targetID = "id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetID = try container.decodeIntOrString(forKey: .targetID)
    }
}

extension SwiftBuildMessage.TaskUpToDateInfo: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case targetID
        case taskSignature = "signature"
        case parentTaskID = "parentID"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        targetID = try container.decodeIntOrStringIfPresent(forKey: .targetID)
        taskSignature = try container.decode(String.self, forKey: .taskSignature)
        parentTaskID = try container.decodeIntOrStringIfPresent(forKey: .parentTaskID)
    }
}

extension SwiftBuildMessage.TaskStartedInfo: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case taskID = "id"
        case targetID
        case taskSignature = "signature"
        case parentTaskID = "parentID"
        case ruleInfo
        case interestingPath
        case commandLineDisplayString
        case executionDescription
        case serializedDiagnosticsPaths
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decodeIntOrString(forKey: .taskID)
        targetID = try container.decodeIntOrStringIfPresent(forKey: .targetID)
        taskSignature = try container.decode(String.self, forKey: .taskSignature)
        parentTaskID = try container.decodeIntOrStringIfPresent(forKey: .parentTaskID)
        ruleInfo = try container.decode(String.self, forKey: .ruleInfo)
        interestingPath = try AbsolutePath(validatingOrNilIfEmpty: container.decodeIfPresent(String.self, forKey: .interestingPath))
        commandLineDisplayString = try container.decodeIfPresent(String.self, forKey: .commandLineDisplayString)
        executionDescription = try container.decode(String.self, forKey: .executionDescription)
        serializedDiagnosticsPaths = try container.decodeIfPresent([AbsolutePath].self, forKey: .serializedDiagnosticsPaths) ?? []
    }
}

extension SwiftBuildMessage.TaskOutputInfo: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case taskID
        case data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decodeIntOrString(forKey: .taskID)
        data = try container.decode(String.self, forKey: .data)
    }
}

extension SwiftBuildMessage.TaskCompleteInfo.Result: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.TaskCompleteInfo.Metrics: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.TaskCompleteInfo: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case taskID = "id"
        case taskSignature = "signature"
        case result
        case signalled
        case metrics
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decodeIntOrString(forKey: .taskID)
        taskSignature = try container.decode(String.self, forKey: .taskSignature)
        result = try container.decode(Result.self, forKey: .result)
        signalled = try container.decode(Bool.self, forKey: .signalled)
        metrics = try container.decodeIfPresent(Metrics.self, forKey: .metrics)
    }
}

extension SwiftBuildMessage.PlanningOperationStartedInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.PlanningOperationCompletedInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.ReportBuildDescriptionInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.ReportPathMapInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.PreparedForIndexInfo: Codable, Equatable, Sendable {}
extension SwiftBuildMessage.PreparedForIndexInfo.ResultInfo: Codable, Equatable, Sendable {}

extension SwiftBuildMessage: Codable, Equatable, Sendable {
    enum CodingKeys: CodingKey {
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "buildStarted":
            self = try .buildStarted(BuildStartedInfo(from: decoder))
        case "buildDiagnostic":
            self = try .buildDiagnostic(BuildDiagnosticInfo(from: decoder))
        case "buildCompleted":
            self = try .buildCompleted(BuildCompletedInfo(from: decoder))
        case "buildOutput":
            self = try .buildOutput(BuildOutputInfo(from: decoder))
        case "preparationComplete":
            self = try .preparationComplete(PreparationCompleteInfo(from: decoder))
        case "didUpdateProgress":
            self = try .didUpdateProgress(DidUpdateProgressInfo(from: decoder))
        case "targetUpToDate":
            self = try .targetUpToDate(TargetUpToDateInfo(from: decoder))
        case "targetStarted":
            self = try .targetStarted(TargetStartedInfo(from: decoder))
        case "targetOutput":
            self = try .targetOutput(TargetOutputInfo(from: decoder))
        case "targetComplete":
            self = try .targetComplete(TargetCompleteInfo(from: decoder))
        case "taskUpToDate":
            self = try .taskUpToDate(TaskUpToDateInfo(from: decoder))
        case "taskStarted":
            self = try .taskStarted(TaskStartedInfo(from: decoder))
        case "taskDiagnostic":
            self = try .taskDiagnostic(TaskDiagnosticInfo(from: decoder))
        case "taskOutput":
            self = try .taskOutput(TaskOutputInfo(from: decoder))
        case "taskComplete":
            self = try .taskComplete(TaskCompleteInfo(from: decoder))
        case "targetDiagnostic":
            self = try .targetDiagnostic(TargetDiagnosticInfo(from: decoder))
        case "diagnostic":
            self = try .diagnostic(DiagnosticInfo(from: decoder))
        case "planningOperationStarted":
            self = try .planningOperationStarted(PlanningOperationStartedInfo(from: decoder))
        case "planningOperationCompleted":
            self = try .planningOperationCompleted(PlanningOperationCompletedInfo(from: decoder))
        case "reportBuildDescription":
            self = try .reportBuildDescription(ReportBuildDescriptionInfo(from: decoder))
        case "reportPathMap":
            self = try .reportPathMap(ReportPathMapInfo(from: decoder))
        case "preparedForIndex":
            self = try .preparedForIndex(PreparedForIndexInfo(from: decoder))
        case "backtraceFrame":
            self = try .backtraceFrame(BacktraceFrameInfo(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "invalid kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .buildStarted(info):
            try container.encode("buildStarted", forKey: .kind)
            try info.encode(to: encoder)
        case let .buildDiagnostic(info):
            try container.encode("buildDiagnostic", forKey: .kind)
            try info.encode(to: encoder)
        case let .buildCompleted(info):
            try container.encode("buildCompleted", forKey: .kind)
            try info.encode(to: encoder)
        case let .buildOutput(info):
            try container.encode("buildOutput", forKey: .kind)
            try info.encode(to: encoder)
        case let .preparationComplete(info):
            try container.encode("preparationComplete", forKey: .kind)
            try info.encode(to: encoder)
        case let .didUpdateProgress(info):
            try container.encode("didUpdateProgress", forKey: .kind)
            try info.encode(to: encoder)
        case let .targetUpToDate(info):
            try container.encode("targetUpToDate", forKey: .kind)
            try info.encode(to: encoder)
        case let .targetStarted(info):
            try container.encode("targetStarted", forKey: .kind)
            try info.encode(to: encoder)
        case let .targetOutput(info):
            try container.encode("targetOutput", forKey: .kind)
            try info.encode(to: encoder)
        case let .targetComplete(info):
            try container.encode("targetComplete", forKey: .kind)
            try info.encode(to: encoder)
        case let .taskUpToDate(info):
            try container.encode("taskUpToDate", forKey: .kind)
            try info.encode(to: encoder)
        case let .taskStarted(info):
            try container.encode("taskStarted", forKey: .kind)
            try info.encode(to: encoder)
        case let .taskDiagnostic(info):
            try container.encode("taskDiagnostic", forKey: .kind)
            try info.encode(to: encoder)
        case let .taskOutput(info):
            try container.encode("taskOutput", forKey: .kind)
            try info.encode(to: encoder)
        case let .taskComplete(info):
            try container.encode("taskComplete", forKey: .kind)
            try info.encode(to: encoder)
        case let .targetDiagnostic(info):
            try container.encode("targetDiagnostic", forKey: .kind)
            try info.encode(to: encoder)
        case let .diagnostic(info):
            try container.encode("diagnostic", forKey: .kind)
            try info.encode(to: encoder)
        case let .output(info):
            try container.encode("output", forKey: .kind)
            try info.encode(to: encoder)
        case let .planningOperationStarted(info):
            try container.encode("planningOperationStarted", forKey: .kind)
            try info.encode(to: encoder)
        case let .planningOperationCompleted(info):
            try container.encode("planningOperationCompleted", forKey: .kind)
            try info.encode(to: encoder)
        case let .reportBuildDescription(info):
            try container.encode("reportBuildDescription", forKey: .kind)
            try info.encode(to: encoder)
        case let .reportPathMap(info):
            try container.encode("reportPathMap", forKey: .kind)
            try info.encode(to: encoder)
        case let .preparedForIndex(info):
            try container.encode("preparedForIndex", forKey: .kind)
            try info.encode(to: encoder)
        case let .backtraceFrame(info):
            try container.encode("backtraceFrame", forKey: .kind)
            try info.encode(to: encoder)
        }
    }
}

fileprivate extension KeyedDecodingContainer {
    func decodeBoolOrString(forKey key: Key) throws -> Bool {
        do {
            return try decode(Bool.self, forKey: key)
        } catch {
            let string = try decode(String.self, forKey: key)
            guard let value = Bool(string) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Could not parse '\(string)' as Bool for key \(key)")
            }
            return value
        }
    }

    func decodeDoubleOrString(forKey key: Key) throws -> Double {
        do {
            return try decode(Double.self, forKey: key)
        } catch {
            let string = try decode(String.self, forKey: key)
            guard let value = Double(string) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Could not parse '\(string)' as Double for key \(key)")
            }
            return value
        }
    }

    func decodeIntOrString(forKey key: Key) throws -> Int {
        do {
            return try decode(Int.self, forKey: key)
        } catch {
            let string = try decode(String.self, forKey: key)
            guard let value = Int(string) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Could not parse '\(string)' as Int for key \(key)")
            }
            return value
        }
    }

    func decodeIntOrStringIfPresent(forKey key: Key) throws -> Int? {
        do {
            return try decodeIfPresent(Int.self, forKey: key)
        } catch {
            guard let string = try decodeIfPresent(String.self, forKey: key), !string.isEmpty else {
                return nil
            }
            guard let value = Int(string) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Could not parse '\(string)' as Int for key \(key)")
            }
            return value
        }
    }
}

fileprivate extension AbsolutePath {
    init?(validatingOrNilIfEmpty path: String?) throws {
        guard let path, !path.isEmpty else {
            return nil
        }
        try self.init(validating: path)
    }
}

// Shim for TSC AbsolutePath. "validating" does nothing.
public struct AbsolutePath: Hashable, Equatable, Sendable {
    public let pathString: String

    public init(validating path: String) throws {
        self.pathString = path
    }

    public static let root = try! AbsolutePath(validating: Path.root.str)
}

extension AbsolutePath: Codable {
    public init(from decoder: any Swift.Decoder) throws {
        try self.init(validating: String(from: decoder))
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try pathString.encode(to: encoder)
    }
}
