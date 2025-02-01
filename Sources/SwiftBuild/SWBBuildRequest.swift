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

public import Foundation

import SWBProtocol
import SWBUtil

/// Refer to `SWBCore.BuildCommand`, `SWBProtocol.BuildCommandMessagePayload`
public struct SWBBuildCommand: Codable, Equatable, Sendable {
    let command: BuildCommand

    private init(command: BuildCommand) {
        self.command = command
    }

    // We expose methods rather than using a direct enum because clients have no need to switch over the values,
    // and it allows for easier evolution of the API by adding overloading with new parameters.

    public static func build(style: SWBBuildTaskStyle) -> Self {
        return build(style: style, skipDependencies: false)
    }

    public static func build(style: SWBBuildTaskStyle, skipDependencies: Bool) -> Self {
        return .init(command: .build(style: style, skipDependencies: skipDependencies))
    }

    public static func buildFiles(paths: [String], action: SWBBuildFilesAction) -> Self {
        return .init(command: .buildFiles(paths: paths, action: action))
    }

    public static func prepareForIndexing(buildOnlyTheseTargets: [String]?, enableIndexBuildArena: Bool) -> Self {
        return .init(command: .prepareForIndexing(buildOnlyTheseTargets: buildOnlyTheseTargets, enableIndexBuildArena: enableIndexBuildArena))
    }

    public static let migrate = Self(command: .migrate)

    public static func cleanBuildFolder(style: SWBBuildLocationStyle) -> Self {
        return .init(command: .cleanBuildFolder(style: style))
    }

    public static func preview(style: SWBPreviewStyle) -> Self {
        return .init(command: .preview(style: style))
    }

    public init(from decoder: any Decoder) throws {
        command = try .init(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try command.encode(to: encoder)
    }
}

/// Refer to `SWBCore.BuildCommand`, `SWBProtocol.BuildCommandMessagePayload`
enum BuildCommand: Codable, Equatable {
    case build(style: SWBBuildTaskStyle, skipDependencies: Bool)
    case buildFiles(paths: [String], action: SWBBuildFilesAction)
    case prepareForIndexing(buildOnlyTheseTargets: [String]?, enableIndexBuildArena: Bool)
    case migrate
    case cleanBuildFolder(style: SWBBuildLocationStyle)
    case preview(style: SWBPreviewStyle)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Command.self, forKey: .command) {
        case .build:
            self = try .build(style: container.decode(SWBBuildTaskStyle.self, forKey: .style), skipDependencies: container.decode(Bool.self, forKey: .skipDependencies))
        case .buildFiles:
            self = try .buildFiles(paths: container.decode([String].self, forKey: .files), action: container.decode(SWBBuildFilesAction.self, forKey: .action))
        case .prepareForIndexing:
            self = try .prepareForIndexing(buildOnlyTheseTargets: container.decode([String].self, forKey: .targets), enableIndexBuildArena: container.decode(Bool.self, forKey: .enableIndexBuildArena))
        case .migrate:
            self = .migrate
        case .cleanBuildFolder:
            self = .cleanBuildFolder(style: try container.decode(SWBBuildLocationStyle.self, forKey: .style))
        case .preview:
            // NOTE: Falling back to .dynamicReplacement for temporary compatibility; this is a required parameter
            self = .preview(style: try container.decodeIfPresent(SWBPreviewStyle.self, forKey: .style) ?? .dynamicReplacement)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Command(self), forKey: .command)
        switch self {
        case let .build(style, skipDependencies):
            try container.encode(style, forKey: .style)
            try container.encode(skipDependencies, forKey: .skipDependencies)
        case .migrate:
            break
        case let .buildFiles(paths: paths, action: action):
            try container.encode(paths, forKey: .files)
            try container.encode(action, forKey: .action)
        case let .prepareForIndexing(buildOnlyTheseTargets, enableIndexBuildArena):
            try container.encode(buildOnlyTheseTargets, forKey: .targets)
            try container.encode(enableIndexBuildArena, forKey: .enableIndexBuildArena)
        case let .cleanBuildFolder(style):
            try container.encode(style, forKey: .style)
        case let .preview(style):
            try container.encode(style, forKey: .style)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case files
        case action
        case targets
        case style
        case skipDependencies
        case enableIndexBuildArena
    }

    private enum Command: String, Codable {
        case build
        case buildFiles
        case prepareForIndexing
        case migrate
        case cleanBuildFolder
        case preview

        init(_ command: BuildCommand) {
            switch command {
            case .build:
                self = .build
            case .buildFiles:
                self = .buildFiles
            case .prepareForIndexing:
                self = .prepareForIndexing
            case .migrate:
                self = .migrate
            case .cleanBuildFolder:
                self = .cleanBuildFolder
            case .preview:
                self = .preview
            }
        }
    }
}

public enum SWBBuildTaskStyle: String, Codable, Sendable {
    case buildOnly
    case buildAndRun
}

public enum SWBBuildFilesAction: String, Codable, Sendable {
    case compile
    case assemble
    case preprocess
}

public enum SWBBuildLocationStyle: String, Codable, Sendable {
    case regular
    case legacy
}

public enum SWBPreviewStyle: String, Codable, Sendable {
    /// A build mode for previews using XOJIT, which is expected to use a shared build arena.
    case xojit

    /// A build mode for previews using dynamic replacement, which is expected to use a separate build arena.
    case dynamicReplacement
}

/// Refer to `SWBCore.SchemeCommand`, `SWBProtocol.SchemeCommandMessagePayload`
public enum SWBSchemeCommand: String, Codable, Sendable {
    case launch
    case test
    case profile
    case archive
}

/// A configured target represents a target and any additional information required to build it in a particular request.
public struct SWBConfiguredTarget: Codable, Sendable {
    /// The PIF GUID of the target to build.
    public var guid: String

    /// The additional build parameters, if necessary.
    public var parameters: SWBBuildParameters?

    /// Create a configured target for the named target GUID.
    ///
    /// - Parameters:
    ///   - guid: The GUID of the target, which must exist in any PIF this request is sent against.
    ///   - parameters: If given, the set of parameters to use for the target (which overrides the parameters passed in the build request). This can be used to customize behavior on a per-target basis.
    public init(guid: String, parameters: SWBBuildParameters? = nil) {
        self.guid = guid
        self.parameters = parameters
    }
}

/// Refer to `SWBProtocol.BuildQoSMessagePayload`
public enum SWBBuildQoS: String, Codable, Sendable {
    case background
    case utility
    case `default`
    case userInitiated

    var dispatchQoS: SWBQoS {
        switch self {
        case .background: return .background
        case .utility: return .utility
        case .default: return .default
        case .userInitiated: return .userInitiated
        }
    }
}

public enum SWBDependencyScope: String, Codable, Sendable {
    case workspace
    case buildRequest

    var messagePayload: DependencyScopeMessagePayload {
        switch self {
        case .workspace:
            return .workspace
        case .buildRequest:
            return .buildRequest
        }
    }
}

/// Container for information required to dispatch a build operation.
public struct SWBBuildRequest: Codable, Sendable {
    /// The build parameters for the overall request.
    public var parameters = SWBBuildParameters()

    /// The list of configured targets.
    public var configuredTargets = [SWBConfiguredTarget]()

    /// Whether targets should be built in parallel.
    public var useParallelTargets = true

    /// Whether implicit dependencies should be added.
    public var useImplicitDependencies = false

    /// The scope determining which target dependencies are considered in a build.
    public var dependencyScope: SWBDependencyScope = .workspace

    /// Whether or not to use "dry run" mode, in which the work to be done is just logged but not executed.
    public var useDryRun = false

    /// Whether or not to continue building after errors
    public var continueBuildingAfterErrors = false

    /// Whether the shell script environment should be shown in the log.
    public var hideShellScriptEnvironment = false

    /// Whether to report non-logged progress updates.
    public var showNonLoggedProgress = true

    /// Whether to record build backtrace frames.
    public var recordBuildBacktraces: Bool? = nil

    /// Whether to generate a report detailing precompiled modules.
    public var generatePrecompiledModulesReport: Bool? = nil

    /// Optional path of a directory into which to write diagnostic information about the build plan.
    public var buildPlanDiagnosticsDirPath: String? = nil

    /// Refer to `SWBCore.BuildCommand`
    public var buildCommand: SWBBuildCommand = .build(style: .buildOnly)

    /// Refer to `SWBCore.SchemeCommand`
    public var schemeCommand: SWBSchemeCommand? = .launch

    /// Path of the root container being built. This is typically a .xcworkspace or .xcodeproj,
    /// but can also be a .playground or the path to a directory containing a Package.swift file.
    public var containerPath: String? = nil

    /// Optional array of paths to files the build should be limited to.
    public var buildOnlyTheseFiles: [String]? = nil

    /// Optional array of GUIDs of targets the build should be limited to.
    public var buildOnlyTheseTargets: [String]? = nil

    /// Optional ID of the build description to use for the request.
    /// If set then the build description will be retrieved using the ID and no build planning will occur.
    public var buildDescriptionID: String? = nil

    /// Whether or not to use a dedicated build arena for the index related requests.
    public var enableIndexBuildArena = false

    /// The QoS to use for the build operation. If not set then a default QoS, that can be configured with a UserDefault, will be selected.
    public var qos: SWBBuildQoS? = nil

    /// Whether or not legacy build locations are being used. Currently, this flag is only relevant for clean build folder.
    public var useLegacyBuildLocations = false

    public init() { }

    /// Add a configured target to build to the request.
    public mutating func add(target configuredTarget: SWBConfiguredTarget) {
        configuredTargets.append(configuredTarget)
    }
}

extension SWBBuildRequest {
    public func dump(toFile filePath: String) throws {
        let filePath = Path(filePath)
        let serializer = MsgPackSerializer()
        serializer.serialize(self.messagePayloadRepresentation)
        try localFS.write(filePath, contents: serializer.byteString)
    }

    public func jsonData() throws -> Data {
        try JSONEncoder(outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).encode(self)
    }
}
