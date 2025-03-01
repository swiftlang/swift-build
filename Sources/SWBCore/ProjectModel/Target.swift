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

public import SWBProtocol
public import SWBUtil
public import SWBMacro

public typealias ProvisioningStyle = SWBProtocol.ProvisioningStyle

public enum TargetType: Sendable {
    /// Native targets are ones the build system actually knows how to construct.
    case standard
    /// Aggregate targets generally behave like the most-generic kind of target.
    case aggregate
    /// External targets behave like aggregate ones, but have some additional custom behaviors.
    case external
    /// Package product targets have no code themselves, but behave like aggregate targets which do, however, define a product (a virtual aggregate). See the class for more information.
    case packageProduct
}

public final class CustomTask: ProjectModelItem, Sendable {
    public let commandLine: [MacroStringExpression]
    public let environment: [(MacroStringExpression, MacroStringExpression)]
    public let workingDirectory: MacroStringExpression?
    public let executionDescription: MacroStringExpression
    public let inputFilePaths: [MacroStringExpression]
    public let outputFilePaths: [MacroStringExpression]
    public let enableSandboxing: Bool
    public let preparesForIndexing: Bool

    init(_ model: SWBProtocol.CustomTask, _ pifLoader: PIFLoader) {
        self.commandLine = model.commandLine.map { pifLoader.userNamespace.parseString($0) }
        self.environment = model.environment.map { (pifLoader.userNamespace.parseString($0.0), pifLoader.userNamespace.parseString($0.1)) }
        self.workingDirectory = pifLoader.userNamespace.parseString(model.workingDirectory)
        self.executionDescription = pifLoader.userNamespace.parseString(model.executionDescription)
        self.inputFilePaths = model.inputFilePaths.map { pifLoader.userNamespace.parseString($0) }
        self.outputFilePaths = model.outputFilePaths.map { pifLoader.userNamespace.parseString($0) }
        self.enableSandboxing = model.enableSandboxing
        self.preparesForIndexing = model.preparesForIndexing
    }

    init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        self.commandLine = try Self.parseValueForKeyAsArrayOfStrings(PIFKey_CustomTask_commandLine, pifDict: pifDict).map { pifLoader.userNamespace.parseString($0) }
        var environment: [(MacroStringExpression, MacroStringExpression)] = []

        let environmentItems = try Self.parseValueForKeyAsArrayOfPropertyListItems(PIFKey_CustomTask_environment, pifDict: pifDict)

        for environmentItemPL in environmentItems {
            guard let keyAndValuePLs = environmentItemPL.arrayValue else {
                throw PIFParsingError.incorrectTypeInArray(keyName: PIFKey_CustomTask_environment, objectType: Self.self, expectedType: "Array")
            }
            guard keyAndValuePLs.count == 2 else  {
                throw StubError.error("Expected a key/value pair when deserializing environment")
            }
            guard let key = keyAndValuePLs[0].stringValue, let value = keyAndValuePLs[1].stringValue else {
                throw PIFParsingError.incorrectTypeInArray(keyName: PIFKey_CustomTask_environment, objectType: Self.self, expectedType: "String")
            }
            environment.append((pifLoader.userNamespace.parseString(key), pifLoader.userNamespace.parseString(value)))
        }

        self.environment = environment
        self.workingDirectory = try Self.parseOptionalValueForKeyAsString(PIFKey_CustomTask_workingDirectory, pifDict: pifDict).map { pifLoader.userNamespace.parseString($0) }
        self.executionDescription = try pifLoader.userNamespace.parseString(Self.parseValueForKeyAsString(PIFKey_CustomTask_executionDescription, pifDict: pifDict))
        self.inputFilePaths = try Self.parseValueForKeyAsArrayOfStrings(PIFKey_CustomTask_inputFilePaths, pifDict: pifDict).map { pifLoader.userNamespace.parseString($0) }
        self.outputFilePaths = try Self.parseValueForKeyAsArrayOfStrings(PIFKey_CustomTask_outputFilePaths, pifDict: pifDict).map { pifLoader.userNamespace.parseString($0) }
        self.enableSandboxing = try Self.parseValueForKeyAsBool(PIFKey_CustomTask_enableSandboxing, pifDict: pifDict)
        self.preparesForIndexing = try Self.parseValueForKeyAsBool(PIFKey_CustomTask_preparesForIndexing, pifDict: pifDict)
    }
}


// MARK: Target Dependency Info

public final class TargetDependency: ProjectModelItem, Encodable, Sendable
{
    /// The GUID that maps back to the target GUID.
    public let guid: String

    /// The name of the target dependency, for display purposes in diagnostics.
    public let name: String?

    private enum CodingKeys: String, CodingKey {
        case guid
        case name
        case platformFilters
    }

    /// The set of the platform filters for the target dependency.
    public let platformFilters: Set<PlatformFilter>

    public init(guid: String, name: String?, platformFilters: Set<PlatformFilter> = []) {
        self.guid = guid
        self.name = name
        self.platformFilters = platformFilters
    }

    init(_ model: SWBProtocol.TargetDependency, _ pifLoader: PIFLoader) {
        self.guid = model.guid
        self.name = model.name
        self.platformFilters = Set(model.platformFilters.map{ SWBCore.PlatformFilter($0, pifLoader) })
    }

    init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        // FIXME: Falling back to an empty string GUID does not seem correct, but this can happen for dependencies on targets from missing project references. Should we instead allow `guid` to be nil to represent this case?
        self.guid = try Self.parseOptionalValueForKeyAsString(PIFKey_guid, pifDict: pifDict) ?? ""
        self.name = try Self.parseOptionalValueForKeyAsString(PIFKey_name, pifDict: pifDict)
        self.platformFilters = Set(try Self.parseOptionalValueForKeyAsArrayOfProjectModelItems(PIFKey_platformFilters, pifDict: pifDict, pifLoader: pifLoader, construct: {
            try PlatformFilter(fromDictionary: $0, withPIFLoader: pifLoader)
        }) ?? [])
    }
}


// MARK: Target abstract class

/// The Target abstract class defines properties common to all types of targets.
public class Target: ProjectModelItem, PIFObject, Hashable, Encodable, @unchecked Sendable
{
    static func referencedObjects(for data: EncodedPIFValue) -> [PIFObjectReference] {
        return []
    }

    /// Parses a ProjectModelItemPIF dictionary as an object of the appropriate subclass of Target.
    static func construct(from data: EncodedPIFValue, signature: PIFObject.Signature, loader: PIFLoader ) throws -> Self {
        switch data {
        case .json(let data):
            return try construct(from: data, signature: signature, loader: loader)
        case .binary(let data):
            let deserializer = MsgPackDeserializer(data)
            let model: SWBProtocol.Target = try deserializer.deserialize()
            return try create(model, loader, signature: signature)
        }
    }

    public static func create(_ model: SWBProtocol.Target, _ pifLoader: PIFLoader, signature: String) throws -> Self {
        // Workaround inability to express protocol completely.
        func autocast<T>(_ some: Target) -> T {
            return some as! T
        }

        switch model {
        case let model as SWBProtocol.AggregateTarget: return autocast(AggregateTarget(model, pifLoader, signature: signature))
        case let model as SWBProtocol.ExternalTarget: return autocast(ExternalTarget(model, pifLoader, signature: signature))
        case let model as SWBProtocol.PackageProductTarget: return autocast(PackageProductTarget(model, pifLoader, signature: signature))
        case let model as SWBProtocol.StandardTarget: return try autocast(StandardTarget(model, pifLoader, signature: signature))
        default:
            fatalError("unexpected model: \(model)")
        }
    }

    /// The PIFObject type name
    static let pifType = PIFObjectType.target

    /// A unique signature for the instance.
    public let signature: String

    /// A stable identifier for the target.
    ///
    /// This is guaranteed to be unique within a single workspace.
    public let guid: String

    public let name: String
    public var type: TargetType { preconditionFailure( "\(Swift.type(of: self)) should never be asked directly for its type" ) }
    public let buildConfigurations: [BuildConfiguration]

    public let hasImpartedBuildProperties: Bool

    /// An optional reference to a target which can build a dynamically linked variant of the same product.
    public let dynamicTargetVariantGuid: String?

    /// Some targets (e.g. third-party macros) may require approval by the user.
    public let approvedByUser: Bool

    /// Custom tasks associated with the target, which may be defined by the user or a higher-level API client.
    public let customTasks: [CustomTask]

    /// The list of GUIDs and `PlatformFilters` for all dependencies.
    ///
    /// This list may include dependencies which are not part of the project this target is a part of, and can only be resolved via the workspace.
    public let dependencies: [TargetDependency]

    private enum CodingKeys: String, CodingKey {
        case signature
        case guid
        case name
        case buildConfigurations
        case dependencies
        case dynamicTargetVariantGuid
    }

    init(_ model: SWBProtocol.Target, _ pifLoader: PIFLoader, signature: String, errors: [String] = [], warnings: [String] = []) {
        self.signature = signature
        self.guid = model.guid
        self.name = model.name
        self.buildConfigurations = model.buildConfigurations.map{ BuildConfiguration($0, pifLoader) }
        self.customTasks = model.customTasks.map { CustomTask($0, pifLoader) }
        self.dependencies = model.dependencies.map{ TargetDependency($0, pifLoader) }
        self.dynamicTargetVariantGuid = model.dynamicTargetVariantGuid
        self.approvedByUser = model.approvedByUser
        self.hasImpartedBuildProperties = buildConfigurations.filter { !$0.impartedBuildProperties.isEmpty }.isEmpty
        self.errors = errors
        self.warnings = warnings
    }

    /// Errors about the configuration of the target.
    public let errors: [String]
    /// Warnings about the configuration of the target.
    public let warnings: [String]

    init(fromDictionary pifDict: ProjectModelItemPIF, signature: String, withPIFLoader pifLoader: PIFLoader, errors: [String] = [], warnings: [String] = []) throws {
        self.signature = signature

        // The GUID is required.
        guid = try Self.parseValueForKeyAsString(PIFKey_guid, pifDict: pifDict)

        // The name is required.
        name = try Self.parseValueForKeyAsString(PIFKey_name, pifDict: pifDict)

        // The list of build configurations is required.
        buildConfigurations = try Self.parseValueForKeyAsArrayOfProjectModelItems(PIFKey_buildConfigurations, pifDict: pifDict, pifLoader: pifLoader, construct: { try BuildConfiguration(fromDictionary: $0, withPIFLoader: pifLoader) })

        customTasks = try Self.parseOptionalValueForKeyAsArrayOfProjectModelItems(PIFKey_Target_customTasks, pifDict: pifDict, pifLoader: pifLoader, construct: { try CustomTask(fromDictionary: $0, withPIFLoader: pifLoader) }) ?? []

        // The list of dependencies is required.
        //
        // The target dependencies are resolved lazily (see `TargetDependencyResolver`) since they may cross target (and even project) boundaries.
        dependencies = try Self.parseValueForKeyAsArrayOfProjectModelItems(PIFKey_Target_dependencies, pifDict: pifDict, pifLoader: pifLoader, construct: {
            return try TargetDependency(fromDictionary: $0, withPIFLoader: pifLoader)
        })

        dynamicTargetVariantGuid = try Self.parseOptionalValueForKeyAsString(PIFKey_Target_dynamicTargetVariantGuid, pifDict: pifDict)
        approvedByUser = try Self.parseValueForKeyAsBool(PIFKey_Target_approvedByUser, pifDict: pifDict, defaultValue: true)
        hasImpartedBuildProperties = buildConfigurations.filter { !$0.impartedBuildProperties.isEmpty }.isEmpty
        self.errors = errors
        self.warnings = warnings
    }

    /// Parses a ProjectModelItemPIF dictionary as an object of the appropriate subclass of Target.
    static func construct(from data: ProjectModelItemPIF, signature: PIFObject.Signature, loader: PIFLoader ) throws -> Self
    {
        // Workaround inability to express protocol completely.
        func autocast<T>(_ some: Target) -> T {
            return some as! T
        }

        // Delegate to protocol-based representation, if in use.
        if let data = try parseOptionalValueForKeyAsByteString("data", pifDict: data) {
            let deserializer = MsgPackDeserializer(data)
            let model: SWBProtocol.Target = try deserializer.deserialize()
            return try autocast(Target.create(model, loader, signature: signature))
        }

        // Get the type of the reference.  This is required, so if there isn't one then it will die.
        switch try parseValueForKeyAsStringEnum(PIFKey_type, pifDict: data) as PIFTargetTypeValue {
        case .standard:
            return try autocast(StandardTarget(fromDictionary: data, signature: signature, withPIFLoader: loader))
        case .aggregate:
            return try autocast(AggregateTarget(fromDictionary: data, signature: signature, withPIFLoader: loader))
        case .external:
            return try autocast(ExternalTarget(fromDictionary: data, signature: signature, withPIFLoader: loader))
        case .packageProduct:
            return try autocast(PackageProductTarget(fromDictionary: data, signature: signature, withPIFLoader: loader))
        }
    }

    public var description: String
    {
        return "\(Swift.type(of: self))<\(guid):\(name)>"
    }

    /// Get the named configuration.
    //
    // FIXME: This code is currently duplicated on the project. We should perhaps have an explicit BuildConfigurationList object, like Xcode, to hold these.
    func getConfiguration(_ name: String) -> BuildConfiguration? {
        for config in buildConfigurations {
            if config.name == name {
                return config
            }
        }
        return nil
    }

    /// Get the effective configuration to use for the given name.
    public func getEffectiveConfiguration(_ name: String?, defaultConfigurationName: String) -> BuildConfiguration? {
        // Return the named config, if present.
        if let name {
            if let config = getConfiguration(name) {
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

    public static func ==(lhs: Target, rhs: Target) -> Bool {
        return lhs === rhs
    }
}

// MARK: BuildPhaseTarget class


/// A BuildPhaseTarget is a kind of target which can contain build phases.
public class BuildPhaseTarget: Target, @unchecked Sendable
{
    /// List of build phases in the target.
    public let buildPhases: [BuildPhase]

    /// The canonical sources build phase in the target, if there is one.  There should only be one in a target; if there is more than one, then a warning will be emitted and the project might not build as expected.
    public let sourcesBuildPhase: SourcesBuildPhase?
    /// The canonical frameworks build phase in the target, if there is one.  There should only be one in a target; if there is more than one, then a warning will be emitted and the project might not build as expected.
    public let frameworksBuildPhase: FrameworksBuildPhase?
    /// The canonical headers build phase in the target, if there is one.  There should only be one in a target; if there is more than one, then a warning will be emitted and the project might not build as expected.
    public let headersBuildPhase: HeadersBuildPhase?
    /// The canonical resources build phase in the target, if there is one.  There should only be one in a target; if there is more than one, then a warning will be emitted and the project might not build as expected.
    public let resourcesBuildPhase: ResourcesBuildPhase?

    init(_ model: SWBProtocol.BuildPhaseTarget, _ pifLoader: PIFLoader, signature: String) {
        buildPhases = model.buildPhases.map{ BuildPhase.create($0, pifLoader) }
        // Populate the convenience build phase properties.
        var warnings: [String] = []
        var sourcesBuildPhase: SourcesBuildPhase? = nil
        var frameworksBuildPhase: FrameworksBuildPhase? = nil
        var headersBuildPhase: HeadersBuildPhase? = nil
        var resourcesBuildPhase: ResourcesBuildPhase? = nil
        for buildPhase in self.buildPhases {
            switch buildPhase {
                case let sourcesPhase as SourcesBuildPhase:
                    if sourcesBuildPhase != nil {
                        warnings.append("target has multiple \(buildPhase.name) build phases, which may cause it to build incorrectly - all but one should be deleted")
                    }
                    sourcesBuildPhase = sourcesPhase
                case let frameworksPhase as FrameworksBuildPhase:
                    if frameworksBuildPhase != nil {
                        warnings.append("target has multiple \(buildPhase.name) build phases, which may cause it to build incorrectly - all but one should be deleted")
                    }
                    frameworksBuildPhase = frameworksPhase
                case let headersPhase as HeadersBuildPhase:
                    if headersBuildPhase != nil {
                        warnings.append("target has multiple \(buildPhase.name) build phases, which may cause it to build incorrectly - all but one should be deleted")
                    }
                    headersBuildPhase = headersPhase
                case let resourcesPhase as ResourcesBuildPhase:
                    if resourcesBuildPhase != nil {
                        warnings.append("target has multiple \(buildPhase.name) build phases, which may cause it to build incorrectly - all but one should be deleted")
                    }
                    resourcesBuildPhase = resourcesPhase
                default:
                    break
            }
        }
        self.sourcesBuildPhase = sourcesBuildPhase
        self.frameworksBuildPhase = frameworksBuildPhase
        self.headersBuildPhase = headersBuildPhase
        self.resourcesBuildPhase = resourcesBuildPhase
        super.init(model, pifLoader, signature: signature, errors: [], warnings: warnings)
    }

    @_spi(Testing) public override init(fromDictionary pifDict: ProjectModelItemPIF, signature: String, withPIFLoader pifLoader: PIFLoader, errors: [String] = [], warnings: [String] = []) throws
    {
        // The list of build phases is required.
        buildPhases = try Self.parseValueForKeyAsArrayOfPropertyListItems(PIFKey_Target_buildPhases, pifDict: pifDict).map { plItem in
            guard case .plDict(let dictValue) = plItem else {
                throw PIFParsingError.incorrectTypeInArray(keyName: PIFKey_Target_buildPhases, objectType: Self.self, expectedType: "Dictionary")
            }

            // Delegate to protocol-based representation, if in use.
            if let data = try Self.parseOptionalValueForKeyAsByteString("data", pifDict: dictValue) {
                let deserializer = MsgPackDeserializer(data)
                let buildPhase: SWBProtocol.BuildPhase = try deserializer.deserialize()
                return BuildPhase.create(buildPhase, pifLoader)
            } else {
                return try BuildPhase.parsePIFDictAsBuildPhase(dictValue, pifLoader: pifLoader)
            }
        }

        // Populate the convenience build phase properties.
        var newWarnings: [String] = []
        var sourcesBuildPhase: SourcesBuildPhase? = nil
        var frameworksBuildPhase: FrameworksBuildPhase? = nil
        var headersBuildPhase: HeadersBuildPhase? = nil
        var resourcesBuildPhase: ResourcesBuildPhase? = nil
        for buildPhase in self.buildPhases
        {
            switch buildPhase
            {
                case let sourcesPhase as SourcesBuildPhase:
                    if sourcesBuildPhase != nil {
                        newWarnings.append("target has multiple \(buildPhase.name) build phases, which may cause it to build incorrectly - all but one should be deleted")
                    }
                    sourcesBuildPhase = sourcesPhase
                case let frameworksPhase as FrameworksBuildPhase:
                    if frameworksBuildPhase != nil {
                        newWarnings.append("target has multiple \(buildPhase.name) build phases, which may cause it to build incorrectly - all but one should be deleted")
                    }
                    frameworksBuildPhase = frameworksPhase
                case let headersPhase as HeadersBuildPhase:
                    if headersBuildPhase != nil {
                        newWarnings.append("target has multiple \(buildPhase.name) build phases, which may cause it to build incorrectly - all but one should be deleted")
                    }
                    headersBuildPhase = headersPhase
                case let resourcesPhase as ResourcesBuildPhase:
                    if resourcesBuildPhase != nil {
                        newWarnings.append("target has multiple \(buildPhase.name) build phases, which may cause it to build incorrectly - all but one should be deleted")
                    }
                    resourcesBuildPhase = resourcesPhase
                default:
                    break
            }
        }
        self.sourcesBuildPhase = sourcesBuildPhase
        self.frameworksBuildPhase = frameworksBuildPhase
        self.headersBuildPhase = headersBuildPhase
        self.resourcesBuildPhase = resourcesBuildPhase

        try super.init(fromDictionary: pifDict, signature: signature, withPIFLoader: pifLoader, errors: errors, warnings: warnings + newWarnings)
    }
}


// MARK: StandardTarget class


/// Source data needed to compute provisioning task inputs for a target+configuration pair.
public typealias ProvisioningSourceData = SWBProtocol.ProvisioningSourceData

/// A StandardTarget is the most common type of target: A target which has build phases describing its input files, and which generates a product.
public final class StandardTarget: BuildPhaseTarget, @unchecked Sendable
{
    public enum SourceCodeLanguage: CustomStringConvertible, Sendable {
        case undefined
        case swift
        case c
        case objectiveC
        case cPlusPlus
        case objectiveCPlusPlus
        case other(String)

        /// Return an appropriate source code language value for the given string.  If the string optional is nil, or is an unrecognized value, then `undefined` will be returned.
        static func from(string: String?) -> SourceCodeLanguage {
            guard let string else { return .undefined }
            switch string {
            case "Xcode.SourceCodeLanguage.Swift":
                return .swift
            case "Xcode.SourceCodeLanguage.C":
                return .c
            case "Xcode.SourceCodeLanguage.Objective-C":
                return .objectiveC
            case "Xcode.SourceCodeLanguage.C-Plus-Plus":
                return .cPlusPlus
            case "Xcode.SourceCodeLanguage.Objective-C-Plus-Plus":
                return .objectiveCPlusPlus
            default:
                return .other(string)
            }
        }

        public var description: String {
            switch self {
            case .undefined: return ""
            case .swift: return "Xcode.SourceCodeLanguage.Swift"
            case .c: return "Xcode.SourceCodeLanguage.C"
            case .objectiveC: return "Xcode.SourceCodeLanguage.Objective-C"
            case .cPlusPlus: return "Xcode.SourceCodeLanguage.C-Plus-Plus"
            case .objectiveCPlusPlus: return "Xcode.SourceCodeLanguage.Objective-C-Plus-Plus"
            case .other(let string): return string
            }
        }
    }

    public override var type: TargetType { return TargetType.standard }
    public let buildRules: [BuildRule]
    public let productTypeIdentifier: String
    public let productReference: ProductReference

    /// Indicates if this target is derived from a Swift package.
    public let isPackageTarget: Bool

    /// The path to the baselines for performance tests.  This will be nil for targets for which it isn't useful.
    public let performanceTestsBaselinesPath: Path?

    /// The predominant source code language in this target.  This language is computed by Xcode and passed to us in the PIF.
    public let predominantSourceCodeLanguage: SourceCodeLanguage

    /// The class prefix used in this target
    public let classPrefix: String

    private let _provisioningSourceData: UnsafeDelayedInitializationSendableWrapper<[ProvisioningSourceData]> = .init()
    var provisioningSourceData: [ProvisioningSourceData] {
        _provisioningSourceData.value
    }

    init(_ model: SWBProtocol.StandardTarget, _ pifLoader: PIFLoader, signature: String) throws {
        buildRules = model.buildRules.map{ BuildRule($0, pifLoader) }
        productTypeIdentifier = model.productTypeIdentifier
        productReference = try ProductReference(model.productReference, pifLoader)
        isPackageTarget = model.isPackageTarget
        performanceTestsBaselinesPath = model.performanceTestsBaselinesPath != nil ? Path(model.performanceTestsBaselinesPath!) : nil
        predominantSourceCodeLanguage = SourceCodeLanguage.from(string: model.predominantSourceCodeLanguage)
        var provisioningSourceData = model.provisioningSourceData
        classPrefix = model.classPrefix ?? ""
        super.init(model, pifLoader, signature: signature)

        // Set our product reference's backpointer to ourself.
        productReference.target = self

        try StandardTarget.fixupProvisioningSourceData(&provisioningSourceData, name: name, buildConfigurations: buildConfigurations)
        _provisioningSourceData.initialize(to: provisioningSourceData)
    }

    @_spi(Testing) public override init(fromDictionary pifDict: ProjectModelItemPIF, signature: String, withPIFLoader pifLoader: PIFLoader, errors: [String] = [], warnings: [String] = []) throws
    {
        // The product type identifier is required.
        productTypeIdentifier = try Self.parseValueForKeyAsString(PIFKey_Target_productTypeIdentifier, pifDict: pifDict)

        // The product reference is required.
        //
        // NOTE: It is important to understand what is happening here. This will be the *actual* product reference model item, not the one present in the project group tree. Therefore, there exist some references which are completely outside the group tree.
        productReference = try Self.parseValueForKeyAsProjectModelItem(PIFKey_Target_productReference, pifDict: pifDict, pifLoader: pifLoader, construct: { try ProductReference(fromDictionary: $0, withPIFLoader: pifLoader) })

        // The list of build rules is required.
        buildRules = try Self.parseValueForKeyAsArrayOfProjectModelItems(PIFKey_Target_buildRules, pifDict: pifDict, pifLoader: pifLoader, construct: { try BuildRule(fromDictionary: $0, withPIFLoader: pifLoader) })

        isPackageTarget = try Self.parseValueForKeyAsBool(PIFKey_Target_isPackageTarget, pifDict: pifDict)

        performanceTestsBaselinesPath = try Self.parseOptionalValueForKeyAsString(PIFKey_Target_performanceTestsBaselinesPath, pifDict: pifDict).map { Path($0) }

        predominantSourceCodeLanguage = try SourceCodeLanguage.from(string: Self.parseOptionalValueForKeyAsString(PIFKey_Target_predominantSourceCodeLanguage, pifDict: pifDict))

        classPrefix = try Self.parseOptionalValueForKeyAsString(PIFKey_Project_classPrefix, pifDict: pifDict) ?? ""

        // The list of provisioning source data dictionaries is optional.  For any configurations for which we were not given a provisioning source data object we will create a default one.
        var provisioningSourceData = [ProvisioningSourceData]()

        if let sourceDataDicts = try Self.parseOptionalValueForKeyAsArrayOfPropertyListItems(PIFKey_Target_provisioningSourceData, pifDict: pifDict) {
            provisioningSourceData = try sourceDataDicts.map { try PropertyList.decode(ProvisioningSourceData.self, from: $0) }
        }

        try super.init(fromDictionary: pifDict, signature: signature, withPIFLoader: pifLoader, errors: errors, warnings: warnings)

        // Set our product reference's backpointer to ourself.
        productReference.target = self

        try StandardTarget.fixupProvisioningSourceData(&provisioningSourceData, name: name, buildConfigurations: buildConfigurations)
        _provisioningSourceData.initialize(to: provisioningSourceData)
    }

    private static func fixupProvisioningSourceData(_ provisioningSourceData: inout [ProvisioningSourceData], name: String, buildConfigurations: [BuildConfiguration]) throws {
        // Make sure all of our provisioning source data objects match existing configurations, and that there are no duplicate source data structs for a configuration.
        var configurationNames = Set<String>(buildConfigurations.map({ $0.name }))
        var foundConfigurationNames = Set<String>()
        for sourceData in provisioningSourceData {
            guard !foundConfigurationNames.contains(sourceData.configurationName) else {
                throw PIFParsingError.custom("Target '\(name)' has multiple provisioning source data for configuration '\(sourceData.configurationName)'")
            }
            guard configurationNames.contains(sourceData.configurationName) else {
                throw PIFParsingError.custom("Target '\(name)' has provisioning source data for configuration '\(sourceData.configurationName)' but no configuration of that name")
            }
            configurationNames.remove(sourceData.configurationName)
            foundConfigurationNames.insert(sourceData.configurationName)
        }
        // If any configurations didn't have provisioning source data objects, then create default ones for those configurations.
        for configurationName in configurationNames
        {
            let sourceData = ProvisioningSourceData(configurationName: configurationName, provisioningStyle: .automatic, bundleIdentifierFromInfoPlist: "")
            provisioningSourceData.append(sourceData)
        }
    }

    /// Get the provisioning source data for the given configuration name.
    /// - scope: An optional macro evaluation scope to use which can override certain provisioning data with build settings.
    /// - returns: The relevant provisioning source data, or `nil` if there is no provisioning data for the given configuration name.
    public func provisioningSourceData(for configurationName: String, scope: MacroEvaluationScope? = nil) -> ProvisioningSourceData? {
        for sourceData in provisioningSourceData {
            if sourceData.configurationName == configurationName {
                // Override the provisioning style using $(CODE_SIGN_STYLE), if defined.
                // FIXME: If $(CODE_SIGN_STYLE) evaluates to an unexpected value, we should emit an error somewhere.
                if let codeSignStyleValue = scope?.evaluate(BuiltinMacros.CODE_SIGN_STYLE), !codeSignStyleValue.isEmpty, let codeSignStyle = ProvisioningStyle.fromString(codeSignStyleValue) {
                    return ProvisioningSourceData(configurationName: sourceData.configurationName, provisioningStyle: codeSignStyle, bundleIdentifierFromInfoPlist: sourceData.bundleIdentifierFromInfoPlist)
                }
                return sourceData
            }
        }
        return nil
    }
}


// MARK: AggregateTarget class


/// An AggregateTarget is a special kind of target primarily intended to group together other targets it depends on, and which does not have a defined product.  However, it may also have build phases, which will be run after all of its dependencies have finished building.
public final class AggregateTarget: BuildPhaseTarget, @unchecked Sendable
{
    public override var type: TargetType { return TargetType.aggregate }
}



// MARK: PackageProductTarget class


/// A PackageProductTarget is a custom target used by the Swift package manager to encapsulate the semantics of products.
///
/// This target is currently only expected to have target dependencies and an optional frameworks build phase, which should reference other (static library) targets package product targets.
///
/// The behavior of this target is "as if" the dependencies of the package pass through to downstream things which link the target.
public final class PackageProductTarget: Target, @unchecked Sendable
{
    public override var type: TargetType { return TargetType.packageProduct }

    /// The frameworks build phase which encodes the link dependencies.
    public let frameworksBuildPhase: FrameworksBuildPhase?

    /// The synthesized product reference.
    public let productReference: ProductReference

    init(_ model: SWBProtocol.PackageProductTarget, _ pifLoader: PIFLoader, signature: String) {
        self.frameworksBuildPhase = model.frameworksBuildPhase.map{ BuildPhase.create($0, pifLoader) as! FrameworksBuildPhase }
        self.productReference = ProductReference(guid: "\(model.guid):ProductReference", name: model.name)
        super.init(model, pifLoader, signature: signature)
        self.productReference.target = self
    }

    @_spi(Testing) public override init(fromDictionary pifDict: ProjectModelItemPIF, signature: String, withPIFLoader pifLoader: PIFLoader, errors: [String] = [], warnings: [String] = []) throws {

        self.frameworksBuildPhase = try Self.parseOptionalValueForKeyAsPIFDictionary(PIFKey_Target_frameworksBuildPhase, pifDict: pifDict).map { try BuildPhase.parsePIFDictAsBuildPhase($0, pifLoader: pifLoader) as? FrameworksBuildPhase } ?? nil

        self.productReference = try ProductReference(guid: "\(Self.parseValueForKeyAsString(PIFKey_guid, pifDict: pifDict)):ProductReference", name: Self.parseValueForKeyAsString(PIFKey_name, pifDict: pifDict))
        try super.init(fromDictionary: pifDict, signature: signature, withPIFLoader: pifLoader, errors: errors, warnings: warnings)
    }
}


// MARK: ExternalTarget class


/// An ExternalTarget represents the use of an external build system (most commonly, but not limited to, make).  It is very different from other kinds of targets in that it has no build phases, and does have a defined product.
public final class ExternalTarget: Target, @unchecked Sendable
{
    public override var type: TargetType { return TargetType.external }
    public let toolPath: MacroStringExpression
    public let arguments: MacroStringListExpression
    public let workingDirectory: MacroStringExpression
    public let passBuildSettingsInEnvironment: Bool

    init(_ model: SWBProtocol.ExternalTarget, _ pifLoader: PIFLoader, signature: String) {
        toolPath = pifLoader.userNamespace.parseString(model.toolPath)
        arguments = pifLoader.userNamespace.parseStringList(model.arguments)
        workingDirectory = pifLoader.userNamespace.parseString(model.workingDirectory)
        passBuildSettingsInEnvironment = model.passBuildSettingsInEnvironment
        super.init(model, pifLoader, signature: signature)
    }

    @_spi(Testing) public override init(fromDictionary pifDict: ProjectModelItemPIF, signature: String, withPIFLoader pifLoader: PIFLoader, errors: [String] = [], warnings: [String] = []) throws
    {
        // The tool path is required.
        toolPath = try pifLoader.userNamespace.parseString(Self.parseValueForKeyAsString(PIFKey_ExternalTarget_toolPath, pifDict: pifDict))

        // The arguments string is required.
        arguments = try pifLoader.userNamespace.parseStringList(Self.parseValueForKeyAsString(PIFKey_ExternalTarget_arguments, pifDict: pifDict))

        // The working directory is required.
        workingDirectory = try pifLoader.userNamespace.parseString(Self.parseValueForKeyAsString(PIFKey_ExternalTarget_workingDirectory, pifDict: pifDict))

        // The flag to indicate whether to pass build settings to the tool in the environment is required.
        passBuildSettingsInEnvironment = try Self.parseValueForKeyAsBool(PIFKey_ExternalTarget_passBuildSettingsInEnvironment, pifDict: pifDict)

        try super.init(fromDictionary: pifDict, signature: signature, withPIFLoader: pifLoader, errors: errors, warnings: warnings)
    }
}
