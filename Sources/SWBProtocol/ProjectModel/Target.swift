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

public struct TargetGUID: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public class Target: PolymorphicSerializable, @unchecked Sendable {
    public static let implementations: [SerializableTypeCode : any PolymorphicSerializable.Type] = [
        0: StandardTarget.self,
        1: AggregateTarget.self,
        2: ExternalTarget.self,
        3: PackageProductTarget.self,
    ]

    public let guid: String
    public let name: String
    public let buildConfigurations: [BuildConfiguration]
    public let customTasks: [CustomTask]
    public let dependencies: [TargetDependency]

    /// An optional reference to a target which can build a dynamically linked variant of the same product.
    ///
    /// We might to move away from this approach in the future as part of rdar://72205262 (Explore moving away from two target approach for dynamic targets to changing linkage directly in Swift Build)
    public let dynamicTargetVariantGuid: String?

    /// Some targets (e.g. third-party macros) may require approval by the user.
    public let approvedByUser: Bool

    public init(guid: String, name: String, buildConfigurations: [BuildConfiguration], customTasks: [CustomTask], dependencies: [TargetDependency], dynamicTargetVariantGuid: String?, approvedByUser: Bool) {
        self.guid = guid
        self.name = name
        self.buildConfigurations = buildConfigurations
        self.customTasks = customTasks
        self.dependencies = dependencies
        self.dynamicTargetVariantGuid = dynamicTargetVariantGuid
        self.approvedByUser = approvedByUser
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(7) {
            serializer.serialize(guid)
            serializer.serialize(name)
            serializer.serialize(buildConfigurations)
            serializer.serialize(customTasks)
            serializer.serialize(dependencies)
            serializer.serialize(dynamicTargetVariantGuid)
            serializer.serialize(approvedByUser)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(7)
        self.guid = try deserializer.deserialize()
        self.name = try deserializer.deserialize()
        self.buildConfigurations = try deserializer.deserialize()
        self.customTasks = try deserializer.deserialize()
        self.dependencies = try deserializer.deserialize()
        self.dynamicTargetVariantGuid = try deserializer.deserialize()
        self.approvedByUser = try deserializer.deserialize()
    }
}

public class BuildPhaseTarget: Target, @unchecked Sendable {
    public let buildPhases: [BuildPhase]

    public init(guid: String, name: String, buildConfigurations: [BuildConfiguration], customTasks: [CustomTask], dependencies: [TargetDependency], buildPhases: [BuildPhase], dynamicTargetVariantGuid: String?, approvedByUser: Bool) {
        self.buildPhases = buildPhases
        super.init(guid: guid, name: name, buildConfigurations: buildConfigurations, customTasks: customTasks, dependencies: dependencies, dynamicTargetVariantGuid: dynamicTargetVariantGuid, approvedByUser: approvedByUser)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(buildPhases)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.buildPhases = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

// MARK: Standard Target

public enum ProvisioningProfileSupport: Int, Serializable, Sendable {
    case unsupported = 0
    case optional = 1
    case required = 2
}

public enum ProvisioningStyle: Int, Serializable, Codable, Sendable {
    /// Provisioning is automatically managed by the IDE
    case automatic = 0
    /// Provisioning is manually managed by the user
    case manual = 1

    public static func fromString(_ string: String) -> ProvisioningStyle? {
        switch string.lowercased() {
        case "automatic":
            return .automatic
        case "manual":
            return .manual
        default:
            return nil
        }
    }
}

public final class StandardTarget: BuildPhaseTarget, @unchecked Sendable {
    public let buildRules: [BuildRule]
    public let productTypeIdentifier: String
    public let productReference: ProductReference
    public let performanceTestsBaselinesPath: String?
    public let predominantSourceCodeLanguage: String?
    public let provisioningSourceData: [ProvisioningSourceData]
    public let classPrefix: String?
    public let isPackageTarget: Bool

    public init(guid: String, name: String, buildConfigurations: [BuildConfiguration], customTasks: [CustomTask], dependencies: [TargetDependency], buildPhases: [BuildPhase], buildRules: [BuildRule], productTypeIdentifier: String, productReference: ProductReference, performanceTestsBaselinesPath: String?, predominantSourceCodeLanguage: String?, provisioningSourceData: [ProvisioningSourceData], classPrefix: String? = nil, isPackageTarget: Bool = false, dynamicTargetVariantGuid: String?, approvedByUser: Bool) {
        self.buildRules = buildRules
        self.productTypeIdentifier = productTypeIdentifier
        self.productReference = productReference
        self.performanceTestsBaselinesPath = performanceTestsBaselinesPath
        self.predominantSourceCodeLanguage = predominantSourceCodeLanguage
        self.provisioningSourceData = provisioningSourceData
        self.classPrefix = classPrefix
        self.isPackageTarget = isPackageTarget
        super.init(guid: guid, name: name, buildConfigurations: buildConfigurations, customTasks: customTasks, dependencies: dependencies, buildPhases: buildPhases, dynamicTargetVariantGuid: dynamicTargetVariantGuid, approvedByUser: approvedByUser)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(9) {
            serializer.serialize(buildRules)
            serializer.serialize(productTypeIdentifier)
            serializer.serialize(productReference)
            serializer.serialize(performanceTestsBaselinesPath)
            serializer.serialize(predominantSourceCodeLanguage)
            serializer.serialize(provisioningSourceData)
            serializer.serialize(classPrefix)
            serializer.serialize(isPackageTarget)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(9)
        self.buildRules = try deserializer.deserialize()
        self.productTypeIdentifier = try deserializer.deserialize()
        self.productReference = try deserializer.deserialize()
        self.performanceTestsBaselinesPath = try deserializer.deserialize()
        self.predominantSourceCodeLanguage = try deserializer.deserialize()
        self.provisioningSourceData = try deserializer.deserialize()
        self.classPrefix = try deserializer.deserialize()
        self.isPackageTarget = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

// MARK: Other Targets

public final class AggregateTarget: BuildPhaseTarget, @unchecked Sendable {
    public init(guid: String, name: String, buildConfigurations: [BuildConfiguration], customTasks: [CustomTask], dependencies: [TargetDependency], buildPhases: [BuildPhase]) {
        super.init(guid: guid, name: name, buildConfigurations: buildConfigurations, customTasks: customTasks, dependencies: dependencies, buildPhases: buildPhases, dynamicTargetVariantGuid: nil, approvedByUser: true)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(1) {
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(1)
        try super.init(from: deserializer)
    }
}

public final class ExternalTarget: Target, @unchecked Sendable {
    public let toolPath: MacroExpressionSource
    public let arguments: MacroExpressionSource
    public let workingDirectory: MacroExpressionSource
    public let passBuildSettingsInEnvironment: Bool

    public init(guid: String, name: String, buildConfigurations: [BuildConfiguration], customTasks: [CustomTask], dependencies: [TargetDependency], toolPath: MacroExpressionSource, arguments: MacroExpressionSource, workingDirectory: MacroExpressionSource, passBuildSettingsInEnvironment: Bool) {
        self.toolPath = toolPath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.passBuildSettingsInEnvironment = passBuildSettingsInEnvironment
        super.init(guid: guid, name: name, buildConfigurations: buildConfigurations, customTasks: customTasks, dependencies: dependencies, dynamicTargetVariantGuid: nil, approvedByUser: true)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(5) {
            serializer.serialize(toolPath)
            serializer.serialize(arguments)
            serializer.serialize(workingDirectory)
            serializer.serialize(passBuildSettingsInEnvironment)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        self.toolPath = try deserializer.deserialize()
        self.arguments = try deserializer.deserialize()
        self.workingDirectory = try deserializer.deserialize()
        self.passBuildSettingsInEnvironment = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}

public final class PackageProductTarget: Target, @unchecked Sendable {
    /// The frameworks build phase which encodes the link dependencies.
    public let frameworksBuildPhase: FrameworksBuildPhase?

    public init(guid: String, name: String, buildConfigurations: [BuildConfiguration], customTasks: [CustomTask], dependencies: [TargetDependency], frameworksBuildPhase: FrameworksBuildPhase, dynamicTargetVariantGuid: String?, approvedByUser: Bool) {
        self.frameworksBuildPhase = frameworksBuildPhase
        super.init(guid: guid, name: name, buildConfigurations: buildConfigurations, customTasks: customTasks, dependencies: dependencies, dynamicTargetVariantGuid: dynamicTargetVariantGuid, approvedByUser: approvedByUser)
    }

    public override func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(2) {
            serializer.serialize(frameworksBuildPhase)
            super.serialize(to: serializer)
        }
    }

    public required init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(2)
        self.frameworksBuildPhase = try deserializer.deserialize()
        try super.init(from: deserializer)
    }
}
