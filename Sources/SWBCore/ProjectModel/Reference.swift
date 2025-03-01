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
import SWBUtil
public import SWBMacro

public typealias SourceTree = SWBProtocol.SourceTree

// MARK: Reference abstract class


public class Reference: ProjectModelItem, Hashable, Equatable, @unchecked Sendable
{
    /// The global ID within the PIF for this reference.
    public let guid: String

    public static func create(_ model: SWBProtocol.Reference, _ pifLoader: PIFLoader, isRoot: Bool) throws -> Reference {
        switch model {
        case let model as SWBProtocol.VersionGroup: return try VersionGroup(model, pifLoader, isRoot: isRoot)
        case let model as SWBProtocol.VariantGroup: return try VariantGroup(model, pifLoader, isRoot: isRoot)
        case let model as SWBProtocol.FileGroup: return try FileGroup(model, pifLoader, isRoot: isRoot)
        case let model as SWBProtocol.ProductReference: return try ProductReference(model, pifLoader)
            // NOTE: This comes last because it is both a concrete and base type.
        case let model as SWBProtocol.FileReference: return try FileReference(model, pifLoader, isRoot: isRoot)
        default:
            fatalError("unexpected model: \(model)")
        }
    }

    init(_ model: SWBProtocol.Reference, _ pifLoader: PIFLoader) throws {
        #if canImport(Darwin)
        assert(type(of: model) !== SWBProtocol.Reference.self, "unexpected concrete type")
        #endif
        self.guid = model.guid

        // Register with the PIF loader so other items can find us.
        try pifLoader.registerReference(self, for: guid)
    }

    @_spi(Testing) public init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        // Initialize stored properties.
        guid = try Self.parseValueForKeyAsString(PIFKey_guid, pifDict: pifDict)

        // Register with the PIF loader so other items can find us.
        try pifLoader.registerReference(self, for: guid)
    }

    init(guid: String)
    {
        self.guid = guid
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func ==(lhs: Reference, rhs: Reference) -> Bool
    {
        return lhs === rhs
    }

    public var description: String
    {
        return "\(type(of: self))<\(guid):ABSTRACT>"
    }
}

// MARK: GroupTreeReference abstract class


/// A GroupTreeReference is a reference which exists as part of a project's group tree.  ProductReference objects are not part of the group tree.
public class GroupTreeReference: Reference, @unchecked Sendable
{
    /// The parent of this reference in the group tree.  The root group's parent pointer will always be nil, but all other references should have backpointers once the PIF is fully loaded.
    ///
    /// The parent relationships are currently only used by the FilePath resolver.
    //
    // FIXME: <rdar://problem/27956865> Evaluate whether it is worth eliminating GroupTreeReference's parent property
    fileprivate final class Parent: Sendable {
        init(value: GroupTreeReference?) {
            self.value = value
        }
        unowned let value: GroupTreeReference?
    }
    fileprivate let _parent: UnsafeDelayedInitializationSendableWrapper<Parent>
    public var parent: GroupTreeReference? {
        _parent.value.value
    }

    /// The source tree for the reference.
    public let sourceTree: SourceTree

    /// The path for the reference, relative to its source tree.  If its path is absolute, then the source tree is not needed to resolve its absolute path.
    public let path: MacroStringExpression

    init(_ model: SWBProtocol.GroupTreeReference, _ pifLoader: PIFLoader, isRoot: Bool) throws {
        #if canImport(Darwin)
        assert(type(of: model) !== SWBProtocol.GroupTreeReference.self, "unexpected concrete reference")
        #endif
        self.sourceTree = model.sourceTree
        self.path = pifLoader.userNamespace.parseString(model.path)
        self._parent = .init()
        if isRoot {
            self._parent.initialize(to: .init(value: nil))
        }
        try super.init(model, pifLoader)
    }

    init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader, isRoot: Bool) throws {
        // Initialize stored properties.
        // Not all subclasses of GroupTreeReference define a source tree or path in their PIF representation, so we define default values for those which don't.
        switch try Self.parseOptionalValueForKeyAsStringEnum(PIFKey_Reference_sourceTree, pifDict: pifDict) as PIFReferenceSourceTreeValue? {
        case .absolute?:
            sourceTree = .absolute
        case .group?, nil:
            sourceTree = .groupRelative
        case let .buildSetting(name)?:
            sourceTree = .buildSetting(name)
        }

        let pathString: String? = try Self.parseOptionalValueForKeyAsString(PIFKey_path, pifDict: pifDict)
        path = pifLoader.userNamespace.parseString(pathString ?? "")

        self._parent = .init()
        if isRoot {
            self._parent.initialize(to: .init(value: nil))
        }
        try super.init(fromDictionary: pifDict, withPIFLoader: pifLoader)
    }

    /// Parses a ProjectModelItemPIF dictionary as an object of the appropriate subclass of GroupTreeReference.
    public class func parsePIFDictAsReference(_ pifDict: ProjectModelItemPIF, pifLoader: PIFLoader, isRoot: Bool) throws -> GroupTreeReference {
        // Delegate to protocol-based representation, if in use.
        if let data = try parseOptionalValueForKeyAsByteString("data", pifDict: pifDict) {
            let deserializer = MsgPackDeserializer(data)
            let model: SWBProtocol.Reference = try deserializer.deserialize()
            return try Reference.create(model, pifLoader, isRoot: isRoot) as! GroupTreeReference
        }

        // Get the type of the reference.  This is required, so if there isn't one then it will die.
        switch try parseValueForKeyAsStringEnum(PIFKey_type, pifDict: pifDict) as PIFReferenceTypeValue {
        case .file:
            return try FileReference(fromDictionary: pifDict, withPIFLoader: pifLoader, isRoot: isRoot)
        case .group:
            return try FileGroup(fromDictionary: pifDict, withPIFLoader: pifLoader, isRoot: isRoot)
        case .versionGroup:
            return try VersionGroup(fromDictionary: pifDict, withPIFLoader: pifLoader, isRoot: isRoot)
        case .variantGroup:
            return try VariantGroup(fromDictionary: pifDict, withPIFLoader: pifLoader, isRoot: isRoot)
        case .product:
            throw PIFParsingError.custom("Product references should not be included in a project's group tree")
        }
    }

    /// Parses the value for an optional key in a PIF dictionary as an Array of Reference objects.
    /// - returns: An Array value if the key is present, nil if it is absent.
    public class func parseOptionalValueForKeyAsArrayOfChildReferences(_ key: String, pifDict: ProjectModelItemPIF, pifLoader: PIFLoader) throws -> [GroupTreeReference]? {
        return try parseOptionalValueForKeyAsArrayOfPropertyListItems(key, pifDict: pifDict)?.map { (plItem) -> GroupTreeReference in
            guard case .plDict(let pifDict) = plItem else {
                throw PIFParsingError.incorrectTypeInArray(keyName: key, objectType: self, expectedType: "Dictionary")
            }
            return try parsePIFDictAsReference(pifDict, pifLoader: pifLoader, isRoot: false)
        }
    }
}


// MARK: FileReference class


/// A FileReference is the most common kind of Reference, representing a single concrete file on disk.
public final class FileReference: GroupTreeReference, BuildFileRepresentable, @unchecked Sendable
{
    public let fileTypeIdentifier: String
    public let regionVariantName: String?
    /// The file text encoding for the reference.  Will only be non-nil if the file type in Xcode indicated that it is a text type file.
    public let fileTextEncoding: FileTextEncoding?
    public let expectedSignature: String?

    init(_ model: SWBProtocol.FileReference, _ pifLoader: PIFLoader, isRoot: Bool) throws {
        self.fileTypeIdentifier = model.fileTypeIdentifier
        self.regionVariantName = model.regionVariantName
        self.fileTextEncoding = model.fileTextEncoding
        self.expectedSignature = model.expectedSignature
        try super.init(model, pifLoader, isRoot: isRoot)
    }

    @_spi(Testing) public override init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader, isRoot: Bool) throws {
        // Initialize stored properties.
        fileTypeIdentifier = try Self.parseValueForKeyAsString(PIFKey_Reference_fileType, pifDict: pifDict)
        regionVariantName = try Self.parseOptionalValueForKeyAsString(PIFKey_Reference_regionVariantName, pifDict: pifDict)
        if let string = try Self.parseOptionalValueForKeyAsString(PIFKey_Reference_fileTextEncoding, pifDict: pifDict) {
            fileTextEncoding = FileTextEncoding(string)
        } else {
            fileTextEncoding = nil
        }
        expectedSignature = try Self.parseOptionalValueForKeyAsString(PIFKey_Reference_expectedSignature, pifDict: pifDict)

        try super.init(fromDictionary: pifDict, withPIFLoader: pifLoader, isRoot: isRoot)
    }

    override public var description: String
    {
        return "\(type(of: self))<\(guid):\(fileTypeIdentifier):\(sourceTree.debugDescription):\(path.stringRep)>"
    }
}


// MARK: VersionGroup class


/// A VersionGroup is a file reference which contains multiple versions of itself as children.  It is possible (but unlikely, and possibly no longer actively promoted) that individual children may be represented by build files.
public final class VersionGroup: GroupTreeReference, BuildFileRepresentable, @unchecked Sendable
{
    /// The children of this version group, if any.
    public let children: [GroupTreeReference]

    init(_ model: SWBProtocol.VersionGroup, _ pifLoader: PIFLoader, isRoot: Bool) throws {
        self.children = try model.children.map { try Reference.create($0, pifLoader, isRoot: false) as! GroupTreeReference }
        try super.init(model, pifLoader, isRoot: isRoot)

        // Set parent backpointer on children.
        for child in children { child._parent.initialize(to: .init(value: self)) }
    }

    override init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader, isRoot: Bool) throws {
        // Initialize stored properties.
        children = try Self.parseOptionalValueForKeyAsArrayOfChildReferences(PIFKey_Reference_children, pifDict: pifDict, pifLoader: pifLoader) ?? []

        try super.init(fromDictionary: pifDict, withPIFLoader: pifLoader, isRoot: isRoot)

        // Set parent backpointer on children.
        for child in children { child._parent.initialize(to: .init(value: self)) }
    }
}


// MARK: FileGroup class


/// A FileGroup is an abstract grouper of references and groups.  It is commonly used either for conceptual grouping for the benefit of users working with a project (and in this case has no meaningful impact on the build), or to represent a directory on disk which its children are relative to.  In the future it might be able to contribute other meaningful content to the build by, for example, describing build settings which apply to all of its children.
public final class FileGroup: GroupTreeReference, @unchecked Sendable
{
    public let name: String
    public let children: [GroupTreeReference]

    init(_ model: SWBProtocol.FileGroup, _ pifLoader: PIFLoader, isRoot: Bool) throws {
        self.name = model.name
        self.children = try model.children.map { try Reference.create($0, pifLoader, isRoot: false) as! GroupTreeReference }
        try super.init(model, pifLoader, isRoot: isRoot)

        // Set parent backpointer on children.
        for child in children { child._parent.initialize(to: .init(value: self)) }
    }

    @_spi(Testing) public override init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader, isRoot: Bool) throws {
        // Initialize stored properties.
        name = try Self.parseValueForKeyAsString(PIFKey_name, pifDict: pifDict)
        children = try Self.parseOptionalValueForKeyAsArrayOfChildReferences(PIFKey_Reference_children, pifDict: pifDict, pifLoader: pifLoader) ?? []

        try super.init(fromDictionary: pifDict, withPIFLoader: pifLoader, isRoot: isRoot)

        // Set parent backpointer on children.
        for child in children { child._parent.initialize(to: .init(value: self)) }
    }

    override public var description: String
    {
        return "\(type(of: self))<\(guid):\(name):\(sourceTree.debugDescription):\(path.stringRep)>"
    }
}


// MARK: VariantGroup class


/// A VariantGroup represents multiple files which conceptually are different 'variants' (e.g., localized variants) of a single file.  This includes more complex groupings, such as a .xib file and its associated localized .strings files.
public final class VariantGroup: GroupTreeReference, BuildFileRepresentable, @unchecked Sendable
{
    /// The name of this variant group - primarily for debugging purposes.
    public let name: String
    /// The children of this variant group, if any.
    public let children: [GroupTreeReference]

    init(_ model: SWBProtocol.VariantGroup, _ pifLoader: PIFLoader, isRoot: Bool) throws {
        self.name = model.name
        self.children = try model.children.map { try Reference.create($0, pifLoader, isRoot: false) as! GroupTreeReference }
        try super.init(model, pifLoader, isRoot: isRoot)

        // Set parent backpointer on children.
        for child in children { child._parent.initialize(to: .init(value: self)) }
    }

    override init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader, isRoot: Bool) throws {
        // Initialize stored properties.
        name = try Self.parseValueForKeyAsString(PIFKey_name, pifDict: pifDict)
        // FIXME: Is children really optional for variant groups?
        children = try Self.parseOptionalValueForKeyAsArrayOfChildReferences(PIFKey_Reference_children, pifDict: pifDict, pifLoader: pifLoader) ?? []

        try super.init(fromDictionary: pifDict, withPIFLoader: pifLoader, isRoot: isRoot)

        // Set parent backpointer on children.
        for child in children { child._parent.initialize(to: .init(value: self)) }
    }

    override public var description: String
    {
        return "\(type(of: self))<\(guid):\(name)>"
    }
}


// MARK: ProductReference class


/// A ProductReference represents the product of a StandardTarget object.  It acts as a placeholder so that product can be represented in other targets, but it contains no meaningful information itself; rather, it vends information about itself by querying its target for that information.  A ProductReference object is not part of a product's group tree and has no parent property; rather, it is owned by and has an unowned backpointer to its target.
public final class ProductReference: Reference, BuildFileRepresentable
{
    /// The name of this reference - primarily for debugging purposes.
    public let name: String

    init(_ model: SWBProtocol.ProductReference, _ pifLoader: PIFLoader) throws {
        self.name = model.name
        try super.init(model, pifLoader)
    }

    init(guid: String, name: String) {
        self.name = name
        super.init(guid: guid)
    }

    // FIXME: This is almost never used inside of Swift Build. We should think about whether this is really something we want to model with a graph connection.
    //
    /// The producing target of this ProductReference.
    ///
    /// This is assigned as part of the PIF loading process (see `StandardTarget.init`).
    public unowned var target: Target?

    override init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        // Initialize stored properties.
        name = try Self.parseValueForKeyAsString(PIFKey_name, pifDict: pifDict)

        try super.init(fromDictionary: pifDict, withPIFLoader: pifLoader)
    }

    override public var description: String {
        return "\(type(of: self))<\(guid):\(name):target=\(target?.name ?? "<none>")>"
    }
}
