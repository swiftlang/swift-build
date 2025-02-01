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

extension ProjectModel {
    /// All possible build phases in a target.
    public enum BuildPhase: Sendable, Hashable {
        case headers(HeadersBuildPhase)
        case sources(SourcesBuildPhase)
        case frameworks(FrameworksBuildPhase)
        case copyBundleResources(CopyBundleResourcesBuildPhase)
        case copyFiles(CopyFilesBuildPhase)
        case shellScript(ShellScriptBuildPhase)

        var common: BuildPhaseCommon {
            switch self {
            case .headers(let phase): return phase.common
            case .sources(let phase): return phase.common
            case .frameworks(let phase): return phase.common
            case .copyBundleResources(let phase): return phase.common
            case .copyFiles(let phase): return phase.common
            case .shellScript(let phase): return phase.common
            }
        }
    }

    public struct BuildPhaseCommon: Sendable, Hashable {
        public var id: GUID
        public fileprivate(set) var files: [BuildFile]

        public init(id: GUID, files: [BuildFile] = []) {
            self.id = id
            self.files = files
        }

        private var nextBuildFileId: GUID {
            return "\(self.id.value)::\(self.files.count)"
        }

        // MARK: - BuildFile

        @discardableResult public mutating func addBuildFile(_ create: CreateFn<BuildFile>) -> BuildFile {
            let buildFile = create(nextBuildFileId)
            self.files.append(buildFile)
            return buildFile
        }

        public subscript(file tag: Tag<BuildFile>) -> BuildFile {
            get { files[id: tag.value] }
            set { files[id: tag.value] = newValue }
        }

    }

    /// A "headers" build phase, i.e. one that copies headers into a directory of the product, after suitable processing.
    public struct HeadersBuildPhase: Sendable, Hashable, Common {
        public var common: BuildPhaseCommon

        public init(id: GUID, files: [BuildFile] = []) {
            self.common = BuildPhaseCommon(id: id, files: files)
        }
    }

    /// A "sources" build phase, i.e. one that compiles sources and provides them to be linked into the executable code of the product.
    public struct SourcesBuildPhase: Sendable, Hashable, Common {
        public var common: BuildPhaseCommon

        public init(id: GUID, files: [BuildFile] = []) {
            self.common = BuildPhaseCommon(id: id, files: files)
        }
    }

    /// A "frameworks" build phase, i.e. one that links compiled code and libraries into the executable of the product.
    public struct FrameworksBuildPhase: Sendable, Hashable, Common {
        public var common: BuildPhaseCommon

        public init(id: GUID, files: [BuildFile] = []) {
            self.common = BuildPhaseCommon(id: id, files: files)
        }
    }

    public struct CopyBundleResourcesBuildPhase: Sendable, Hashable, Common {
        public var common: BuildPhaseCommon

        public init(id: GUID) {
            self.common = BuildPhaseCommon(id: id)
        }
    }

    /// A "copy files" build phase, i.e. one that copies files to an arbitrary location relative to the product.
    public struct CopyFilesBuildPhase: Sendable, Hashable, Common {
        public enum DestinationSubfolder: Sendable, Hashable, Codable {
            case absolute
            case builtProductsDir
            case buildSetting(String)

            public static let wrapper = DestinationSubfolder.buildSetting("$(WRAPPER_NAME)")
            public static let resources = DestinationSubfolder.buildSetting("$(UNLOCALIZED_RESOURCES_FOLDER_PATH)")
            public static let frameworks = DestinationSubfolder.buildSetting("$(FRAMEWORKS_FOLDER_PATH)")
            public static let sharedFrameworks = DestinationSubfolder.buildSetting("$(SHARED_FRAMEWORKS_FOLDER_PATH)")
            public static let sharedSupport = DestinationSubfolder.buildSetting("$(SHARED_SUPPORT_FOLDER_PATH)")
            public static let plugins = DestinationSubfolder.buildSetting("$(PLUGINS_FOLDER_PATH)")
            public static let javaResources = DestinationSubfolder.buildSetting("$(JAVA_FOLDER_PATH)")

            public var pathString: String {
                switch self {
                case .absolute:
                    return "<absolute>"
                case .builtProductsDir:
                    return "<builtProductsDir>"
                case .buildSetting(let value):
                    return value
                }
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                let str = try container.decode(String.self)
                switch str {
                case "<absolute>": self = .absolute
                case "<builtProductsDir>": self = .builtProductsDir
                default: self = .buildSetting(str)
                }
            }

            public func encode(to encoder: any Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(self.pathString)
            }
        }

        public var common: BuildPhaseCommon
        public var destinationSubfolder: CopyFilesBuildPhase.DestinationSubfolder
        public var destinationSubpath: String = ""
        public var runOnlyForDeploymentPostprocessing: Bool = false

        public init(common: BuildPhaseCommon, destinationSubfolder: CopyFilesBuildPhase.DestinationSubfolder, destinationSubpath: String = "", runOnlyForDeploymentPostprocessing: Bool = false) {
            self.common = common
            self.destinationSubfolder = destinationSubfolder
            self.destinationSubpath = destinationSubpath
            self.runOnlyForDeploymentPostprocessing = runOnlyForDeploymentPostprocessing
        }
    }

    /// A "shell script" build phase, i.e. one that runs a custom shell script.
    public struct ShellScriptBuildPhase: Sendable, Hashable, Common {
        public var common: BuildPhaseCommon
        public var name: String
        public var scriptContents: String
        public var shellPath: String
        public var inputPaths: [String]
        public var outputPaths: [String]
        public var emitEnvironment: Bool
        public var alwaysOutOfDate: Bool
        public var runOnlyForDeploymentPostprocessing: Bool
        public var originalObjectID: String
        public var sandboxingOverride: SandboxingOverride
        public var alwaysRunForInstallHdrs: Bool

        public init(
            id: GUID,
            name: String,
            scriptContents: String,
            shellPath: String,
            inputPaths: [String],
            outputPaths: [String],
            emitEnvironment: Bool,
            alwaysOutOfDate: Bool,
            runOnlyForDeploymentPostprocessing: Bool = false,
            originalObjectID: String,
            sandboxingOverride: SandboxingOverride = .basedOnBuildSetting,
            alwaysRunForInstallHdrs: Bool = false
        ) {
            self.common = BuildPhaseCommon(id: id)
            self.name = name
            self.scriptContents = scriptContents
            self.shellPath = shellPath
            self.inputPaths = inputPaths
            self.outputPaths = outputPaths
            self.emitEnvironment = emitEnvironment
            self.alwaysOutOfDate = alwaysOutOfDate
            self.runOnlyForDeploymentPostprocessing = runOnlyForDeploymentPostprocessing
            self.originalObjectID = originalObjectID
            self.sandboxingOverride = sandboxingOverride
            self.alwaysRunForInstallHdrs = alwaysRunForInstallHdrs
        }
    }
}



extension ProjectModel.BuildPhase: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "com.apple.buildphase.headers":
            self = .headers(try .init(from: decoder))
        case "com.apple.buildphase.sources":
            self = .sources(try .init(from: decoder))
        case "com.apple.buildphase.frameworks":
            self = .frameworks(try .init(from: decoder))
        case "com.apple.buildphase.resources":
            self = .copyBundleResources(try .init(from: decoder))
        case "com.apple.buildphase.copy-files":
            self = .copyFiles(try .init(from: decoder))
        case "com.apple.buildphase.shell-script":
            self = .shellScript(try .init(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .headers(let buildPhase): try buildPhase.encode(to: encoder)
        case .sources(let buildPhase): try buildPhase.encode(to: encoder)
        case .frameworks(let buildPhase): try buildPhase.encode(to: encoder)
        case .copyBundleResources(let buildPhase): try buildPhase.encode(to: encoder)
        case .copyFiles(let buildPhase): try buildPhase.encode(to: encoder)
        case .shellScript(let buildPhase): try buildPhase.encode(to: encoder)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
    }
}

extension ProjectModel.BuildPhaseCommon: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        self.files = try container.decode([ProjectModel.BuildFile].self, forKey: .buildFiles)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.files, forKey: .buildFiles)
    }

    enum CodingKeys: String, CodingKey {
        case guid
        case buildFiles
    }
}

extension ProjectModel.HeadersBuildPhase: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        let files = try container.decode([ProjectModel.BuildFile].self, forKey: .buildFiles)
        self.common = .init(id: id, files: files)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("com.apple.buildphase.headers", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.files, forKey: .buildFiles)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case guid
        case buildFiles
    }
}

extension ProjectModel.SourcesBuildPhase: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        let files = try container.decode([ProjectModel.BuildFile].self, forKey: .buildFiles)
        self.common = .init(id: id, files: files)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("com.apple.buildphase.sources", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.files, forKey: .buildFiles)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case guid
        case buildFiles
    }
}

extension ProjectModel.FrameworksBuildPhase: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        let files = try container.decode([ProjectModel.BuildFile].self, forKey: .buildFiles)
        self.common = .init(id: id, files: files)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("com.apple.buildphase.frameworks", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.files, forKey: .buildFiles)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case guid
        case buildFiles
    }
}

extension ProjectModel.CopyBundleResourcesBuildPhase: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        let files = try container.decode([ProjectModel.BuildFile].self, forKey: .buildFiles)
        self.common = .init(id: id, files: files)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("com.apple.buildphase.resources", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.files, forKey: .buildFiles)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case guid
        case buildFiles
    }
}

extension ProjectModel.CopyFilesBuildPhase: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.common = .init(id: try container.decode(ProjectModel.GUID.self, forKey: .guid))
        self.destinationSubfolder = try container.decode(DestinationSubfolder.self, forKey: .destinationSubfolder)
        self.files = try container.decode([ProjectModel.BuildFile].self, forKey: .buildFiles)
        self.destinationSubpath = try container.decode(String.self, forKey: .destinationSubpath)
        self.runOnlyForDeploymentPostprocessing = try container.decode(String.self, forKey: .runOnlyForDeploymentPostprocessing) == "true"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("com.apple.buildphase.copy-files", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.files, forKey: .buildFiles)
        try container.encode(self.destinationSubfolder.pathString, forKey: .destinationSubfolder)
        try container.encode(self.destinationSubpath, forKey: .destinationSubpath)
        try container.encode(self.runOnlyForDeploymentPostprocessing ? "true" : "false", forKey: .runOnlyForDeploymentPostprocessing)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case guid
        case buildFiles
        case destinationSubfolder
        case destinationSubpath
        case runOnlyForDeploymentPostprocessing
    }
}

extension ProjectModel.ShellScriptBuildPhase: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ProjectModel.GUID.self, forKey: .guid)
        let files = try container.decode([ProjectModel.BuildFile].self, forKey: .buildFiles)
        self.common = .init(id: id, files: files)

        self.name = try container.decode(String.self, forKey: .name)
        self.shellPath = try container.decode(String.self, forKey: .shellPath)
        self.scriptContents = try container.decode(String.self, forKey: .scriptContents)
        self.inputPaths = try container.decode([String].self, forKey: .inputFilePaths)
        self.outputPaths = try container.decode([String].self, forKey: .outputFilePaths)
        self.emitEnvironment = try container.decode(String.self, forKey: .emitEnvironment) == "true"
        self.sandboxingOverride = try container.decode(ProjectModel.SandboxingOverride.self, forKey: .sandboxingOverride)
        self.alwaysOutOfDate = try container.decode(String.self, forKey: .alwaysOutOfDate) == "true"
        self.runOnlyForDeploymentPostprocessing = try container.decode(String.self, forKey: .runOnlyForDeploymentPostprocessing) == "true"
        self.originalObjectID = try container.decode(String.self, forKey: .originalObjectID)
        self.alwaysRunForInstallHdrs = try container.decode(String.self, forKey: .alwaysRunForInstallHdrs) == "true"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("com.apple.buildphase.shell-script", forKey: .type)
        try container.encode(self.id, forKey: .guid)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.shellPath, forKey: .shellPath)
        try container.encode(self.scriptContents, forKey: .scriptContents)
        try container.encode(self.files, forKey: .buildFiles)
        try container.encode(self.inputPaths, forKey: .inputFilePaths)
        try container.encode(self.outputPaths, forKey: .outputFilePaths)
        try container.encode(self.emitEnvironment ? "true" : "false", forKey: .emitEnvironment)
        try container.encode(self.sandboxingOverride, forKey: .sandboxingOverride)
        try container.encode(self.alwaysOutOfDate ? "true" : "false", forKey: .alwaysOutOfDate)
        try container.encode(self.runOnlyForDeploymentPostprocessing ? "true" : "false", forKey: .runOnlyForDeploymentPostprocessing)
        try container.encode(self.originalObjectID, forKey: .originalObjectID)
        try container.encode(self.alwaysRunForInstallHdrs ? "true" : "false", forKey: .alwaysRunForInstallHdrs)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case guid
        case name
        case shellPath
        case scriptContents
        case buildFiles
        case inputFilePaths
        case outputFilePaths
        case emitEnvironment
        case sandboxingOverride
        case alwaysOutOfDate
        case runOnlyForDeploymentPostprocessing
        case originalObjectID
        case alwaysRunForInstallHdrs
    }
}

