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

public struct Project: Sendable {
    public let guid: String
    public let isPackage: Bool
    public let xcodeprojPath: Path
    public let sourceRoot: Path
    public let targetSignatures: [String]
    public let groupTree: FileGroup
    public let buildConfigurations: [BuildConfiguration]
    public let defaultConfigurationName: String
    public let developmentRegion: String?
    public let knownLocalizations: [String]?
    public let classPrefix: String
    public let appPreferencesBuildSettings: [BuildConfiguration.MacroBindingSource]

    public init(guid: String, isPackage: Bool, xcodeprojPath: Path, sourceRoot: Path, targetSignatures: [String], groupTree: FileGroup, buildConfigurations: [BuildConfiguration], defaultConfigurationName: String, developmentRegion: String?, knownLocalizations: [String]?, classPrefix: String, appPreferencesBuildSettings: [BuildConfiguration.MacroBindingSource] = []) {
        self.guid = guid
        self.isPackage = isPackage
        self.xcodeprojPath = xcodeprojPath
        self.sourceRoot = sourceRoot
        self.targetSignatures = targetSignatures
        self.groupTree = groupTree
        self.buildConfigurations = buildConfigurations
        self.defaultConfigurationName = defaultConfigurationName
        self.developmentRegion = developmentRegion
        self.knownLocalizations = knownLocalizations
        self.classPrefix = classPrefix
        self.appPreferencesBuildSettings = appPreferencesBuildSettings
    }
}

// MARK: SerializableCodable

extension Project: Serializable {
    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(12) {
            serializer.serialize(guid)
            serializer.serialize(isPackage)
            serializer.serialize(xcodeprojPath)
            serializer.serialize(sourceRoot)
            serializer.serialize(targetSignatures)
            serializer.serialize(groupTree)
            serializer.serialize(buildConfigurations)
            serializer.serialize(defaultConfigurationName)
            serializer.serialize(developmentRegion)
            serializer.serialize(knownLocalizations)
            serializer.serialize(classPrefix)
            serializer.serialize(appPreferencesBuildSettings)
        }
    }

    public init(from deserializer: any Deserializer) throws {
        let count = try deserializer.beginAggregate(11...12)
        self.guid = try deserializer.deserialize()
        self.isPackage = try deserializer.deserialize()
        self.xcodeprojPath = try deserializer.deserialize()
        self.sourceRoot = try deserializer.deserialize()
        self.targetSignatures = try deserializer.deserialize()
        self.groupTree = try deserializer.deserialize()
        self.buildConfigurations = try deserializer.deserialize()
        self.defaultConfigurationName = try deserializer.deserialize()
        self.developmentRegion = try deserializer.deserialize()
        if count >= 12 {
            self.knownLocalizations = try deserializer.deserialize()
        } else {
            self.knownLocalizations = nil
        }
        self.classPrefix = try deserializer.deserialize()
        self.appPreferencesBuildSettings = try deserializer.deserialize()
    }
}
