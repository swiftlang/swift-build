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

/// Reference subclasses which can be represented by a build file must adopt the BuildFileRepresentable protocol.
public protocol BuildFileRepresentable: AnyObject
{
}

public typealias HeaderVisibility = SWBProtocol.BuildFile.HeaderVisibility

public typealias MigCodegenFiles = SWBProtocol.BuildFile.MigCodegenFiles

public typealias IntentsCodegenVisibility = SWBProtocol.BuildFile.IntentsCodegenVisibility

public typealias ResourceRule = SWBProtocol.BuildFile.ResourceRule

/// A build file represents an individual item in a build phase.
///
/// The majority of build files are simple associations to a file reference in the project. However, they can include additional data to alter the role of the build file, often depending on the exact phase they are contained within.
//
// FIXME: This should probably be a simple struct, and be more optimized for the common case (to optimize memory use).
public final class BuildFile: ProjectModelItem {
    /// Build files can refer to either regular items in the group tree
    /// (specifically, file references or variant/version groups), *or* they can
    /// refer to product references.
    ///
    /// Product references need to be handled specially, since they may cross
    /// target and project boundaries, so we model this distinction explicitly.
    public enum BuildableItem: Hashable, SerializableCodable, Sendable {
        /// A file like reference type.
        case reference(guid: String)

        /// A product reference, identified by the GUID of the `StandardTarget` whose product it is.
        case targetProduct(guid: String)

        /// A reference by name.
        case namedReference(name: String, fileTypeIdentifier: String)
    }

    public let guid: String

    /// The buildable item the build file refers to.
    public let buildableItem: BuildableItem

    /// The header visibility, if specified.
    public let headerVisibility: HeaderVisibility?

    /// Additional user-specified command line arguments to pass to the build tool, if specified.  May contain build setting references.
    public let additionalArgs: MacroStringListExpression?

    /// Whether the asset should be decompressed (used only by SceneKit).
    public let decompress: Bool

    /// The type of Mig interfaces to generate, if specified.
    public let migCodegenFiles: MigCodegenFiles?

    /// Whether to generate interfaces for intents files
    public let intentsCodegenVisibility: IntentsCodegenVisibility

    /// The rule for processing this build file as a resource.
    public let resourceRule: ResourceRule

    /// Whether to code sign the file, if copied.
    public let codeSignOnCopy: Bool

    /// Whether to remove header from the file (directory), if copies.
    public let removeHeadersOnCopy: Bool

    /// Whether to link weakly, for linking build files.
    public let shouldLinkWeakly: Bool

    /// On Demand Resources asset tags
    public let assetTags: Set<String>

    /// The set of platforms to filter on.
    public let platformFilters: Set<PlatformFilter>

    /// Whether to skip the "no rule to process file..." warning for this file.
    public let shouldWarnIfNoRuleToProcess: Bool

    init(_ model: SWBProtocol.BuildFile, _ pifLoader: PIFLoader)
    {
        guid = model.guid
        codeSignOnCopy = model.codeSignOnCopy
        removeHeadersOnCopy = model.removeHeadersOnCopy
        shouldLinkWeakly = model.shouldLinkWeakly
        headerVisibility = model.headerVisibility
        additionalArgs = model.additionalArgs.map{ pifLoader.userNamespace.parseStringList($0) }
        decompress = model.decompress
        migCodegenFiles = model.migCodegenFiles
        assetTags = model.assetTags
        intentsCodegenVisibility = model.intentsCodegenVisibility
        resourceRule = model.resourceRule
        platformFilters = Set(model.platformFilters.map{ SWBCore.PlatformFilter($0, pifLoader) })
        shouldWarnIfNoRuleToProcess = model.shouldWarnIfNoRuleToProcess

        switch model.buildableItemGUID {
        case .reference(let guid):
            buildableItem = .reference(guid: guid)
        case .targetProduct(let guid):
            buildableItem = .targetProduct(guid: guid)
        case .namedReference(let name, let fileTypeIdentifier):
            buildableItem = .namedReference(name: name, fileTypeIdentifier: fileTypeIdentifier)
        }
    }

    @_spi(Testing) public init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        guid = try Self.parseValueForKeyAsString(PIFKey_guid, pifDict: pifDict)
        codeSignOnCopy = try Self.parseValueForKeyAsBool(PIFKey_BuildFile_codeSignOnCopy, pifDict: pifDict)
        removeHeadersOnCopy = try Self.parseValueForKeyAsBool(PIFKey_BuildFile_removeHeadersOnCopy, pifDict: pifDict)
        shouldLinkWeakly = try Self.parseValueForKeyAsBool(PIFKey_BuildFile_shouldLinkWeakly, pifDict: pifDict)
        assetTags = try Set(Self.parseOptionalValueForKeyAsArrayOfStrings(PIFKey_BuildFile_assetTags, pifDict: pifDict) ?? [])
        shouldWarnIfNoRuleToProcess = try Self.parseValueForKeyAsBool(PIFKey_BuildFile_shouldWarnIfNoRuleToProcess, pifDict: pifDict, defaultValue: true)

        // Parse the header visibility.
        self.headerVisibility = try Self.parseOptionalValueForKeyAsStringEnum(PIFKey_BuildFile_headerVisibility, pifDict: pifDict)

        // Make a copy of any command line arguments to pass to the build tool.  For now this is just a string, and since we don’t have access to any namespace, we just store it in string form here until it can be parsed.
        switch pifDict[PIFKey_BuildFile_additionalCompilerOptions] {
        case .plString(let stringValue)?:
            self.additionalArgs = pifLoader.userNamespace.parseStringList(stringValue)
        case .plArray(let arrayValue)?:
            self.additionalArgs = try pifLoader.userNamespace.parseStringList(arrayValue.map { (plItem) -> String in
                guard case .plString(let string) = plItem else {
                    throw PIFParsingError.incorrectTypeInArray(keyName: PIFKey_BuildFile_additionalCompilerOptions, objectType: Self.self, expectedType: "String")
                }
                return string
            }.joined(separator: " "))
        case .none:
            self.additionalArgs = nil
            break
        default:
            throw PIFParsingError.incorrectType(keyName: PIFKey_BuildFile_additionalCompilerOptions, objectType: Self.self, expectedType: "String or [String]", destinationType: nil)
        }

        self.decompress = try Self.parseValueForKeyAsBool(PIFKey_BuildFile_decompress, pifDict: pifDict)

        // Parse the Mig attributes.
        self.migCodegenFiles = try Self.parseOptionalValueForKeyAsStringEnum(PIFKey_BuildFile_migCodegenFiles, pifDict: pifDict)

        // Parse the Intents attributes
        if let value: IntentsCodegenVisibility = try Self.parseOptionalValueForKeyAsStringEnum(PIFKey_BuildFile_intentsCodegenVisibility, pifDict: pifDict) {
            intentsCodegenVisibility = value
        } else {
            intentsCodegenVisibility = try Self.parseValueForKeyAsBool(PIFKey_BuildFile_intentsCodegenFiles, pifDict: pifDict) ? .public : .noCodegen
        }

        // Parse the resource rule attribute
        if let value: ResourceRule = try Self.parseOptionalValueForKeyAsStringEnum(PIFKey_BuildFile_resourceRule, pifDict: pifDict) {
            resourceRule = value
        } else {
            resourceRule = .process // default to `.process` for backwards compatibility
        }

        // Parse the platformFilters data.
        platformFilters = try Set(Self.parseOptionalValueForKeyAsArrayOfProjectModelItems(PIFKey_platformFilters, pifDict: pifDict, pifLoader: pifLoader, construct: {
            try PlatformFilter(fromDictionary: $0, withPIFLoader: pifLoader)
        }) ?? [])

        if let targetReferenceGUID = try Self.parseOptionalValueForKeyAsString(PIFKey_BuildFile_targetReference, pifDict: pifDict) {
            buildableItem = .targetProduct(guid: targetReferenceGUID)
        } else if let fileReferenceGUID = try Self.parseOptionalValueForKeyAsString(PIFKey_BuildFile_fileReference, pifDict: pifDict) {
            buildableItem = .reference(guid: fileReferenceGUID)
        } else {
            let fileTypeIdentifier = try Self.parseValueForKeyAsString(PIFKey_Reference_fileType, pifDict: pifDict)
            let name = try Self.parseValueForKeyAsString(PIFKey_name, pifDict: pifDict)
            buildableItem = .namedReference(name: name, fileTypeIdentifier: fileTypeIdentifier)
        }
    }

    public init(guid: String, targetProductGuid: String, platformFilters: Set<PlatformFilter> = Set()) {
        self.guid = guid
        self.codeSignOnCopy = true
        self.removeHeadersOnCopy = false
        self.shouldLinkWeakly = false
        self.headerVisibility = .none
        self.additionalArgs = nil
        self.decompress = false
        self.migCodegenFiles = nil
        self.assetTags = Set<String>()
        self.intentsCodegenVisibility = .noCodegen
        self.platformFilters = platformFilters
        self.buildableItem = .targetProduct(guid: targetProductGuid)
        self.shouldWarnIfNoRuleToProcess = true
        self.resourceRule = .process
    }

    public var description: String
    {
        // It would be convenient to emit something to identify the reference here.
        return "\(type(of: self))<\(guid)>"
    }
}

extension HeaderVisibility: PIFStringEnum {
    public static let logicalTypeName = "header visibility"
}

extension MigCodegenFiles: PIFStringEnum {
    public static let logicalTypeName = "MiG code generation mode"
}

extension IntentsCodegenVisibility: PIFStringEnum {
    public static let logicalTypeName = "Intents code generation visibility"
}

extension ResourceRule: PIFStringEnum {
    public static let logicalTypeName = "Rule for resource processing"
}
