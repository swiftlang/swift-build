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
public import SWBMacro
import Foundation

public enum DuplicatedIdentifierObjectType: String, Sendable {
    case project
    case target
    case reference
}

public enum WorkspaceErrors: Error {
    /// The workspace has multiple projects which contain the same target with the specified guid.
    case duplicateProjectsForTarget(_ guid: String)
    /// The workspace has multiple objects with the same guid.
    case duplicateIdentifiers(_ type: DuplicatedIdentifierObjectType, _ guid: String)
    /// The workspace has a reference to a missing package.
    case missingPackageProduct(_ packageName: String)
    /// The workspace has a reference to a missing file.
    case missingFileReference(_ guid: String)
    /// The workspace has a reference to a missing target.
    case missingTargetProductReference(_ guid: String)
    /// References by name cannot be resolved.
    case namedReferencesCannotBeResolved(_ name: String)
}

extension WorkspaceErrors: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .duplicateProjectsForTarget(guid):
            return "The workspace has multiple projects which contain the same target with the GUID '\(guid)'"
        case let .duplicateIdentifiers(type, guid):
            return "The workspace contains multiple \(type.rawValue)s with the same GUID '\(guid)'"
        case let .missingPackageProduct(packageName):
            return "The workspace has a reference to a missing package product named '\(packageName)'"
        case let .missingFileReference(guid):
            return "The workspace has a reference to a missing file with GUID '\(guid)'"
        case let .missingTargetProductReference(guid):
            return "The workspace has a reference to a missing target with GUID '\(guid)'"
        case let .namedReferencesCannotBeResolved(name):
            return "Named reference '\(name)' cannot be resolved"
        }
    }
}

public final class Workspace: ProjectModelItem, PIFObject, ReferenceLookupContext, Encodable
{
    static func referencedObjects(for data: EncodedPIFValue) throws -> [PIFObjectReference] {
        switch data {
        case .json(let data):
            // The only direct references are to projects.
            guard case let .plArray(projects)? = data["projects"] else { return [] }
            return projects.compactMap{
                guard case let .plString(signature) = $0 else { return nil }
                return PIFObjectReference(signature: signature, type: .project)
            }

        case .binary(let data):
            // The only direct references are to projects.
            //
            // FIXME: This sucks, we are doing the protocol decode twice: <rdar://problem/31097863> Don't require duplicate binary PIF decode in incremental PIF transfer
            let deserializer = MsgPackDeserializer(data)
            let model: SWBProtocol.Workspace = try deserializer.deserialize()
            return model.projectSignatures.map{ PIFObjectReference(signature: $0, type: .project) }
        }
    }

    static func construct(from data: EncodedPIFValue, signature: PIFObject.Signature, loader: PIFLoader) throws -> Workspace {
        switch data {
        case .json(let data):
            return try construct(from: data, signature: signature, loader: loader)
        case .binary(let data):
            let deserializer = MsgPackDeserializer(data)
            let model: SWBProtocol.Workspace = try deserializer.deserialize()
            return try Workspace(model, loader, signature: signature)
        }
    }

    static func construct(from data: ProjectModelItemPIF, signature: PIFObject.Signature, loader: PIFLoader) throws -> Workspace {
        // Delegate to protocol-based representation, if in use.
        if let data = try parseOptionalValueForKeyAsByteString("data", pifDict: data) {
            let deserializer = MsgPackDeserializer(data)
            let model: SWBProtocol.Workspace = try deserializer.deserialize()
            return try Workspace(model, loader, signature: signature)
        }
        return try Workspace(fromDictionary: data, signature: signature, withPIFLoader: loader)
    }

    /// The PIFObject type name
    static let pifType = PIFObjectType.workspace

    /// A unique signature for the workspace.
    public let signature: String

    /// The GUID for the workspace.
    public let guid: String

    /// The name of the workspace.
    public let name: String

    /// The path to the workspace's `.xcworkspace` file on disk.
    public let path: Path

    /// The list of projects which the workspace directly contains.  This does not distinguish between top-level projects and "nested" projects, because the PIF Xcode sends us flattens any such layering, so Swift Build never sees it.
    public let projects: [Project]

    /// The namespace for user build settings defined during loading the workspace's PIF.  Its parent is the internal namespace for the core `SpecRegistry`.
    public let userNamespace: MacroNamespace

    /// The map of all projects keyed by GUID.
    private let projectsByGUID: [String: Project]

    /// The map of all targets keyed by GUID.
    private let targetsByGUID: [String: Target]

    /// The map of targets to projects.
    private let projectsByTarget: [Target: Project]

    /// The map of all references keyed by GUID.
    private let referencesByGUID: [String: Reference]

    /// The map of all targets keyed by name.
    private let projectsByName: [String: [Project]]

    private enum CodingKeys: CodingKey {
        case signature
        case guid
        case name
        case path
        case projects
    }

    init(_ model: SWBProtocol.Workspace, _ pifLoader: PIFLoader, signature: String) throws {
        self.signature = signature
        self.guid = model.guid
        self.name = model.name
        self.path = model.path
        self.projects = try model.projectSignatures.map{ try pifLoader.loadReference(signature: $0, type: Project.self) }

        // The PIFLoader creates the user namespace which is used during loading, but the workspace ultimately owns it.
        self.userNamespace = pifLoader.userNamespace

        // Construct the map of projects and group tree references.
        var referencesByGUID = [String: Reference]()
        func visit(_ reference: Reference) throws {
            if referencesByGUID.updateValue(reference, forKey: reference.guid) != nil {
                throw WorkspaceErrors.duplicateIdentifiers(.reference, reference.guid)
            }
            switch reference {
            case let asGroup as FileGroup:
                try asGroup.children.forEach(visit)
            case let asGroup as VersionGroup:
                try asGroup.children.forEach(visit)
            case let asGroup as VariantGroup:
                try asGroup.children.forEach(visit)
            default:
                break
            }
        }
        for project in projects {
            try visit(project.groupTree)
        }
        self.projectsByGUID = try projects.byGUID
        self.targetsByGUID = try projects.targetsByGUID
        self.projectsByTarget = try projects.byTarget
        self.referencesByGUID = referencesByGUID
        self.projectsByName = Dictionary(grouping: projects, by: { $0.name })
    }

    /// Create the workspace from a PIF property list.
    @_spi(Testing) public init(fromDictionary pifDict: ProjectModelItemPIF, signature: String, withPIFLoader pifLoader: PIFLoader) throws
    {
        self.signature = signature

        // The PIFLoader creates the user namespace which is used during loading, but the workspace ultimately owns it.
        self.userNamespace = pifLoader.userNamespace

        // Load the contents of the PIF.
        guid = try Self.parseValueForKeyAsString(PIFKey_guid, pifDict: pifDict)

        name = try Self.parseValueForKeyAsString(PIFKey_name, pifDict: pifDict)

        path = try Path(Self.parseValueForKeyAsString(PIFKey_path, pifDict: pifDict))

        projects = try Self.parseValueForKeyAsArrayOfIndirectObjects(PIFKey_Workspace_projects, pifDict: pifDict, pifLoader: pifLoader)

        // Construct the map of projects and group tree references.
        var referencesByGUID = [String: Reference]()
        func visit(_ reference: Reference) throws {
            if referencesByGUID.updateValue(reference, forKey: reference.guid) != nil {
                throw WorkspaceErrors.duplicateIdentifiers(.reference, reference.guid)
            }
            switch reference {
            case let asGroup as FileGroup:
                try asGroup.children.forEach(visit)
            case let asGroup as VersionGroup:
                try asGroup.children.forEach(visit)
            case let asGroup as VariantGroup:
                try asGroup.children.forEach(visit)
            default:
                break
            }
        }
        for project in projects {
            try visit(project.groupTree)
        }
        self.projectsByGUID = try projects.byGUID
        self.targetsByGUID = try projects.targetsByGUID
        self.projectsByTarget = try projects.byTarget
        self.referencesByGUID = referencesByGUID
        self.projectsByName = Dictionary(grouping: projects, by: { $0.name })
    }

    /// A sequence of all targets in the workspace.
    ///
    /// The targets will appear in the order they are within each nested project.
    public var allTargets: AnySequence<Target> {
        return AnySequence(projects.lazy.flatMap{ $0.targets })
    }

    /// Find project with the given project GUID.
    public func project(for guid: String) -> Project? {
        return projectsByGUID[guid]
    }

    /// Find the target with the given GUID.
    public func target(for guid: String) -> Target? {
        return targetsByGUID[guid]
    }

    /// Finds all of the targets with the given name.
    public func targets(named: String) -> [Target] {
        return allTargets.filter({ $0.name == named })
    }

    /// Check if the workspace contains the given target.
    public func contains(target: Target) -> Bool {
        return projectsByTarget.contains(target)
            || (self.target(for: target.guid).map(projectsByTarget.contains) ?? false)
    }

    /// Find the project containing the given target.
    ///
    /// - Precondition: workspace.contains(target)
    public func project(for target: Target) -> Project {
        guard let project = projectsByTarget[target]
                ?? (self.target(for: target.guid).map({ projectsByTarget[$0] }) ?? nil) else {
            preconditionFailure("workspace '\(name)' does not contain target '\(target.name)'")
        }
        return project
    }

    /// Find the projects with the given name.
    public func projects(named name: String) -> [Project] {
        return projectsByName[name] ?? []
    }

    /// Resolve a build file's buildable item.
    /// - Parameters:
    ///   - item: The buildable item reference to resolve.
    ///   - dynamicallyBuildingTargets: If the product reference references a target in this list, the product reference of the target referenced by `dynamicTargetVariantGuid` will be returned instead of the product reference of the package product target itself. This parameter is only relevant if `item` references a package product target.
    public func resolveBuildableItemReference(_ item: BuildFile.BuildableItem, dynamicallyBuildingTargets: Set<Target> = []) throws -> Reference {
        switch item {
        case .reference(let guid):
            if let ref = lookupReference(for: guid) {
                return ref
            } else {
                throw WorkspaceErrors.missingFileReference(guid)
            }

        case .targetProduct(let guid):
            switch dynamicTarget(for: guid, dynamicallyBuildingTargets: dynamicallyBuildingTargets) {
            case let target as StandardTarget:
                return target.productReference
            case let target as PackageProductTarget:
                return target.productReference
            default:
                // FIXME: This is a bit unfortunate, but should be fine in practice, since GUIDs from traditional projects will never look this way.
                if guid.hasPrefix("PACKAGE-PRODUCT:") {
                    let packageName = guid.components(separatedBy: ":").dropFirst().joined(separator: ":")
                    throw WorkspaceErrors.missingPackageProduct(packageName)
                } else {
                    throw WorkspaceErrors.missingTargetProductReference(guid)
                }
            }

        case let .namedReference(name, _):
            throw WorkspaceErrors.namedReferencesCannotBeResolved(name)
        }
    }

    /// Returns the dynamic target variant if this target has a dynamic variant, otherwise returns the input target.
    public func dynamicTarget(for guid: String, dynamicallyBuildingTargets: Set<Target> = []) -> Target? {
        return target(for: guid).map { target in dynamicTarget(for: target, dynamicallyBuildingTargets: dynamicallyBuildingTargets) } ?? nil
    }

    /// Returns the dynamic target variant if this target has a dynamic variant, otherwise returns the input target.
    public func dynamicTarget(for target: Target, dynamicallyBuildingTargets: Set<Target> = []) -> Target {
        if dynamicallyBuildingTargets.contains(target), let dynamicTargetVariantGuid = target.dynamicTargetVariantGuid, let target = self.target(for: dynamicTargetVariantGuid) {
            return target
        } else {
            return target
        }
    }

    /// Resolve the reference for the given GUID.
    //
    // FIXME: This is fairly unfortunate, from a performance perspective, we could have pre-bound these things at load time; except that we reuse loaded objects during incremental PIF loading, so we need to guarantee that they are self-contained and don't contain external references. For now, we manage this by deferring the lookup until runtime. See:
    public func lookupReference(for guid: String ) -> Reference? {
        return referencesByGUID[guid]
    }

    public func diff(against other: Workspace) -> WorkspaceDiff {
        var diff = WorkspaceDiff()

        let projectDiff = projectsByGUID.keys.diff(against: other.projectsByGUID.keys)
        diff.leftProjects = projectDiff.left.map { projectsByGUID[$0]! }
        diff.rightProjects = projectDiff.right.map { other.projectsByGUID[$0]! }

        let targetDiff = targetsByGUID.keys.diff(against: other.targetsByGUID.keys)
        diff.leftTargets = targetDiff.left.map { targetsByGUID[$0]! }
        diff.rightTargets = targetDiff.right.map { other.targetsByGUID[$0]! }

        let referenceDiff = referencesByGUID.keys.diff(against: other.referencesByGUID.keys)
        diff.leftReferences = referenceDiff.left.map { referencesByGUID[$0]! }
        diff.rightReferences = referenceDiff.right.map { other.referencesByGUID[$0]! }

        return diff
    }
}


extension Workspace: CustomStringConvertible
{
    public var description: String
    {
        return "\(type(of: self))<\(guid):\(name):\(path.str):\(projects.count) projects>"
    }
}


public struct WorkspaceDiff: CustomStringConvertible, Sendable {
    public var leftProjects: [Project] = []
    public var rightProjects: [Project] = []

    public var leftTargets: [Target] = []
    public var rightTargets: [Target] = []

    public var leftReferences: [Reference] = []
    public var rightReferences: [Reference] = []

    public var hasChanges: Bool {
        return !leftProjects.isEmpty ||
            !rightProjects.isEmpty ||
            !leftTargets.isEmpty ||
            !rightTargets.isEmpty ||
            !leftReferences.isEmpty ||
            !rightReferences.isEmpty
    }

    public var description: String {
        return """
        \(type(of: self))<
            leftProjects: \(leftProjects),
            rightProjects: \(rightProjects),
            leftTargets: \(leftTargets),
            rightTargets: \(rightTargets),
            leftReferences: \(leftReferences),
            rightReferences: \(rightReferences)
        >
        """
    }
}

extension Array where Element == Project {
    fileprivate var targetsByGUID: [String: Target] {
        get throws {
            try Dictionary(grouping: flatMap(\.targets), by: \.guid).compactMapValues({ guid, targets in
                guard let target = targets.only else {
                    throw WorkspaceErrors.duplicateIdentifiers(.target, guid)
                }
                return target
            })
        }
    }

    fileprivate var byTarget: [Target: Project] {
        get throws {
            try Dictionary(grouping: flatMap { project in project.targets.map { target in (project, target) } }, by: { $0.1 }).mapValues { $0.map { $0.0 } }.compactMapValues({ target, projects in
                guard let project = projects.only else {
                    throw WorkspaceErrors.duplicateProjectsForTarget(target.guid)
                }
                return project
            })
        }
    }

    fileprivate var byGUID: [String: Project] {
        get throws {
            try Dictionary(grouping: self, by: \.guid).compactMapValues({ guid, projects in
                guard let project = projects.only else {
                    throw WorkspaceErrors.duplicateIdentifiers(.project, guid)
                }
                return project
            })
        }
    }
}
