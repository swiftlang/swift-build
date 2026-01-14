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

public import struct Foundation.Data

public enum BuildTaskStyleMessagePayload: Int, Serializable, Codable, Equatable, Sendable {
    case buildOnly
    case buildAndRun
}

public enum BuildLocationStyleMessagePayload: Int, Serializable, Codable, Equatable, Sendable {
    case regular
    case legacy
}

public enum PreviewStyleMessagePayload: Int, Serializable, Codable, Equatable, Sendable {
    case dynamicReplacement
    case xojit
}

/// Refer to `SWBCore.BuildCommand`
public enum BuildCommandMessagePayload: SerializableCodable, Equatable, Sendable {
    case build(style: BuildTaskStyleMessagePayload, skipDependencies: Bool)
    case generateAssemblyCode(buildOnlyTheseFiles: [String])
    case generatePreprocessedFile(buildOnlyTheseFiles: [String])
    case singleFileBuild(buildOnlyTheseFiles: [String])
    case prepareForIndexing(buildOnlyTheseTargets: [String]?, enableIndexBuildArena: Bool)
    case migrate
    case cleanBuildFolder(style: BuildLocationStyleMessagePayload)
    case preview(style: PreviewStyleMessagePayload)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Command.self, forKey: .command) {
        case .build:
            self = try .build(style: container.decode(BuildTaskStyleMessagePayload.self, forKey: .style), skipDependencies: container.decodeIfPresent(Bool.self, forKey: .skipDependencies) ?? false)
        case .generateAssemblyCode:
            self = .generateAssemblyCode(buildOnlyTheseFiles: try container.decode([String].self, forKey: .files))
        case .generatePreprocessedFile:
            self = .generatePreprocessedFile(buildOnlyTheseFiles: try container.decode([String].self, forKey: .files))
        case .singleFileBuild:
            self = .singleFileBuild(buildOnlyTheseFiles: try container.decode([String].self, forKey: .files))
        case .prepareForIndexing:
            self = try .prepareForIndexing(buildOnlyTheseTargets: container.decode([String]?.self, forKey: .targets), enableIndexBuildArena: container.decode(Bool.self, forKey: .enableIndexBuildArena))
        case .migrate:
            self = .migrate
        case .cleanBuildFolder:
            self = .cleanBuildFolder(style: try container.decode(BuildLocationStyleMessagePayload.self, forKey: .style))
        case .preview:
            self = .preview(style: try container.decode(PreviewStyleMessagePayload.self, forKey: .style))
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
        case let .generateAssemblyCode(buildOnlyTheseFiles),
             let .generatePreprocessedFile(buildOnlyTheseFiles),
             let .singleFileBuild(buildOnlyTheseFiles):
            try container.encode(buildOnlyTheseFiles, forKey: .files)
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
        case targets
        case style
        case skipDependencies
        case enableIndexBuildArena
    }

    private enum Command: String, Codable {
        case build
        case generateAssemblyCode
        case generatePreprocessedFile
        case singleFileBuild
        case prepareForIndexing
        case migrate
        case cleanBuildFolder
        case preview

        init(_ command: BuildCommandMessagePayload) {
            switch command {
            case .build:
                self = .build
            case .generateAssemblyCode:
                self = .generateAssemblyCode
            case .generatePreprocessedFile:
                self = .generatePreprocessedFile
            case .singleFileBuild:
                self = .singleFileBuild
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

/// Refer to `SWBCore.SchemeCommand`
public enum SchemeCommandMessagePayload: Int, Serializable, Codable, Equatable, Sendable {
    case launch
    case test
    case profile
    case archive
}

public enum BuildQoSMessagePayload: Int, Serializable, Codable, Equatable, Sendable {
    case background
    case utility
    case `default`
    case userInitiated
}

public enum DependencyScopeMessagePayload: Int, Codable, Equatable, Sendable {
    case workspace
    case buildRequest
}

/// The build request being sent in a Message.
public struct BuildRequestMessagePayload: SerializableCodable, Equatable, Sendable {
    public var parameters: BuildParametersMessagePayload
    public var configuredTargets: [ConfiguredTargetMessagePayload]
    public var dependencyScope: DependencyScopeMessagePayload
    public var continueBuildingAfterErrors: Bool
    public var hideShellScriptEnvironment: Bool
    public var useParallelTargets: Bool
    public var useImplicitDependencies: Bool
    public var useDryRun: Bool
    public var showNonLoggedProgress: Bool
    public var recordBuildBacktraces: Bool?
    public var generatePrecompiledModulesReport: Bool?
    public var buildPlanDiagnosticsDirPath: Path?
    public var buildCommand: BuildCommandMessagePayload
    public var schemeCommand: SchemeCommandMessagePayload?
    public var containerPath: Path?
    public var buildDescriptionID: String?
    public var qos: BuildQoSMessagePayload?
    public var schedulerLaneWidthOverride: UInt32?
    public var jsonRepresentation: Foundation.Data?

    public init(parameters: BuildParametersMessagePayload, configuredTargets: [ConfiguredTargetMessagePayload], dependencyScope: DependencyScopeMessagePayload, continueBuildingAfterErrors: Bool, hideShellScriptEnvironment: Bool, useParallelTargets: Bool, useImplicitDependencies: Bool, useDryRun: Bool, showNonLoggedProgress: Bool, recordBuildBacktraces: Bool?, generatePrecompiledModulesReport: Bool?, buildPlanDiagnosticsDirPath: Path?, buildCommand: BuildCommandMessagePayload, schemeCommand: SchemeCommandMessagePayload?, containerPath: Path?, buildDescriptionID: String?, qos: BuildQoSMessagePayload?, schedulerLaneWidthOverride: UInt32?, jsonRepresentation: Foundation.Data?) {
        self.parameters = parameters
        self.configuredTargets = configuredTargets
        self.dependencyScope = dependencyScope
        self.continueBuildingAfterErrors = continueBuildingAfterErrors
        self.hideShellScriptEnvironment = hideShellScriptEnvironment
        self.useParallelTargets = useParallelTargets
        self.useImplicitDependencies = useImplicitDependencies
        self.useDryRun = useDryRun
        self.showNonLoggedProgress = showNonLoggedProgress
        self.recordBuildBacktraces = recordBuildBacktraces
        self.generatePrecompiledModulesReport = generatePrecompiledModulesReport
        self.buildPlanDiagnosticsDirPath = buildPlanDiagnosticsDirPath
        self.buildCommand = buildCommand
        self.schemeCommand = schemeCommand
        self.containerPath = containerPath
        self.buildDescriptionID = buildDescriptionID
        self.qos = qos
        self.schedulerLaneWidthOverride = schedulerLaneWidthOverride
        self.jsonRepresentation = jsonRepresentation
    }

    enum CodingKeys: CodingKey {
        case parameters
        case configuredTargets
        case dependencyScope
        case continueBuildingAfterErrors
        case hideShellScriptEnvironment
        case useParallelTargets
        case useImplicitDependencies
        case recordBuildBacktraces
        case generatePrecompiledModulesReport
        case useDryRun
        case showNonLoggedProgress
        case buildPlanDiagnosticsDirPath
        case buildCommand
        case schemeCommand
        case containerPath
        case buildDescriptionID
        case qos
        case schedulerLaneWidthOverride
        case jsonRepresentation
    }

    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<BuildRequestMessagePayload.CodingKeys> = try decoder.container(keyedBy: BuildRequestMessagePayload.CodingKeys.self)

        self.parameters = try container.decode(BuildParametersMessagePayload.self, forKey: BuildRequestMessagePayload.CodingKeys.parameters)
        self.configuredTargets = try container.decode([ConfiguredTargetMessagePayload].self, forKey: BuildRequestMessagePayload.CodingKeys.configuredTargets)
        self.dependencyScope = try container.decodeIfPresent(DependencyScopeMessagePayload.self, forKey: BuildRequestMessagePayload.CodingKeys.dependencyScope) ?? .workspace
        self.continueBuildingAfterErrors = try container.decode(Bool.self, forKey: BuildRequestMessagePayload.CodingKeys.continueBuildingAfterErrors)
        self.hideShellScriptEnvironment = try container.decode(Bool.self, forKey: BuildRequestMessagePayload.CodingKeys.hideShellScriptEnvironment)
        self.useParallelTargets = try container.decode(Bool.self, forKey: BuildRequestMessagePayload.CodingKeys.useParallelTargets)
        self.useImplicitDependencies = try container.decode(Bool.self, forKey: BuildRequestMessagePayload.CodingKeys.useImplicitDependencies)
        self.recordBuildBacktraces = try container.decodeIfPresent(Bool.self, forKey: .recordBuildBacktraces)
        self.generatePrecompiledModulesReport = try container.decodeIfPresent(Bool.self, forKey: .generatePrecompiledModulesReport)
        self.useDryRun = try container.decode(Bool.self, forKey: BuildRequestMessagePayload.CodingKeys.useDryRun)
        self.showNonLoggedProgress = try container.decode(Bool.self, forKey: BuildRequestMessagePayload.CodingKeys.showNonLoggedProgress)
        self.buildPlanDiagnosticsDirPath = try container.decodeIfPresent(Path.self, forKey: BuildRequestMessagePayload.CodingKeys.buildPlanDiagnosticsDirPath)
        self.buildCommand = try container.decode(BuildCommandMessagePayload.self, forKey: BuildRequestMessagePayload.CodingKeys.buildCommand)
        self.schemeCommand = try container.decodeIfPresent(SchemeCommandMessagePayload.self, forKey: BuildRequestMessagePayload.CodingKeys.schemeCommand)
        self.containerPath = try container.decodeIfPresent(Path.self, forKey: BuildRequestMessagePayload.CodingKeys.containerPath)
        self.buildDescriptionID = try container.decodeIfPresent(String.self, forKey: BuildRequestMessagePayload.CodingKeys.buildDescriptionID)
        self.qos = try container.decodeIfPresent(BuildQoSMessagePayload.self, forKey: BuildRequestMessagePayload.CodingKeys.qos)
        self.schedulerLaneWidthOverride = try container.decodeIfPresent(UInt32.self, forKey: BuildRequestMessagePayload.CodingKeys.schedulerLaneWidthOverride)
        self.jsonRepresentation = try container.decodeIfPresent(Data.self, forKey: BuildRequestMessagePayload.CodingKeys.jsonRepresentation)

    }

    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<BuildRequestMessagePayload.CodingKeys> = encoder.container(keyedBy: BuildRequestMessagePayload.CodingKeys.self)

        try container.encode(self.parameters, forKey: BuildRequestMessagePayload.CodingKeys.parameters)
        try container.encode(self.configuredTargets, forKey: BuildRequestMessagePayload.CodingKeys.configuredTargets)
        try container.encode(self.dependencyScope, forKey: BuildRequestMessagePayload.CodingKeys.dependencyScope)
        try container.encode(self.continueBuildingAfterErrors, forKey: BuildRequestMessagePayload.CodingKeys.continueBuildingAfterErrors)
        try container.encode(self.hideShellScriptEnvironment, forKey: BuildRequestMessagePayload.CodingKeys.hideShellScriptEnvironment)
        try container.encode(self.useParallelTargets, forKey: BuildRequestMessagePayload.CodingKeys.useParallelTargets)
        try container.encode(self.useImplicitDependencies, forKey: BuildRequestMessagePayload.CodingKeys.useImplicitDependencies)
        try container.encodeIfPresent(self.recordBuildBacktraces, forKey: .recordBuildBacktraces)
        try container.encodeIfPresent(self.generatePrecompiledModulesReport, forKey: .generatePrecompiledModulesReport)
        try container.encode(self.useDryRun, forKey: BuildRequestMessagePayload.CodingKeys.useDryRun)
        try container.encode(self.showNonLoggedProgress, forKey: BuildRequestMessagePayload.CodingKeys.showNonLoggedProgress)
        try container.encodeIfPresent(self.buildPlanDiagnosticsDirPath, forKey: BuildRequestMessagePayload.CodingKeys.buildPlanDiagnosticsDirPath)
        try container.encode(self.buildCommand, forKey: BuildRequestMessagePayload.CodingKeys.buildCommand)
        try container.encodeIfPresent(self.schemeCommand, forKey: BuildRequestMessagePayload.CodingKeys.schemeCommand)
        try container.encodeIfPresent(self.containerPath, forKey: BuildRequestMessagePayload.CodingKeys.containerPath)
        try container.encodeIfPresent(self.buildDescriptionID, forKey: BuildRequestMessagePayload.CodingKeys.buildDescriptionID)
        try container.encodeIfPresent(self.qos, forKey: BuildRequestMessagePayload.CodingKeys.qos)
        try container.encodeIfPresent(self.schedulerLaneWidthOverride, forKey: BuildRequestMessagePayload.CodingKeys.schedulerLaneWidthOverride)
        try container.encodeIfPresent(self.jsonRepresentation, forKey: BuildRequestMessagePayload.CodingKeys.jsonRepresentation)
    }
}

/// The configured target being sent in a Message.
public struct ConfiguredTargetMessagePayload: SerializableCodable, Equatable, Sendable {
    public var guid: String
    public var parameters: BuildParametersMessagePayload?

    public init(guid: String, parameters: BuildParametersMessagePayload?) {
        self.guid = guid
        self.parameters = parameters
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.guid = try deserializer.deserialize()
        self.parameters = try deserializer.deserialize()
    }
}

/// The build parameters being sent in a Message.
public struct BuildParametersMessagePayload: SerializableCodable, Equatable, Sendable {
    public let action: String
    public let configuration: String?
    public let activeRunDestination: RunDestinationInfo?
    public let activeArchitecture: String?
    public let arenaInfo: ArenaInfo?
    public let overrides: SettingsOverridesMessagePayload

    public init(action: String = "", configuration: String? = nil, activeRunDestination: RunDestinationInfo?, activeArchitecture: String?, arenaInfo: ArenaInfo?, overrides: SettingsOverridesMessagePayload) {
        self.action = action
        self.configuration = configuration
        self.activeRunDestination = activeRunDestination
        self.activeArchitecture = activeArchitecture
        self.arenaInfo = arenaInfo
        self.overrides = overrides
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        self.action = try deserializer.deserialize()
        self.configuration = try deserializer.deserialize()
        self.activeRunDestination = try deserializer.deserialize()
        self.activeArchitecture = try deserializer.deserialize()
        self.arenaInfo = try deserializer.deserialize()
        self.overrides = try deserializer.deserialize()
        if !deserializer.deserializeNil() {
            try deserializer.beginAggregate(5)
            _ = try deserializer.deserialize() as String
            _ = try deserializer.deserialize() as String
            _ = try deserializer.deserialize() as String?
            _ = try deserializer.deserialize() as Int?
            _ = try deserializer.deserialize() as String?
        }
    }
}

public struct RunDestinationInfo: SerializableCodable, Hashable, Sendable {
    public var buildTarget: BuildTarget

    public var targetArchitecture: String
    public var supportedArchitectures: OrderedSet<String>
    public var disableOnlyActiveArch: Bool
    public var hostTargetedPlatform: String?

    public init(buildTarget: BuildTarget, targetArchitecture: String, supportedArchitectures: OrderedSet<String>, disableOnlyActiveArch: Bool, hostTargetedPlatform: String? = nil) {
        self.buildTarget = buildTarget
        self.targetArchitecture = targetArchitecture
        self.supportedArchitectures = supportedArchitectures
        self.disableOnlyActiveArch = disableOnlyActiveArch
        self.hostTargetedPlatform = hostTargetedPlatform
    }

    public enum CodingKeys: CodingKey {
        case buildTarget
        case targetArchitecture
        case supportedArchitectures
        case disableOnlyActiveArch
        case hostTargetedPlatform

        // These are the old coding keys that were previously associated with toolchain SDK's
        case platform
        case sdk
        case sdkVariant
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let buildTarget = try container.decodeIfPresent(BuildTarget.self, forKey: .buildTarget) {
            self.buildTarget = buildTarget
        } else {
            // Handle the message payload from earlier versions that didn't have the buildTarget enumeration
            let platform = try container.decode(String.self, forKey: .platform)
            let sdk: String = try container.decode(String.self, forKey: .sdk)
            let sdkVariant: String? = try container.decode(String?.self, forKey: .sdkVariant)
            self.buildTarget = .toolchainSDK(platform: platform, sdk: sdk, sdkVariant: sdkVariant)
        }

        self.targetArchitecture = try container.decode(String.self, forKey: .targetArchitecture)
        self.supportedArchitectures = try container.decode(OrderedSet.self, forKey: .supportedArchitectures)
        self.disableOnlyActiveArch = try container.decode(Bool.self, forKey: .disableOnlyActiveArch)
        self.hostTargetedPlatform = try container.decodeIfPresent(String.self, forKey: .hostTargetedPlatform)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self.buildTarget {
        case let .toolchainSDK(platform: platform, sdk: sdk, sdkVariant: sdkVariant):
            try container.encode(platform, forKey: .platform)
            try container.encode(sdk, forKey: .sdk)
            try container.encode(sdkVariant, forKey: .sdkVariant)
        case .swiftSDK:
            try container.encode(buildTarget, forKey: .buildTarget)
        }

        try container.encode(self.targetArchitecture, forKey: .targetArchitecture)
        try container.encode(self.supportedArchitectures, forKey: .supportedArchitectures)
        try container.encode(self.disableOnlyActiveArch, forKey: .disableOnlyActiveArch)
        try container.encode(self.hostTargetedPlatform, forKey: .hostTargetedPlatform)
    }
}

public enum BuildTarget: SerializableCodable, Hashable, Sendable {
    case toolchainSDK(platform: String, sdk: String, sdkVariant: String?)
    case swiftSDK(sdkManifestPath: String, triple: String)
}

/// The arena info being sent in a Message.
public struct ArenaInfo: SerializableCodable, Hashable, Sendable {
    public var derivedDataPath: Path
    public var buildProductsPath: Path
    public var buildIntermediatesPath: Path
    public var pchPath: Path

    public var indexRegularBuildProductsPath: Path?
    public var indexRegularBuildIntermediatesPath: Path?
    public var indexPCHPath: Path
    public var indexDataStoreFolderPath: Path?
    public var indexEnableDataStore: Bool

    public init(derivedDataPath: Path, buildProductsPath: Path, buildIntermediatesPath: Path, pchPath: Path, indexRegularBuildProductsPath: Path?, indexRegularBuildIntermediatesPath: Path?, indexPCHPath: Path, indexDataStoreFolderPath: Path?, indexEnableDataStore: Bool) {
        self.derivedDataPath = derivedDataPath
        self.buildProductsPath = buildProductsPath
        self.buildIntermediatesPath = buildIntermediatesPath
        self.pchPath = pchPath

        self.indexRegularBuildProductsPath = indexRegularBuildProductsPath
        self.indexRegularBuildIntermediatesPath = indexRegularBuildIntermediatesPath
        self.indexPCHPath = indexPCHPath
        self.indexDataStoreFolderPath = indexDataStoreFolderPath
        self.indexEnableDataStore = indexEnableDataStore
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        self.derivedDataPath = try deserializer.deserialize()
        self.buildProductsPath = try deserializer.deserialize()
        self.buildIntermediatesPath = try deserializer.deserialize()

        self.pchPath = try deserializer.deserialize()
        self.indexPCHPath = try deserializer.deserialize()
        self.indexDataStoreFolderPath = try deserializer.deserialize()
        self.indexEnableDataStore = try deserializer.deserialize()
    }
}

/// The build settings overrides being sent in a Message.
public struct SettingsOverridesMessagePayload: SerializableCodable, Equatable, Sendable {
    public let synthesized: [String: String]
    public let commandLine: [String: String]
    public let commandLineConfigPath: Path?
    public let commandLineConfig: [String: String]
    public let environmentConfigPath: Path?
    public let environmentConfig: [String: String]
    public let toolchainOverride: String?

    public init(synthesized: [String: String], commandLine: [String: String], commandLineConfigPath: Path?, commandLineConfig: [String: String], environmentConfigPath: Path?, environmentConfig: [String: String], toolchainOverride: String?) {
        self.synthesized = synthesized
        self.commandLine = commandLine
        self.commandLineConfigPath = commandLineConfigPath
        self.commandLineConfig = commandLineConfig
        self.environmentConfigPath = environmentConfigPath
        self.environmentConfig = environmentConfig
        self.toolchainOverride = toolchainOverride
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        self.synthesized = try deserializer.deserialize()
        self.commandLine = try deserializer.deserialize()
        self.commandLineConfigPath = nil
        self.commandLineConfig = try deserializer.deserialize()
        self.environmentConfigPath = nil
        self.environmentConfig = try deserializer.deserialize()
        self.toolchainOverride = try deserializer.deserialize()
    }
}

public struct PreviewInfoContext: Codable, Equatable, Sendable {
    public let sdkRoot: String
    public let sdkVariant: String?
    public let buildVariant: String
    public let architecture: String

    public let pifGUID: String

    public init(sdkRoot: String, sdkVariant: String?, buildVariant: String, architecture: String, pifGUID: String) {
        self.sdkRoot = sdkRoot
        self.sdkVariant = sdkVariant
        self.buildVariant = buildVariant
        self.architecture = architecture
        self.pifGUID = pifGUID
    }
}

public struct PreviewInfoThunkInfo: Codable, Equatable, Sendable {
    public let compileCommandLine: [String]
    public let linkCommandLine: [String]

    public let thunkSourceFile: Path
    public let thunkObjectFile: Path
    public let thunkLibrary: Path

    public init(compileCommandLine: [String], linkCommandLine: [String], thunkSourceFile: Path, thunkObjectFile: Path, thunkLibrary: Path) {
        self.compileCommandLine = compileCommandLine
        self.linkCommandLine = linkCommandLine
        self.thunkSourceFile = thunkSourceFile
        self.thunkObjectFile = thunkObjectFile
        self.thunkLibrary = thunkLibrary
    }
}

public struct PreviewInfoTargetDependencyInfo: Codable, Equatable, Sendable {
    public let productModuleName: String
    public let objectFileInputMap: [String: Set<String>]
    public let linkCommandLine: [String]
    public let linkerWorkingDirectory: String?
    public let swiftEnableOpaqueTypeErasure: Bool
    public let swiftUseIntegratedDriver: Bool
    public let enableJITPreviews: Bool
    public let enableDebugDylib: Bool
    public let enableAddressSanitizer: Bool
    public let enableThreadSanitizer: Bool
    public let enableUndefinedBehaviorSanitizer: Bool
    public let enableMemoryTaggingAddressSanitizer: Bool

    public init(
        productModuleName: String,
        objectFileInputMap: [String : Set<String>],
        linkCommandLine: [String],
        linkerWorkingDirectory: String?,
        swiftEnableOpaqueTypeErasure: Bool,
        swiftUseIntegratedDriver: Bool,
        enableJITPreviews: Bool,
        enableDebugDylib: Bool,
        enableAddressSanitizer: Bool,
        enableThreadSanitizer: Bool,
        enableUndefinedBehaviorSanitizer: Bool,
        enableMemoryTaggingAddressSanitizer: Bool,
    ) {
        self.productModuleName = productModuleName
        self.objectFileInputMap = objectFileInputMap
        self.linkCommandLine = linkCommandLine
        self.linkerWorkingDirectory = linkerWorkingDirectory
        self.swiftEnableOpaqueTypeErasure = swiftEnableOpaqueTypeErasure
        self.swiftUseIntegratedDriver = swiftUseIntegratedDriver
        self.enableJITPreviews = enableJITPreviews
        self.enableDebugDylib = enableDebugDylib
        self.enableAddressSanitizer = enableAddressSanitizer
        self.enableThreadSanitizer = enableThreadSanitizer
        self.enableUndefinedBehaviorSanitizer = enableUndefinedBehaviorSanitizer
        self.enableMemoryTaggingAddressSanitizer = enableMemoryTaggingAddressSanitizer
    }
}

/// The preview-information being sent in a Message.
public struct PreviewInfoMessagePayload: SerializableCodable, Equatable, Sendable {
    public let context: PreviewInfoContext

    public enum Kind: Codable, Equatable, Sendable {
        case thunkInfo(PreviewInfoThunkInfo)
        case targetDependencyInfo(PreviewInfoTargetDependencyInfo)
    }

    public let kind: Kind

    public init(context: PreviewInfoContext, kind: Kind) {
        self.context = context
        self.kind = kind
    }
}

/// The documentation information being sent in a Message.
///
/// For a description of how this feature works, see the `SWBBuildServiceSession.generateDocumentationInfo` documentation.
public struct DocumentationInfoMessagePayload: SerializableCodable, Equatable, Sendable {
    /// The output path where the built documentation will be written.
    public let outputPath: Path
    /// The identifier of the target associated with the docs we built.
    public let targetIdentifier: String?

    public init(outputPath: Path, targetIdentifier: String?) {
        self.outputPath = outputPath
        self.targetIdentifier = targetIdentifier
    }

    public init(fromLegacy deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        self.outputPath = try deserializer.deserialize()
        self.targetIdentifier = nil
    }
}

/// Describes attributes of a portion of a build, for example platform and architecture, that are relevant to distinguishing localized strings extracted during a build.
public struct LocalizationInfoBuildPortion: SerializableCodable, Hashable, Sendable {
    /// The name of the platform we were building for.
    ///
    /// Mac Catalyst is treated as its own platform.
    public let effectivePlatformName: String

    /// The name of the build variant, e.g. "normal"
    public let variant: String

    /// The name of the architecture we were building for.
    public let architecture: String

    public init(effectivePlatformName: String, variant: String, architecture: String) {
        self.effectivePlatformName = effectivePlatformName
        self.variant = variant
        self.architecture = architecture
    }
}

/// The localization info for a specific Target being sent in a Message.
public struct LocalizationInfoMessagePayload: SerializableCodable, Equatable, Sendable {
    /// The target GUID (not the ConfiguredTarget guid).
    public let targetIdentifier: String

    /// Paths to source .xcstrings files used as inputs in this target.
    ///
    /// This collection specifically contains compilable files, AKA files in a Resources phase (not a Copy Files phase).
    public let compilableXCStringsPaths: Set<Path>

    /// Paths to .stringsdata files produced by this target, grouped by build attributes such as platform and architecture.
    public let producedStringsdataPaths: [LocalizationInfoBuildPortion: Set<Path>]

    /// The name of the primary platform we were building for.
    ///
    /// Mac Catalyst is treated as its own platform.
    public let effectivePlatformName: String?

    /// Paths to generated source code files holding string symbols, keyed by xcstrings file path.
    public var generatedSymbolFilesByXCStringsPath = [Path: Set<Path>]()

    public init(targetIdentifier: String,
                compilableXCStringsPaths: Set<Path>,
                producedStringsdataPaths: [LocalizationInfoBuildPortion: Set<Path>],
                effectivePlatformName: String?) {
        self.targetIdentifier = targetIdentifier
        self.compilableXCStringsPaths = compilableXCStringsPaths
        self.producedStringsdataPaths = producedStringsdataPaths
        self.effectivePlatformName = effectivePlatformName
    }
}
