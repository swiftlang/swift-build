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

public class BuildPhase: PolymorphicSerializable, @unchecked Sendable {
    public static let implementations: [SerializableTypeCode : any PolymorphicSerializable.Type] = [
        0: AppleScriptBuildPhase.self,
        1: CopyFilesBuildPhase.self,
        2: FrameworksBuildPhase.self,
        3: HeadersBuildPhase.self,
        4: JavaArchiveBuildPhase.self,
        5: ResourcesBuildPhase.self,
        6: RezBuildPhase.self,
        7: ShellScriptBuildPhase.self,
        8: SourcesBuildPhase.self,
    ]

    public let guid: String

    public init(guid: String) {
        self.guid = guid
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serialize(guid)
    }

    public required init(from deserializer: any Deserializer) throws {
        self.guid = try deserializer.deserialize()
    }
}

public class BuildPhaseWithBuildFiles: BuildPhase, @unchecked Sendable {
    public let buildFiles: [BuildFile]

    public init(guid: String, buildFiles: [BuildFile]) {
        self.buildFiles = buildFiles
        super.init(guid: guid)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(buildFiles)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.buildFiles = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

public final class AppleScriptBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable {}
public final class FrameworksBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable {}
public final class HeadersBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable {}
public final class JavaArchiveBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable {}
public final class ResourcesBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable {}
public final class RezBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable {}
public final class SourcesBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable {}

public final class CopyFilesBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable {
    public let destinationSubfolder: MacroExpressionSource
    public let destinationSubpath: MacroExpressionSource
    public let runOnlyForDeploymentPostprocessing: Bool

    public init(guid: String, buildFiles: [BuildFile], destinationSubfolder: MacroExpressionSource, destinationSubpath: MacroExpressionSource, runOnlyForDeploymentPostprocessing: Bool) {
        self.destinationSubfolder = destinationSubfolder
        self.destinationSubpath = destinationSubpath
        self.runOnlyForDeploymentPostprocessing = runOnlyForDeploymentPostprocessing
        super.init(guid: guid, buildFiles: buildFiles)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(destinationSubfolder)
            serializer.serialize(destinationSubpath)
            serializer.serialize(runOnlyForDeploymentPostprocessing)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.destinationSubfolder = try deserializer.deserialize()
        self.destinationSubpath = try deserializer.deserialize()
        self.runOnlyForDeploymentPostprocessing = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

public enum SandboxingOverride: Int, Serializable, Sendable, Codable {
    case forceDisabled = 0
    case forceEnabled = 1
    case basedOnBuildSetting = 2
}

public final class ShellScriptBuildPhase: BuildPhase, @unchecked Sendable {
    public let name: String
    // FIXME: This should be a MacroExpressionSource
    public let shellPath: Path
    public let scriptContents: String
    public let originalObjectID: String
    public let inputFilePaths: [MacroExpressionSource]
    public let inputFileListPaths: [MacroExpressionSource]
    public let outputFilePaths: [MacroExpressionSource]
    public let outputFileListPaths: [MacroExpressionSource]
    public let emitEnvironment: Bool
    public let sandboxingOverride: SWBProtocol.SandboxingOverride
    public let runOnlyForDeploymentPostprocessing: Bool
    public let dependencyInfo: SWBProtocol.DependencyInfo?
    public let alwaysOutOfDate: Bool
    public let alwaysRunForInstallHdrs: Bool

    public init(guid: String, name: String, shellPath: Path, scriptContents: String, originalObjectID: String, inputFilePaths: [MacroExpressionSource], inputFileListPaths: [MacroExpressionSource], outputFilePaths: [MacroExpressionSource], outputFileListPaths: [MacroExpressionSource], emitEnvironment: Bool, runOnlyForDeploymentPostprocessing: Bool, dependencyInfo: SWBProtocol.DependencyInfo? = nil, alwaysOutOfDate: Bool = false, sandboxingOverride: SandboxingOverride = .basedOnBuildSetting, alwaysRunForInstallHdrs: Bool = false) {
        self.name = name
        self.shellPath = shellPath
        self.scriptContents = scriptContents
        self.originalObjectID = originalObjectID
        self.inputFilePaths = inputFilePaths
        self.inputFileListPaths = inputFileListPaths
        self.outputFilePaths = outputFilePaths
        self.outputFileListPaths = outputFileListPaths
        self.emitEnvironment = emitEnvironment
        self.sandboxingOverride = sandboxingOverride
        self.runOnlyForDeploymentPostprocessing = runOnlyForDeploymentPostprocessing
        self.dependencyInfo = dependencyInfo
        self.alwaysOutOfDate = alwaysOutOfDate
        self.alwaysRunForInstallHdrs = alwaysRunForInstallHdrs
        super.init(guid: guid)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(15) {
            serializer.serialize(name)
            serializer.serialize(shellPath)
            serializer.serialize(scriptContents)
            serializer.serialize(originalObjectID)
            serializer.serialize(inputFilePaths)
            serializer.serialize(inputFileListPaths)
            serializer.serialize(outputFilePaths)
            serializer.serialize(outputFileListPaths)
            serializer.serialize(emitEnvironment)
            serializer.serialize(sandboxingOverride)
            serializer.serialize(runOnlyForDeploymentPostprocessing)
            serializer.serialize(dependencyInfo)
            serializer.serialize(alwaysOutOfDate)
            serializer.serialize(alwaysRunForInstallHdrs)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(15)
        self.name = try deserializer.deserialize()
        self.shellPath = try deserializer.deserialize()
        self.scriptContents = try deserializer.deserialize()
        self.originalObjectID = try deserializer.deserialize()
        self.inputFilePaths = try deserializer.deserialize()
        self.inputFileListPaths = try deserializer.deserialize()
        self.outputFilePaths = try deserializer.deserialize()
        self.outputFileListPaths = try deserializer.deserialize()
        self.emitEnvironment = try deserializer.deserialize()
        self.sandboxingOverride = try deserializer.deserialize()
        self.runOnlyForDeploymentPostprocessing = try deserializer.deserialize()
        self.dependencyInfo = try deserializer.deserialize()
        self.alwaysOutOfDate = try deserializer.deserialize()
        self.alwaysRunForInstallHdrs = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}
