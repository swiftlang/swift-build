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

import Synchronization

/// The component of a diagnostic.
public enum Component: Serializable, Equatable, Hashable, Sendable, Codable {
    case `default`
    case packageResolution
    case targetIntegrity
    case clangCompiler(categoryName: String)
    case targetMissingUserApproval

    public static let swiftCompilerError = Self.clangCompiler(categoryName: "Swift Compiler Error")
    public static let parseIssue = Self.clangCompiler(categoryName: "Parse Issue")
    public static let lexicalOrPreprocessorIssue = Self.clangCompiler(categoryName: "Lexical or Preprocessor Issue")

    private init?(name: String) {
        switch name {
        case "default":
            self = .default
        case "packageResolution":
            self = .packageResolution
        case "targetIntegrity":
            self = .targetIntegrity

            // Compatibility cases
        case "swiftCompiler":
            self = .clangCompiler(categoryName: "Swift Compiler Error")
        case "parseIssue":
            self = .clangCompiler(categoryName: "Parse Issue")
        case "lexicalOrPreprocessorIssue":
            self = .clangCompiler(categoryName: "Lexical or Preprocessor Issue")

        default:
            self = .clangCompiler(categoryName: name)
        }
    }

    fileprivate var name: String {
        switch self {
        case .default:
            return "default"
        case .packageResolution:
            return "packageResolution"
        case .targetIntegrity:
            return "targetIntegrity"
        case let .clangCompiler(categoryName):
            return categoryName
        case .targetMissingUserApproval:
            return "targetMissingUserApproval"
        }
    }

    public func serialize<T>(to serializer: T) where T : Serializer {
        serializer.serialize(name)
    }

    public init(from deserializer: any Deserializer) throws {
        let value = try deserializer.deserialize() as String
        guard let component = Self.init(name: value) else {
            throw DeserializerError.unexpectedValue("Unknown Component value '\(value)'")
        }
        self = component
    }
}

/// The location of the diagnostic.
public protocol DiagnosticLocation {
    /// The human readable summary description for the location.
    var localizedDescription: String { get }
}

public struct Diagnostic: Equatable, Hashable, Serializable, Sendable, Codable {
    fileprivate enum LocationType: Int, Serializable {
        case unknown = 0
        case path = 1
        case buildSettings = 2
        case buildFiles = 3
    }

    fileprivate enum FileLocationType: Int, Serializable {
        case textual = 0
        case object = 1
    }

    public enum FileLocation: Equatable, Hashable, Serializable, Sendable, Codable {
        /// Represents a textual location in a file, identified by a line and (optionally) column number.
        /// - parameter line: The line number associated with the diagnostic.
        /// - parameter column: The column number associated with the diagnostic, if known.
        case textual(line: Int, column: Int?)

        /// Represents a semantic object location within a file.
        /// - parameter identifier: An opaque string identifying the object.
        case object(identifier: String)

        public func serialize<T>(to serializer: T) where T : Serializer {
            serializer.serializeAggregate(2) {
                switch self {
                case let .textual(line, column):
                    serializer.serialize(FileLocationType.textual)
                    serializer.serializeAggregate(2) {
                        serializer.serialize(line)
                        serializer.serialize(column)
                    }
                case let .object(identifier):
                    serializer.serialize(FileLocationType.object)
                    serializer.serialize(identifier)
                }
            }
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            switch try deserializer.deserialize() as FileLocationType {
            case .textual:
                try deserializer.beginAggregate(2)
                self = try .textual(line: deserializer.deserialize(), column: deserializer.deserialize())
            case .object:
                self = try .object(identifier: deserializer.deserialize())
            }
        }
    }

    public enum Location: DiagnosticLocation, Equatable, Hashable, Serializable, Sendable, Codable {
        /// Represents an unknown diagnostic location.
        case unknown

        /// Represents a file path diagnostic location.
        /// - parameter path: The file path associated with the diagnostic.
        /// - parameter fileLocation: The location within the file, either a textual line-column location or a semantic object identifier.
        case path(_ path: Path, fileLocation: FileLocation?)

        /// Represents a build settings diagnostic location.
        case buildSettings(names: [String])

        public struct BuildFileAndPhase: Hashable, Serializable, Sendable, Codable {
            public let buildFileGUID: String
            public let buildPhaseGUID: String

            public init(buildFileGUID: String, buildPhaseGUID: String) {
                self.buildFileGUID = buildFileGUID
                self.buildPhaseGUID = buildPhaseGUID
            }

            public func serialize<T: Serializer>(to serializer: T) {
                serializer.serializeAggregate(2) {
                    serializer.serialize(buildFileGUID)
                    serializer.serialize(buildPhaseGUID)
                }
            }

            public init(from deserializer: any Deserializer) throws {
                try deserializer.beginAggregate(2)
                buildFileGUID = try deserializer.deserialize()
                buildPhaseGUID = try deserializer.deserialize()
            }
        }

        /// Represents a build file diagnostic locations, within a particular target and project.
        case buildFiles(_ buildFiles: [BuildFileAndPhase], targetGUID: String)

        /// Represents a file path diagnostic location.
        public static func path(_ path: Path, line: Int? = nil, column: Int? = nil) -> Location {
            if let line {
                return .path(path, fileLocation: .textual(line: line, column: column))
            }

            // Can't have a column without a line; should use the type system to enforce this but requires adjusting a bunch of callers.
            assert(column == nil)

            return .path(path, fileLocation: nil)
        }

        /// Represents a build setting diagnostic location.
        public static func buildSetting(name: String) -> Location {
            return .buildSettings(names: [name])
        }

        /// Represents a build file diagnostic location, within a particular target and project.
        public static func buildFile(buildFileGUID: String, buildPhaseGUID: String, targetGUID: String) -> Location {
            return .buildFiles([.init(buildFileGUID: buildFileGUID, buildPhaseGUID: buildPhaseGUID)], targetGUID: targetGUID)
        }

        public var localizedDescription: String {
            switch self {
            case .unknown:
                return "<unknown>"
            case let .path(path, fileLocation):
                switch fileLocation {
                case let .textual(line, column):
                    if let column {
                        return "\(path.str):\(line):\(column)"
                    } else {
                        return "\(path.str):\(line)"
                    }
                case let .object(identifier):
                    if !identifier.isEmpty {
                        return "\(path.str):\(identifier)"
                    } else {
                        return "\(path.str)"
                    }
                case nil:
                    return path.str
                }
            case let .buildSettings(names):
                return names.joined(separator: ", ")
            case .buildFiles:
                return "<unknown>"
            }
        }

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.serializeAggregate(2) {
                switch self {
                case .unknown:
                    serializer.serialize(LocationType.unknown)
                    serializer.serialize("") // This is needed so that the number of items in the aggregate is constant no matter the case.
                case let .path(path, fileLocation):
                    serializer.serialize(LocationType.path)
                    serializer.beginAggregate(2)
                    serializer.serialize(path)
                    serializer.serialize(fileLocation)
                    serializer.endAggregate()
                case let .buildSettings(names):
                    serializer.serialize(LocationType.buildSettings)
                    serializer.beginAggregate(1)
                    serializer.serialize(names)
                    serializer.endAggregate()
                case let .buildFiles(buildFiles, targetGUID):
                    serializer.serialize(LocationType.buildFiles)
                    serializer.beginAggregate(2)
                    serializer.serialize(buildFiles)
                    serializer.serialize(targetGUID)
                    serializer.endAggregate()
                }
            }
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            switch try deserializer.deserialize() as LocationType {
            case .unknown:
                _ = try deserializer.deserialize() as String // This is just a mock for the aggregate and we can ignore the value.
                self = .unknown
            case .path:
                try deserializer.beginAggregate(2)
                self = .path(try deserializer.deserialize(),
                             fileLocation: try deserializer.deserialize())
            case .buildSettings:
                try deserializer.beginAggregate(1)
                self = .buildSettings(names: try deserializer.deserialize())
            case .buildFiles:
                try deserializer.beginAggregate(2)
                self = .buildFiles(try deserializer.deserialize(),
                                   targetGUID: try deserializer.deserialize())
            }
        }
    }

    /// The behavior associated with this diagnostic.
    public enum Behavior: Equatable, Hashable, Sendable, Codable {
        /// An error which will halt the operation.
        case error

        /// A warning, but which will not halt the operation.
        case warning

        /// An informational message.
        case note

        /// A diagnostic which was ignored.
        case ignored

        /// A remark, which provides information about the compiler's behavior on a successful operation.
        case remark

        public init?(name: String) {
            switch name {
            case "error":
                self = .error
            case "warning":
                self = .warning
            case "note":
                self = .note
            case "remark":
                self = .remark
            default:
                return nil
            }
        }

        public var name: String {
            switch self {
            case .error:
                return "error"
            case .warning:
                return "warning"
            case .note:
                return "note"
            case .ignored:
                return "ignored"
            case .remark:
                return "remark"
            }
        }
    }

    /// Represents a line and column delimited range within a textual source file.
    public struct SourceRange: Equatable, Hashable, Serializable, CustomStringConvertible, Sendable, Codable {
        public let path: Path
        public let startLine: Int
        public let startColumn: Int
        public let endLine: Int
        public let endColumn: Int

        public func serialize<T>(to serializer: T) where T : Serializer {
            serializer.serializeAggregate(5) {
                serializer.serialize(path)
                serializer.serialize(startLine)
                serializer.serialize(startColumn)
                serializer.serialize(endLine)
                serializer.serialize(endColumn)
            }
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(5)
            path = try deserializer.deserialize()
            startLine = try deserializer.deserialize()
            startColumn = try deserializer.deserialize()
            endLine = try deserializer.deserialize()
            endColumn = try deserializer.deserialize()
        }

        public init(path: Path, startLine: Int, startColumn: Int, endLine: Int, endColumn: Int) {
            self.path = path
            self.startLine = startLine
            self.startColumn = startColumn
            self.endLine = endLine
            self.endColumn = endColumn
        }

        /// Create a copy of this SourceRange with the given modifications.
        public func with(path: Path? = nil, startLine: Int? = nil, startColumn: Int? = nil, endLine: Int? = nil, endColumn: Int? = nil) -> Self {
            return Self(path: path ?? self.path, startLine: startLine ?? self.startLine, startColumn: startColumn ?? self.startColumn, endLine: endLine ?? self.endLine, endColumn: endColumn ?? self.endColumn)
        }

        public var description: String {
            return "\(path.str):\(startLine):\(startColumn)-\(endLine):\(endColumn)"
        }
    }

    public struct FixIt: Equatable, Hashable, Serializable, Sendable, Codable {
        /// The location of the fix.  May be an empty location (start and end locations the same) for pure insert.
        public let sourceRange: SourceRange

        /// The new text to replace the range.  May be an empty string for pure delete.
        public let textToInsert: String

        public func serialize<T: Serializer>(to serializer: T) {
            serializer.serializeAggregate(2) {
                serializer.serialize(sourceRange)
                serializer.serialize(textToInsert)
            }
        }

        public init(from deserializer: any Deserializer) throws {
            try deserializer.beginAggregate(2)
            self.sourceRange = try deserializer.deserialize()
            self.textToInsert = try deserializer.deserialize()
        }

        public init(sourceRange: SourceRange, newText: String) {
            self.sourceRange = sourceRange
            self.textToInsert = newText
        }

        public func localizedDescription(includeLocation: Bool) -> String {
            return "\(includeLocation ? "\(sourceRange): " : "")fixit: \(textToInsert)"
        }
    }

    /// The diagnostic's behavior.
    public let behavior: Behavior

    /// The conceptual location of this diagnostic.
    ///
    /// This could refer to a concrete location in a file, for example, but it
    /// could also refer to an abstract location such as "the Git repository at
    /// this URL".
    public let location: Location

    /// The source ranges indicating key locations within files associated with this diagnostic.
    public let sourceRanges: [SourceRange]

    /// The information on the actual diagnostic.
    public let data: DiagnosticData

    /// If this diagnostic should be appended to the output stream.
    ///
    /// This should be set to true if the diagnostic should be appended to the log stream in clients of Swift Build.
    public let appendToOutputStream: Bool

    /// List of child diagnostics of this diagnostic, used for nesting during display.
    /// Note that multi-level nesting is not guaranteed to be supported by clients.
    public let childDiagnostics: [Diagnostic]

    /// List of fix-its for this diagnostic.
    public let fixIts: [FixIt]

    // FIXME: Need additional attachment mechanism (backtrace, etc.), or
    // extensible handlers (e.g., interactive diagnostics).

    /// Create a new diagnostic.
    ///
    /// - Parameters:
    ///   - location: The abstract location of the issue which triggered the diagnostic.
    ///   - parameters: The parameters to the diagnostic conveying additional information.
    /// - Precondition: The bindings must match those declared by the identifier.
    public init(behavior: Behavior, location: Location, sourceRanges: [SourceRange] = [], data: DiagnosticData, appendToOutputStream: Bool = true, fixIts: [FixIt] = [], childDiagnostics: [Diagnostic] = []) {
        self.behavior = behavior
        self.location = location
        self.sourceRanges = sourceRanges
        self.data = data
        self.appendToOutputStream = appendToOutputStream
        self.childDiagnostics = childDiagnostics
        self.fixIts = fixIts
    }

    /// Create a copy of this diagnostic with the given modifications.
    public func with(behavior: Behavior? = nil, location: Location? = nil, sourceRanges: [SourceRange] = [], data: DiagnosticData? = nil, appendToOutputStream: Bool? = nil, fixIts: [FixIt]? = nil, childDiagnostics: [Diagnostic]? = nil) -> Diagnostic {
        return Diagnostic(behavior: behavior ?? self.behavior, location: location ?? self.location, sourceRanges: sourceRanges, data: data ?? self.data, appendToOutputStream: appendToOutputStream ?? self.appendToOutputStream, fixIts: fixIts ?? self.fixIts, childDiagnostics: childDiagnostics ?? self.childDiagnostics)
    }

    /// Enumerates possible styles of printing the diagnostic's localized description, that is, which information to include in a string representation of the diagnostic in addition to the message string.
    ///
    /// This is used to control which pieces of contextual information are included in string representations of the diagnostic -- IDE clients like Xcode will want nothing, since they will represent the diagnostics in a UI, using icons for the behavior, grouping by component, adding click actions based on the location, etc., while the build system's internal testing will prefer all contextual information directly in the string for easy diagnosis and comparison in unit tests.
    public enum LocalizedDescriptionFormat: Sendable {
        /// Debug-level formatting. Includes all contextual information as well as child diagnostics, recursively. Used for debug-level output and for sorting/comparison.
        case debug

        /// Same as `debug`, but without the behavior. Used in contexts where testing APIs formally separate error, warning, and notice behaviors separately from the diagnostic's message string.
        case debugWithoutBehavior

        /// Same as `debugWithoutBehavior`, but additionally excluding the location (if the location is a path). Used in contexts where testing APIs formally separate location as well.
        case debugWithoutBehaviorAndLocation

        /// Message string only. Used by clients such as Xcode which will represent diagnostics graphically in a UI or otherwise handle formatting entirely by themselves.
        case messageOnly
    }

    /// Human readable description for the diagnostic.
    public func formatLocalizedDescription(_ format: LocalizedDescriptionFormat) -> String {
        switch format {
        case .debug:
            return formatLocalizedDescription(includeLocation: true, includeSourceRanges: true, includeBehavior: true, includeComponent: true, includeFixIts: true, includeChildren: true)
        case .debugWithoutBehavior:
            return formatLocalizedDescription(includeLocation: true, includeSourceRanges: false, includeBehavior: false, includeComponent: true, includeFixIts: true, includeChildren: true)
        case .debugWithoutBehaviorAndLocation:
            return formatLocalizedDescription(includeLocation: false, includeSourceRanges: false, includeBehavior: false, includeComponent: true, includeFixIts: false, includeChildren: true)
        case .messageOnly:
            return formatLocalizedDescription(includeLocation: false, includeSourceRanges: false, includeBehavior: false, includeComponent: false, includeFixIts: false, includeChildren: false)
        }
    }

    /// Human readable description for the diagnostic.
    private func formatLocalizedDescription(includeLocation: Bool, includeSourceRanges: Bool, includeBehavior: Bool, includeComponent: Bool, includeFixIts: Bool, includeChildren: Bool) -> String {
        var result = ""

        // Include file path and line number information for path-based diagnostics
        if includeLocation, case .path = location {
            result += location.localizedDescription
            result += ": "
        }

        if includeSourceRanges && !sourceRanges.isEmpty {
            result += "["
            result += sourceRanges.map { "\($0.startLine):\($0.startColumn)-\($0.endLine):\($0.endColumn)" }.joined(separator: ", ")
            result += "]"
            result += ": "
        }

        if includeBehavior {
            result += behavior.name
            result += ": "
        }

        if includeComponent && data.component != .default {
            result += "[" + data.component.name + "] "
        }

        result += data.description

        if includeFixIts {
            result = ([result] + fixIts.map { $0.localizedDescription(includeLocation: includeLocation) }).joined(separator: "\n")
        }

        if includeChildren {
            result = ([result] + childDiagnostics.map { $0.formatLocalizedDescription(includeLocation: includeLocation, includeSourceRanges: includeSourceRanges, includeBehavior: includeBehavior, includeComponent: includeComponent, includeFixIts: includeFixIts, includeChildren: includeChildren) }).joined(separator: "\n")
        }

        return result
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(7)
        serializer.serialize(self.data)
        serializer.serialize(self.behavior.name)
        serializer.serialize(self.location)
        serializer.serialize(self.sourceRanges)
        serializer.serialize(self.appendToOutputStream)
        serializer.serialize(self.fixIts)
        serializer.serialize(self.childDiagnostics)
        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        self.data = try deserializer.deserialize()
        let behaviorName: String = try deserializer.deserialize()
        guard let behavior = Behavior(name: behaviorName) else {
            throw DeserializerError.unexpectedValue(behaviorName)
        }
        self.behavior = behavior
        self.location = try deserializer.deserialize()
        self.sourceRanges = try deserializer.deserialize()
        self.appendToOutputStream = try deserializer.deserialize()
        self.fixIts = try deserializer.deserialize()
        self.childDiagnostics = try deserializer.deserialize()
    }

    public static func ==(lhs: Diagnostic, rhs: Diagnostic) -> Bool {
        // Not the best for performance, but this is only used in unit tests, and making DiagnosticID and DiagnosticData conform to Equatable is nontrivial.
        lhs.formatLocalizedDescription(.debug) == rhs.formatLocalizedDescription(.debug)
    }
}

/// An engine for managing diagnostic output.
public final class DiagnosticsEngine: CustomStringConvertible, Sendable {
    private struct MutableState: Sendable {
        /// The list of handlers to run when a diagnostic is emitted.
        var handlers: [@Sendable (Diagnostic) -> Void] = []
        var diagnostics: [Diagnostic] = []
        var hasErrors: Bool = false
        var immutable: Bool = false
    }

    private let mutableState = SWBMutex<MutableState>(.init())

    /// The diagnostics produced by the engine.
    public var diagnostics: [Diagnostic] {
        return mutableState.withLock { $0.diagnostics }
    }

    public var hasErrors: Bool {
        return mutableState.withLock { $0.hasErrors }
    }

    public init() {
    }

    public func addHandler(_ handler: @escaping @Sendable (Diagnostic) -> Void) {
        mutableState.withLock { mutableState in
            mutableState.handlers.append(handler)
        }
    }

    public func emit(_ diag: Diagnostic) {
        mutableState.withLock { mutableState in
            // If the diagnostics engine is frozen, it should no longer be receiving diagnostics.
            // We currently violate this constraint in a number of places, which means that
            // diagnostics emitted to the core delegate after core initialization will be
            // silently dropped and never emitted anywhere.
            assert(!mutableState.immutable)

            mutableState.diagnostics.append(diag)
            if diag.behavior == .error {
                mutableState.hasErrors = true
            }
        }
        for handler in mutableState.withLock({ $0.handlers }) {
            handler(diag)
        }
    }

    public func emit(data: DiagnosticData, behavior: Diagnostic.Behavior, location: Diagnostic.Location = .unknown, childDiagnostics: [Diagnostic] = []) {
        emit(Diagnostic(behavior: behavior, location: location, sourceRanges: [], data: data, childDiagnostics: childDiagnostics))
    }

    public func freeze() {
        mutableState.withLock { $0.immutable = true }
    }

    public var description: String {
        let stream = OutputByteStream()
        stream <<< "["
        for diag in diagnostics {
            stream <<< diag.formatLocalizedDescription(.debug) <<< ", "
        }
        stream <<< "]"
        return stream.bytes.asString
    }
}

// MARK: Utilities

/// Adaptor diagnostic from literal strings.
public struct DiagnosticData: Serializable, Equatable, Hashable, Sendable, Codable {
    public let description: String
    public let component: Component
    public let optionName: String?

    public init(_ description: String, component: Component = .default, optionName: String? = nil) {
        self.description = description
        self.component = component
        self.optionName = optionName
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(description)
            serializer.serialize(component)
            serializer.serialize(optionName)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(2...3)
        self.description = try deserializer.deserialize()
        self.component = try deserializer.deserialize()
        self.optionName = (count >= 3) ? try deserializer.deserialize() : nil
    }
}
