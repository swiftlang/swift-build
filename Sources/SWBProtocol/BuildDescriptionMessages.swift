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

// MARK: Support types

public struct ConfiguredTargetIdentifier: Hashable, Sendable, Codable {
    public var rawGUID: String
    public var targetGUID: TargetGUID

    public init(rawGUID: String, targetGUID: TargetGUID) {
        self.rawGUID = rawGUID
        self.targetGUID = targetGUID
    }
}

/// The language of a source file
public enum SourceLanguage: Hashable, Sendable, Codable {
    case c
    case cpp
    case metal
    case objectiveC
    case objectiveCpp
    case swift
}

// MARK: Requests

/// Get the configured targets inside a pre-generated build description, their dependencies and some supplementary
/// information about the targets.
public struct BuildDescriptionConfiguredTargetsRequest: SessionMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = BuildDescriptionConfiguredTargetsResponse

    public static let name = "BUILD_DESCRIPTION_CONFIGURED_TARGETS_REQUEST"

    public let sessionHandle: String

    /// The ID of the build description from which to load the configured targets
    public let buildDescriptionID: BuildDescriptionID

    /// The build request that was used to generate the build description with the given ID.
    public let request: BuildRequestMessagePayload

    public init(sessionHandle: String, buildDescriptionID: BuildDescriptionID, request: BuildRequestMessagePayload) {
        self.sessionHandle = sessionHandle
        self.buildDescriptionID = buildDescriptionID
        self.request = request
    }
}

public struct BuildDescriptionConfiguredTargetsResponse: Message, SerializableCodable, Equatable {
    public static let name = "BUILD_DESCRIPTION_CONFIGURED_TARGETS_RESPONSE"

    public struct ConfiguredTargetInfo: SerializableCodable, Equatable, Sendable {
        /// The GUID of this configured target
        public let identifier: ConfiguredTargetIdentifier

        /// A name of the target that may be displayed to the user
        public let name: String

        /// The configured targets that this target depends on
        public let dependencies: Set<ConfiguredTargetIdentifier>

        /// The path of the toolchain that should be used to build this target.
        ///
        /// `nil` if the toolchain for this target could not be determined due to an error.
        public let toolchain: Path?

        public let artifactInfo: ArtifactInfo?

        public init(identifier: ConfiguredTargetIdentifier, name: String, dependencies: Set<ConfiguredTargetIdentifier>, toolchain: Path?, artifactInfo: ArtifactInfo?) {
            self.identifier = identifier
            self.name = name
            self.dependencies = dependencies
            self.toolchain = toolchain
            self.artifactInfo = artifactInfo
        }
    }

    public let configuredTargets: [ConfiguredTargetInfo]

    public init(configuredTargets: [ConfiguredTargetInfo]) {
        self.configuredTargets = configuredTargets
    }
}

/// Get information about the source files in a list of configured targets.
public struct BuildDescriptionConfiguredTargetSourcesRequest: SessionMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = BuildDescriptionConfiguredTargetSourcesResponse

    public static let name = "BUILD_DESCRIPTION_CONFIGURED_TARGET_SOURCES_REQUEST"

    public var sessionHandle: String

    /// The ID of the build description in which the configured targets reside
    public let buildDescriptionID: BuildDescriptionID

    /// The build request that was used to generate the build description with the given ID.
    public let request: BuildRequestMessagePayload

    /// The configured targets for which to load source file information
    public let configuredTargets: [ConfiguredTargetIdentifier]

    public init(sessionHandle: String, buildDescriptionID: BuildDescriptionID, request: BuildRequestMessagePayload, configuredTargets: [ConfiguredTargetIdentifier]) {
        self.sessionHandle = sessionHandle
        self.buildDescriptionID = buildDescriptionID
        self.request = request
        self.configuredTargets = configuredTargets
    }
}

public struct BuildDescriptionConfiguredTargetSourcesResponse: Message, SerializableCodable, Equatable {
    public static let name = "BUILD_DESCRIPTION_CONFIGURED_TARGET_SOURCES_RESPONSE"

    public struct SourceFileInfo: SerializableCodable, Equatable, Sendable {
        /// The path of the source file on disk
        public let path: Path

        /// The language of the source file.
        ///
        /// `nil` if the language could not be determined due to an error.
        public let language: SourceLanguage?

        /// The output path that is used for indexing, ie. the value of the `-index-unit-output-path` or `-o` option in
        /// the source file's build settings.
        ///
        /// This is a `String` and not a `Path` because th index output path may be a fake path that is relative to the
        /// build directory and has no relation to actual files on disks.
        ///
        /// May be `nil` if the output path could not be determined due to an error.
        public let indexOutputPath: String?

        public init(path: Path, language: SourceLanguage?, outputPath: String?) {
            self.path = path
            self.language = language
            self.indexOutputPath = outputPath
        }
    }

    public struct ConfiguredTargetSourceFilesInfo: SerializableCodable, Equatable, Sendable {
        /// The configured target to which this info belongs
        public let configuredTarget: ConfiguredTargetIdentifier

        /// Information about the source files in this source file
        public let sourceFiles: [SourceFileInfo]

        public init(configuredTarget: ConfiguredTargetIdentifier, sourceFiles: [SourceFileInfo]) {
            self.configuredTarget = configuredTarget
            self.sourceFiles = sourceFiles
        }
    }

    /// For each requested configured target, the response contains one entry in this array
    public let targetSourceFileInfos: [ConfiguredTargetSourceFilesInfo]

    public init(targetSourceFileInfos: [ConfiguredTargetSourceFilesInfo]) {
        self.targetSourceFileInfos = targetSourceFileInfos
    }
}

/// Select a configured target for each provided target GUID in the pre-generated build description to be used by the index.
public struct BuildDescriptionSelectConfiguredTargetsForIndexRequest: SessionMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = BuildDescriptionSelectConfiguredTargetsForIndexResponse

    public static let name = "BUILD_DESCRIPTION_SELECT_CONFIGURED_TARGETS_FOR_INDEX_REQUEST"

    public let sessionHandle: String

    /// The ID of the build description from which to load the configured targets
    public let buildDescriptionID: BuildDescriptionID

    /// The build request that was used to generate the build description with the given ID.
    public let request: BuildRequestMessagePayload

    /// The targets for which to select configured targets.
    public let targets: [TargetGUID]

    public init(sessionHandle: String, buildDescriptionID: BuildDescriptionID, request: BuildRequestMessagePayload, targets: [TargetGUID]) {
        self.sessionHandle = sessionHandle
        self.buildDescriptionID = buildDescriptionID
        self.request = request
        self.targets = targets
    }
}

public struct BuildDescriptionSelectConfiguredTargetsForIndexResponse: Message, SerializableCodable, Equatable {
    public static let name = "BUILD_DESCRIPTION_SELECT_CONFIGURED_TARGETS_FOR_INDEX_RESPONSE"

    public let configuredTargets: [ConfiguredTargetIdentifier]

    public init(configuredTargets: [ConfiguredTargetIdentifier]) {
        self.configuredTargets = configuredTargets
    }
}

/// Load the build settings that should be used to index a source file in a given configured target
public struct IndexBuildSettingsRequest: SessionMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = IndexBuildSettingsResponse

    public static let name = "INDEX_BUILD_SETTINGS_REQUEST"

    public var sessionHandle: String

    /// The ID of the build description in which the configured targets reside
    public let buildDescriptionID: BuildDescriptionID

    /// The build request that was used to generate the build description with the given ID.
    public let request: BuildRequestMessagePayload

    /// The configured target in whose context the build settings of the source file should be loaded
    public let configuredTarget: ConfiguredTargetIdentifier

    /// The path of the source file for which the build settings should be loaded
    public let file: Path

    public init(
        sessionHandle: String,
        buildDescriptionID: BuildDescriptionID,
        request: BuildRequestMessagePayload,
        configuredTarget: ConfiguredTargetIdentifier,
        file: Path
    ) {
        self.sessionHandle = sessionHandle
        self.buildDescriptionID = buildDescriptionID
        self.request = request
        self.configuredTarget = configuredTarget
        self.file = file
    }
}

public struct IndexBuildSettingsResponse: Message, SerializableCodable, Equatable {
    public static let name = "INDEX_BUILD_SETTINGS_RESPONSE"

    /// The arguments that should be passed to the compiler to index the source file.
    ///
    /// This does not include the path to the compiler executable itself.
    public let compilerArguments: [String]

    public init(compilerArguments: [String]) {
        self.compilerArguments = compilerArguments
    }
}

public struct ReleaseBuildDescriptionRequest: SessionMessage, RequestMessage, SerializableCodable, Equatable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "RELEASE_BUILD_DESCRIPTION"

    public var sessionHandle: String

    public let buildDescriptionID: BuildDescriptionID

    public init(
        sessionHandle: String,
        buildDescriptionID: BuildDescriptionID
    ) {
        self.sessionHandle = sessionHandle
        self.buildDescriptionID = buildDescriptionID
    }
}

// MARK: Registering messages

let buildDescriptionMessages: [any Message.Type] = [
    BuildDescriptionConfiguredTargetsRequest.self,
    BuildDescriptionConfiguredTargetsResponse.self,
    BuildDescriptionConfiguredTargetSourcesRequest.self,
    BuildDescriptionConfiguredTargetSourcesResponse.self,
    BuildDescriptionSelectConfiguredTargetsForIndexRequest.self,
    BuildDescriptionSelectConfiguredTargetsForIndexResponse.self,
    IndexBuildSettingsRequest.self,
    IndexBuildSettingsResponse.self,
    ReleaseBuildDescriptionRequest.self,
]
