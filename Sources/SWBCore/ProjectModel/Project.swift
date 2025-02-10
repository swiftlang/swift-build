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

import SWBProtocol
public import SWBUtil

public final class Project: ProjectModelItem, PIFObject, Hashable, Encodable
{
    static func referencedObjects(for data: EncodedPIFValue) throws -> [PIFObjectReference] {
        // Any errors here will be diagnosed in the loader.
        switch data {
        case .json(let data):
            guard case let .plArray(projects)? = data["targets"] else { return [] }
            return projects.compactMap{
                guard case let .plString(signature) = $0 else { return nil }
                return PIFObjectReference(signature: signature, type: .target)
            }

        case .binary(let data):
            // The only direct references are to targets.
            //
            // FIXME: This sucks, we are doing the protocol decode twice: <rdar://problem/31097863> Don't require duplicate binary PIF decode in incremental PIF transfer
            let deserializer = MsgPackDeserializer(data)
            let model: SWBProtocol.Project = try deserializer.deserialize()
            return model.targetSignatures.map{ PIFObjectReference(signature: $0, type: .target) }
        }
    }

    static func construct(from data: EncodedPIFValue, signature: PIFObject.Signature, loader: PIFLoader) throws -> Project {
        switch data {
        case .json(let data):
            return try construct(from: data, signature: signature, loader: loader)
        case .binary(let data):
            let deserializer = MsgPackDeserializer(data)
            let model: SWBProtocol.Project = try deserializer.deserialize()
            return try Project(model, loader, signature: signature)
        }
    }

    /// The PIFObject type name
    static let pifType = PIFObjectType.project

    /// A unique signature for the instance.
    public let signature: String

    public let guid: String

    /// The path to the project's .xcodeproj file.
    public let xcodeprojPath: Path

    /// The source root for the project.
    public let sourceRoot: Path

    /// The name of the project.
    public let name: String

    public let targets: [Target]
    public let groupTree: FileGroup
    public let buildConfigurations: [BuildConfiguration]
    public let defaultConfigurationName: String
    public let developmentRegion: String?
    public let classPrefix: String
    public let appPreferencesBuildSettings: [String: PropertyListItem]
    public let isPackage: Bool

    private enum CodingKeys : String, CodingKey {
        case name
        case signature
        case guid
        case targets
    }

    static func construct(from data: ProjectModelItemPIF, signature: PIFObject.Signature, loader: PIFLoader) throws -> Project {
        // Delegate to protocol-based representation, if in use.
        if let data = try parseOptionalValueForKeyAsByteString("data", pifDict: data) {
            let deserializer = MsgPackDeserializer(data)
            let model: SWBProtocol.Project = try deserializer.deserialize()
            return try Project(model, loader, signature: signature)
        }
        return try Project(fromDictionary: data, signature: signature, withPIFLoader: loader)
    }

    init(_ model: SWBProtocol.Project, _ pifLoader: PIFLoader, signature: String) throws {
        self.signature = signature
        self.guid = model.guid
        self.isPackage = model.isPackage
        self.xcodeprojPath = model.xcodeprojPath
        self.sourceRoot = model.sourceRoot
        self.targets = try model.targetSignatures.map{ try pifLoader.loadReference(signature: $0, type: Target.self) }
        self.groupTree = try Reference.create(model.groupTree, pifLoader, isRoot: true) as! FileGroup
        self.buildConfigurations = model.buildConfigurations.map{ BuildConfiguration($0, pifLoader) }
        self.defaultConfigurationName = model.defaultConfigurationName
        self.developmentRegion = model.developmentRegion
        self.classPrefix = model.classPrefix
        self.appPreferencesBuildSettings = BuildConfiguration.convertMacroBindingSourceToPlistDictionary(model.appPreferencesBuildSettings)

        // Compute the derived name.
        self.name = xcodeprojPath.basenameWithoutSuffix

        try validateTargets()
    }

    @_spi(Testing) public init(fromDictionary pifDict: ProjectModelItemPIF, signature: String, withPIFLoader pifLoader: PIFLoader) throws {
        self.signature = signature

        // The GUID is required.
        guid = try Self.parseValueForKeyAsString(PIFKey_guid, pifDict: pifDict)

        // The path to the .xcodeproj file is required.
        let xcodeprojPath = try Path(Self.parseValueForKeyAsString(PIFKey_path, pifDict: pifDict))
        self.xcodeprojPath = xcodeprojPath

        // Use the name if got one from PIF, otherwise compute it from the project path.
        let name = try Self.parseOptionalValueForKeyAsString(PIFKey_Project_name, pifDict: pifDict)
        self.name = name ?? xcodeprojPath.basenameWithoutSuffix

        self.isPackage = try Self.parseValueForKeyAsBool(PIFKey_Project_isPackage, pifDict: pifDict)

        // The source root is optional, while we wait for the PIF format to update.
        if let path = try Self.parseOptionalValueForKeyAsString(PIFKey_Project_projectDirectory, pifDict: pifDict) {
            sourceRoot = Path(path)
        } else {
            sourceRoot = xcodeprojPath.dirname
        }

        // The top-level file group is required.  We load this early because our or our targets' build configurations can refer to files in here.
        groupTree = try FileGroup.parsePIFDictAsReference(Self.parseValueForKeyAsPIFDictionary(PIFKey_Project_groupTree, pifDict: pifDict), pifLoader: pifLoader, isRoot: true) as! FileGroup

        // The list of targets is required.
        targets = try Self.parseValueForKeyAsArrayOfIndirectObjects(PIFKey_Project_targets, pifDict: pifDict, pifLoader: pifLoader)

        // The list of build configurations is required.
        buildConfigurations = try Self.parseValueForKeyAsArrayOfProjectModelItems(PIFKey_buildConfigurations, pifDict: pifDict, pifLoader: pifLoader, construct: { try BuildConfiguration(fromDictionary: $0, withPIFLoader: pifLoader) })

        // The default configuration name is required.
        defaultConfigurationName = try Self.parseValueForKeyAsString(PIFKey_Project_defaultConfigurationName, pifDict: pifDict)

        // The development region name is required.
        developmentRegion = try Self.parseOptionalValueForKeyAsString(PIFKey_Project_developmentRegion, pifDict: pifDict)

        classPrefix = try Self.parseOptionalValueForKeyAsString(PIFKey_Project_classPrefix, pifDict: pifDict) ?? ""

        // Get the application preferences build settings.
        appPreferencesBuildSettings = try Self.parseOptionalValueForKeyAsPIFDictionary(PIFKey_Project_appPreferencesBuildSettings, pifDict: pifDict) ?? [:]

        try validateTargets()
    }

    public var description: String
    {
        return "\(type(of: self))<\(guid):\(xcodeprojPath.str):\(targets.count) targets>"
    }

    /// Get the named configuration.
    //
    // FIXME: This code is currently duplicated on the target. We should perhaps have an explicit BuildConfigurationList object, like Xcode, to hold these.
    func getConfiguration(_ name: String) -> BuildConfiguration? {
        for config in buildConfigurations {
            if config.name == name {
                return config
            }
        }
        return nil
    }

    /// Get the effective configuration to use for the given name.
    func getEffectiveConfiguration(_ name: String?, packageConfigurationOverride: String?) -> BuildConfiguration? {
        // Return the named config, if present.
        if let name {
            if let config = getConfiguration(name) {
                return config
            }
        }

        // Use the package-specific override, if applicable.
        if let packageConfigurationOverride, isPackage {
            if let config = getConfiguration(packageConfigurationOverride) {
                return config
            }
        }

        // Otherwise, return the configuration matching the default configuration name.
        if let config = getConfiguration(defaultConfigurationName) {
            return config
        }

        // Otherwise, return any configuration.
        return buildConfigurations.first
    }

    /// Returns a hash value based on the identity of the object.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func ==(lhs: Project, rhs: Project) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    /// Validates the target listing to ensure that collection of targets are valid for the given project.
    /// - remark: This is used to ensure that no `PackageProductTarget` exists in a project where `isPackage = false`.
    func validateTargets() throws {
        if !isPackage {
            for target in targets where target is PackageProductTarget {
                throw PIFLoadingError.incompatiblePackageTargetProject(target: target.name)
            }
        }
    }
}
