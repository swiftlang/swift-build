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

/// This is used as part of the signature for the high-level PIF objects, to ensure that changes to the PIF schema are represented by the objects which do not use a content-based signature scheme (workspaces and projects, currently).
public var pifEncodingSchemaVersion: Int {
    return PIFObject.supportedPIFEncodingSchemaVersion
}

public enum PIF {
    /// The type used for identifying PIF objects.
    public typealias GUID = String

    enum Error: Swift.Error {
        case duplicatedTargetIdentifier(targetIdentifier: String, targetName: String, productName: String)
        case emptyTargetIdentifier(targetName: String, productName: String)
        case emptyTargetName(targetIdentifier: String, productName: String)
    }

    /// A PIF project, consisting of a tree of groups and file references, a list of targets, and some additional information.
    public class Project {
        public let id: String
        public let name: String
        public var developmentRegion: String?
        public var path: String
        public let mainGroup: Group
        public var buildConfigs: [BuildConfig]
        public var productGroup: Group?
        public var projectDir: String
        public var targets: [BaseTarget]
        public var isPackage: Bool

        public convenience init(id: String, path: String, projectDir: String, name: String) {
            self.init(id: id, path: path, projectDir: projectDir, name: name, isPackage: true)
        }

        public init(id: String, path: String, projectDir: String, name: String, isPackage: Bool) {
            precondition(!id.isEmpty)
            precondition(!path.isEmpty)
            precondition(!projectDir.isEmpty)
            self.id = id
            self.name = name
            self.path = path
            self.mainGroup = Group(id: "\(id)::MAINGROUP", path: "")
            self.buildConfigs = []
            self.productGroup = nil
            self.projectDir = projectDir
            self.targets = []
            self.isPackage = isPackage
        }

        public convenience init(id: String, path: String, projectDir: String, name: String, developmentRegion: String?) {
            self.init(id: id, path: path, projectDir: projectDir, name: name)
            self.developmentRegion = developmentRegion
        }

        private var nextTargetId: String {
            return "\(self.id)::TARGET_\(targets.count)"
        }

        /// Creates and adds a new empty target, i.e. one that does not initially have any build phases.  If provided, the ID must be non-empty and unique within the PIF workspace; if not provided, an arbitrary guaranteed-to-be-unique identifier will be assigned.  The name must not be empty and must not be equal to the name of any existing target in the project.
        @discardableResult public func addTargetThrowing(id idOpt: String? = nil, productType: Target.ProductType, name: String, productName: String, approvedByUser: Bool) throws -> Target {
            let id = idOpt ?? nextTargetId
            guard !name.isEmpty else {
                throw Error.emptyTargetName(targetIdentifier: id, productName: productName)
            }
            guard !id.isEmpty else {
                throw Error.emptyTargetIdentifier(targetName: name, productName: productName)
            }
            guard !targets.contains(where: { $0.id == id }) else {
                throw Error.duplicatedTargetIdentifier(targetIdentifier: id, targetName: name, productName: productName)
            }
            let target = Target(id: id, productType: productType, name: name, productName: productName, approvedByUser: approvedByUser)
            targets.append(target)
            return target
        }

        @discardableResult public func addTargetThrowing(id idOpt: String? = nil, productType: Target.ProductType, name: String, productName: String) throws -> Target {
            return try addTargetThrowing(id: idOpt, productType: productType, name: name, productName: productName, approvedByUser: true)
        }

        @discardableResult public func addTarget(id idOpt: String? = nil, productType: Target.ProductType, name: String, productName: String) -> Target {
            do {
                return try addTargetThrowing(id: idOpt, productType: productType, name: name, productName: productName)
            } catch {
                fatalError("\(error)")
            }
        }

        @discardableResult public func addAggregateTarget(id idOpt: String? = nil, name: String) -> AggregateTarget {
            let id = idOpt ?? nextTargetId
            precondition(!id.isEmpty)
            precondition(!targets.contains{ $0.id == id })
            precondition(!name.isEmpty)
            let target = AggregateTarget(id: id, name: name)
            targets.append(target)
            return target
        }

        /// Creates and adds a new empty build configuration, i.e. one that does not initially have any build settings.  The name must not be empty and must not be equal to the name of any existing build configuration in the project.
        @discardableResult public func addBuildConfig(name: String, settings: BuildSettings = BuildSettings(), impartedBuildSettings: BuildSettings) -> BuildConfig {
            precondition(!name.isEmpty)
            precondition(!buildConfigs.contains{ $0.name == name })
            let id = "\(self.id)::BUILDCONFIG_\(buildConfigs.count)"
            let buildConfig = BuildConfig(id: id, name: name, settings: settings, impartedBuildSettings: impartedBuildSettings)
            buildConfigs.append(buildConfig)
            return buildConfig
        }

        @discardableResult public func addBuildConfig(name: String, settings: BuildSettings = BuildSettings()) -> BuildConfig {
            return addBuildConfig(name: name, settings: settings, impartedBuildSettings: BuildSettings())
        }
    }

    /// Abstract base class for all items in the group hierarchy.
    public class Reference {
        public let id: String

        /// Relative path of the reference.  It is usually a literal, but may in fact contain build settings.
        public var path: String

        /// Determines the base path for the reference's relative path.
        public var pathBase: RefPathBase

        /// Name of the reference, if different from the last path component (if not set, the last path component will be used as the name).
        public var name: String? = nil

        /// Determines the base path for a reference's relative path.
        public enum RefPathBase: String, Sendable {
            /// Indicates that the path is relative to the source root (i.e. the "project directory").
            case projectDir = "SOURCE_ROOT"

            /// Indicates that the path is relative to the path of the parent group.
            case groupDir = "<group>"

            /// Indicates that the path is relative to the effective build directory (which varies depending on active scheme, active run destination, or even an overridden build setting.
            case buildDir = "BUILT_PRODUCTS_DIR"

            /// Indicates that the path is an absolute path.
            case absolute = "<absolute>"

            /// The string form, suitable for use in the PIF representation.
            public var asString: String { return rawValue }
        }

        public init(id: String, path: String, pathBase: RefPathBase = .groupDir, name: String? = nil) {
            self.id = id
            self.path = path
            self.pathBase = pathBase
            self.name = name
        }
    }

    /// A reference to a file system entity (a file, folder, etc).
    public class FileReference : Reference {
        public var fileType: String?
        public var expectedSignature: String?

        public init(id: String, path: String, pathBase: RefPathBase = .groupDir, name: String? = nil, fileType: String? = nil, expectedSignature: String?) {
            super.init(id: id, path: path, pathBase: pathBase, name: name)
            self.fileType = fileType
            self.expectedSignature = expectedSignature
        }
    }

    /// A group that can contain References (FileReferences and other Groups).  The resolved path of a group is used as the base path for any child references whose source tree type is GroupRelative.
    public class Group : Reference {
        public var subitems = [Reference]()

        private var nextRefId: String {
            return "\(self.id)::REF_\(subitems.count)"
        }

        /// Creates and appends a new Group to the list of subitems.  The new group is returned so that it can be configured.
        public func addGroup(path: String, pathBase: RefPathBase = .groupDir, name: String? = nil) -> Group {
            let group = Group(id: nextRefId, path: path, pathBase: pathBase, name: name)
            subitems.append(group)
            return group
        }

        /// Creates and appends a new FileReference to the list of subitems.
        public func addFileReference(path: String, pathBase: RefPathBase = .groupDir, name: String? = nil, fileType: String? = nil) -> FileReference {
            // TODO: Keep for ABI.
            return self.addFileReference(path: path, pathBase: pathBase, name: name, fileType: fileType, expectedSignature: nil)
        }
        public func addFileReference(path: String, pathBase: RefPathBase = .groupDir, name: String? = nil, fileType: String? = nil, expectedSignature: String?) -> FileReference {
            let fref = FileReference(id: nextRefId, path: path, pathBase: pathBase, name: name, fileType: fileType, expectedSignature: expectedSignature)
            subitems.append(fref)
            return fref
        }
    }

    public class BaseTarget {
        public let id: String
        public var signature: String?
        public var name: String
        public var buildConfigs: [BuildConfig]
        public var buildPhases: [BuildPhase]
        public var buildRules: [BuildRule]
        public var customTasks: [CustomTask]
        public var dependencies: [TargetDependency]
        public init(id: String, name: String) {
            self.id = id
            self.name = name
            self.buildConfigs = []
            self.buildPhases = []
            self.buildRules = []
            self.customTasks = []
            self.dependencies = []
        }

        /// Creates and adds a new empty build configuration, i.e. one that does not initially have any build settings.  The name must not be empty and must not be equal to the name of any existing build configuration in the target.
        @discardableResult public func addBuildConfig(name: String, settings: BuildSettings = BuildSettings(), impartedBuildSettings: BuildSettings) -> BuildConfig {
            precondition(!name.isEmpty)
            precondition(!buildConfigs.contains{ $0.name == name })
            let id = "\(self.id)::BUILDCONFIG_\(buildConfigs.count)"
            let buildConfig = BuildConfig(id: id, name: name, settings: settings, impartedBuildSettings: impartedBuildSettings)
            buildConfigs.append(buildConfig)
            return buildConfig
        }

        @discardableResult public func addBuildConfig(name: String, settings: BuildSettings = BuildSettings()) -> BuildConfig {
            return addBuildConfig(name: name, settings: settings, impartedBuildSettings: BuildSettings())
        }

        /// Represents a dependency on another target (identified by its PIF ID).
        public struct TargetDependency: Sendable {
            /// Identifier of depended-upon target.
            public let targetId: String
            /// The platform filters for this target dependency.
            public let platformFilters: Set<PlatformFilter>
        }

        /// Adds a dependency on another target.  It is the caller's responsibility to avoid creating dependency cycles.  A dependency of one target on another ensures that the other target is built first.
        public func addDependency(on targetId: String, platformFilters: Set<PlatformFilter>) {
            dependencies.append(TargetDependency(targetId: targetId, platformFilters: platformFilters))
        }

        /// Extension/override point to customize behavior of `PIFRepresentable.serialize(to:)`
        internal func _serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
            fatalError("target subclasses need to implement their own serialization")
        }
    }

    public class AggregateTarget: BaseTarget {
        internal override func _serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
            return [
                PIFKey_type: "aggregate",
                PIFKey_guid: id,
                PIFKey_name: name,
                PIFKey_Target_dependencies: dependencies.map { [
                    PIFKey_guid: $0.targetId,
                    PIFKey_platformFilters: $0.platformFilters.map{ $0.serialize(to: serializer) }
                ] },
                PIFKey_Target_buildRules: buildRules.map{ $0.serialize(to: serializer) },
                PIFKey_Target_buildPhases: buildPhases.map{ ($0 as! (any PIFRepresentable)).serialize(to: serializer) },
                PIFKey_Target_customTasks: customTasks.map { $0.serialize(to: serializer) },
                PIFKey_buildConfigurations: buildConfigs.map{ $0.serialize(to: serializer) },
            ]
        }
    }

    /// An Xcode target, representing a single entity to build.
    public class Target : BaseTarget {
        public var productName: String
        public var productType: ProductType
        public var productReference: FileReference?
        public var approvedByUser: Bool

        /// Package products can have an optional reference to a dynamic target which allows building the same product dynamically instead.
        public var dynamicTargetVariant: Target? {
            didSet {
                guard dynamicTargetVariant != nil else { return }
            }
        }

        public enum ProductType: String, Sendable {
            case application = "com.apple.product-type.application"
            case staticArchive = "com.apple.product-type.library.static"
            case objectFile = "com.apple.product-type.objfile"
            case dynamicLibrary = "com.apple.product-type.library.dynamic"
            case framework = "com.apple.product-type.framework"
            case executable = "com.apple.product-type.tool"
            case hostBuildTool = "com.apple.product-type.tool.host-build"
            case unitTest = "com.apple.product-type.bundle.unit-test"
            case bundle = "com.apple.product-type.bundle"
            case packageProduct = "packageProduct"
            public var asString: String { return rawValue }
        }
        public init(id: String, productType: ProductType, name: String, productName: String, approvedByUser: Bool) {
            self.productType = productType
            self.productName = productName
            self.approvedByUser = approvedByUser
            super.init(id: id, name: name)
        }

        public convenience init(id: String, productType: ProductType, name: String, productName: String) {
            self.init(id: id, productType: productType, name: name, productName: productName, approvedByUser: true)
        }

        private var nextBuildPhaseId: String {
            return "\(self.id)::BUILDPHASE_\(buildPhases.count)"
        }

        /// Adds a "headers" build phase, i.e. one that copies headers into a directory of the product, after suitable processing.
        @discardableResult public func addHeadersBuildPhase() -> HeadersBuildPhase {
            let phase = HeadersBuildPhase(id: nextBuildPhaseId)
            buildPhases.append(phase)
            return phase
        }

        /// Adds a "sources" build phase, i.e. one that compiles sources and provides them to be linked into the executable code of the product.
        @discardableResult public func addSourcesBuildPhase() -> SourcesBuildPhase {
            let phase = SourcesBuildPhase(id: nextBuildPhaseId)
            buildPhases.append(phase)
            return phase
        }

        /// Adds a "frameworks" build phase, i.e. one that links compiled code and libraries into the executable of the product.
        @discardableResult public func addFrameworksBuildPhase() -> FrameworksBuildPhase {
            let phase = FrameworksBuildPhase(id: nextBuildPhaseId)
            buildPhases.append(phase)
            return phase
        }

        /// Adds a "copy files" build phase, i.e. one that copies files to an arbitrary location relative to the product.
        @discardableResult public func addCopyFilesBuildPhase(destinationSubfolder: CopyFilesBuildPhase.DestinationSubfolder, destinationSubpath: String = "", runOnlyForDeploymentPostprocessing: Bool = false) -> CopyFilesBuildPhase {
            let phase = CopyFilesBuildPhase(id: nextBuildPhaseId,
                                            destinationSubfolder: destinationSubfolder,
                                            destinationSubpath: destinationSubpath,
                                            runOnlyForDeploymentPostprocessing: runOnlyForDeploymentPostprocessing)
            buildPhases.append(phase)
            return phase
        }

        @discardableResult public func addCopyBundleResourcesBuildPhase() -> CopyBundleResourcesBuildPhase {
            let phase = CopyBundleResourcesBuildPhase(id: nextBuildPhaseId)
            buildPhases.append(phase)
            return phase
        }

        /// Adds a "shell script" build phase, i.e. one that runs a custom shell script as part of the build.
        @discardableResult public func addShellScriptBuildPhase(
            name: String,
            shellPath: String = "/bin/sh",
            scriptContents: String,
            inputPaths: [String],
            outputPaths: [String],
            emitEnvironment: Bool = false,
            alwaysOutOfDate: Bool = false,
            runOnlyForDeploymentPostprocessing: Bool = false,
            originalObjectID: String,
            insertAtFront: Bool = false
        ) -> ShellScriptBuildPhase {
            return addShellScriptBuildPhaseWithConfigurableSandboxing(
                name: name,
                shellPath: shellPath,
                scriptContents: scriptContents,
                inputPaths: inputPaths,
                outputPaths: outputPaths,
                emitEnvironment: emitEnvironment,
                alwaysOutOfDate: alwaysOutOfDate,
                runOnlyForDeploymentPostprocessing: runOnlyForDeploymentPostprocessing,
                originalObjectID: originalObjectID,
                insertAtFront: insertAtFront)
        }

        /// Adds a "shell script" build phase, i.e. one that runs a custom shell script as part of the build.
        @discardableResult public func addShellScriptBuildPhaseWithConfigurableSandboxing(
            name: String,
            shellPath: String = "/bin/sh",
            scriptContents: String,
            inputPaths: [String],
            outputPaths: [String],
            emitEnvironment: Bool = false,
            alwaysOutOfDate: Bool = false,
            runOnlyForDeploymentPostprocessing: Bool = false,
            originalObjectID: String,
            insertAtFront: Bool = false,
            sandboxingOverride: SandboxingOverride = .basedOnBuildSetting,
            alwaysRunForInstallHdrs: Bool = false
        ) -> ShellScriptBuildPhase {
            let phase = ShellScriptBuildPhase(
                id: nextBuildPhaseId,
                name: name,
                shellPath: shellPath,
                scriptContents: scriptContents,
                inputPaths: inputPaths,
                outputPaths: outputPaths,
                emitEnvironment: emitEnvironment,
                alwaysOutOfDate: alwaysOutOfDate,
                runOnlyForDeploymentPostprocessing: runOnlyForDeploymentPostprocessing,
                originalObjectID: originalObjectID,
                sandboxingOverride: sandboxingOverride,
                alwaysRunForInstallHdrs: alwaysRunForInstallHdrs)
            if insertAtFront {
                buildPhases.insert(phase, at: 0)
            } else {
                buildPhases.append(phase)
            }
            return phase
        }

        private var nextBuildRuleId: String {
            return "\(self.id)::BUILDRULE_\(buildRules.count)"
        }

        /// Adds a build rule with an input specifying files to match and an action specifying either a compiler or a shell script.
        @discardableResult public func addBuildRule(name: String, input: BuildRule.Input, action: BuildRule.Action) -> BuildRule {
            let rule = BuildRule(id: nextBuildRuleId, name: name, input: input, action: action)
            buildRules.append(rule)
            return rule
        }

        /// Adds a dependency on another target.  It is the caller's responsibility to avoid creating dependency cycles.  A dependency of one target on another ensures that the other target is built first.  If `linkProduct` is true, the receiver will also be configured to link against the product produced by the other target (this presumes that the product type is one that can be linked against).
        public func addDependency(on targetId: String, platformFilters: Set<PlatformFilter>, linkProduct: Bool) {
            super.addDependency(on: targetId, platformFilters: platformFilters)
            if linkProduct {
                let frameworksPhase = buildPhases.first{ $0 is FrameworksBuildPhase } ?? addFrameworksBuildPhase()
                frameworksPhase.addBuildFile(productOf: targetId, platformFilters: platformFilters)
            }
        }

        public func addDependency(on targetId: String, linkProduct: Bool) {
            self.addDependency(on: targetId, platformFilters: [], linkProduct: linkProduct)
        }

        /// Convenience function to add a file reference to the Headers build phase, after creating it if needed.
        @discardableResult public func addHeaderFile(ref: FileReference) -> BuildFile {
            let headerPhase = buildPhases.first{ $0 is HeadersBuildPhase } ?? addHeadersBuildPhase()
            return headerPhase.addBuildFile(fileRef: ref)
        }

        /// Convenience function to add a file reference to the Sources build phase, after creating it if needed.
        @discardableResult public func addSourceFile(ref: FileReference, generatedCodeVisibility: BuildFile.GeneratedCodeVisibility?) -> BuildFile {
            let sourcesPhase = buildPhases.first{ $0 is SourcesBuildPhase } ?? addSourcesBuildPhase()
            return sourcesPhase.addBuildFile(fileRef: ref, generatedCodeVisibility: generatedCodeVisibility)
        }

        @discardableResult public func addSourceFile(ref: FileReference) -> BuildFile {
            let sourcesPhase = buildPhases.first{ $0 is SourcesBuildPhase } ?? addSourcesBuildPhase()
            return sourcesPhase.addBuildFile(fileRef: ref, generatedCodeVisibility: nil)
        }

        /// Convenience function to add a file reference to the Frameworks build phase, after creating it if needed.
        @discardableResult public func addLibrary(ref: FileReference, platformFilters: Set<PlatformFilter>, codeSignOnCopy: Bool = false, removeHeadersOnCopy: Bool = false) -> BuildFile {
            let frameworksPhase = buildPhases.first{ $0 is FrameworksBuildPhase } ?? addFrameworksBuildPhase()
            return frameworksPhase.addBuildFile(fileRef: ref, platformFilters: platformFilters, codeSignOnCopy: codeSignOnCopy, removeHeadersOnCopy: removeHeadersOnCopy)
        }

        @_disfavoredOverload @discardableResult public func addLibrary(ref: FileReference, codeSignOnCopy: Bool = false, removeHeadersOnCopy: Bool = false) -> BuildFile {
            self.addLibrary(ref: ref, platformFilters: [], codeSignOnCopy: codeSignOnCopy, removeHeadersOnCopy: removeHeadersOnCopy)
        }

        @_disfavoredOverload @discardableResult public func addLibrary(ref: FileReference) -> BuildFile {
            self.addLibrary(ref: ref, codeSignOnCopy: false)
        }

        @discardableResult public func addResourceFile(ref: FileReference, platformFilters: Set<PlatformFilter>, resourceRule: BuildFile.ResourceRule? = nil) -> BuildFile {
            let resourcesPhase = buildPhases.first{ $0 is CopyBundleResourcesBuildPhase } ?? addCopyBundleResourcesBuildPhase()
            return resourcesPhase.addBuildFile(fileRef: ref, platformFilters: platformFilters, resourceRule: resourceRule)
        }

        @_disfavoredOverload @discardableResult public func addResourceFile(ref: FileReference, platformFilters: Set<PlatformFilter>) -> BuildFile {
            self.addResourceFile(ref: ref, platformFilters: platformFilters, resourceRule: nil)
        }

        @_disfavoredOverload @discardableResult public func addResourceFile(ref: FileReference) -> BuildFile {
            self.addResourceFile(ref: ref, platformFilters: [])
        }

        internal override func _serialize(to serializer: any IDEPIFSerializer) -> PIFDict {
            if productType == .packageProduct {
                var result: [String: Any] = [
                    PIFKey_type: "packageProduct",
                    PIFKey_guid: id,
                    PIFKey_name: name,
                    PIFKey_Target_customTasks: customTasks.map { $0.serialize(to: serializer) },
                    PIFKey_Target_dependencies: dependencies.map{ [
                        PIFKey_guid: $0.targetId,
                        PIFKey_platformFilters: $0.platformFilters.map{ $0.serialize(to: serializer) }
                    ] },
                    PIFKey_buildConfigurations: buildConfigs.map{ $0.serialize(to: serializer) },
                ]
                // Add the framework build phase, if present.
                if let phase = buildPhases.first as? PIF.FrameworksBuildPhase {
                    result[PIFKey_Target_frameworksBuildPhase] = phase.serialize(to: serializer)
                }
                if let dynamicTargetVariant = dynamicTargetVariant {
                    result[PIFKey_Target_dynamicTargetVariantGuid] = dynamicTargetVariant.id
                }
                result[PIFKey_Target_approvedByUser] = approvedByUser ? "true" : "false"
                return result
            }
            var result: [String: Any] = [
                PIFKey_type: "standard",
                PIFKey_guid: id,
                PIFKey_name: name,
                PIFKey_Target_dependencies: dependencies.map{ ["guid": $0.targetId, "platformFilters": $0.platformFilters.map{ $0.serialize(to: serializer) }] },
                PIFKey_Target_productTypeIdentifier: productType.asString,
                PIFKey_Target_productReference: [
                    PIFKey_type: "file",
                    PIFKey_guid: "PRODUCTREF-\(id)",
                    PIFKey_name: productName,
                ],
                PIFKey_Target_buildRules: buildRules.map{ $0.serialize(to: serializer) },
                PIFKey_Target_buildPhases: buildPhases.map{ ($0 as! (any PIFRepresentable)).serialize(to: serializer) },
                PIFKey_Target_customTasks: customTasks.map { $0.serialize(to: serializer) },
                PIFKey_buildConfigurations: buildConfigs.map{ $0.serialize(to: serializer) },
            ]
            if let dynamicTargetVariant {
                result[PIFKey_Target_dynamicTargetVariantGuid] = dynamicTargetVariant.id
            }
            result[PIFKey_Target_approvedByUser] = approvedByUser ? "true" : "false"
            return result
        }
    }

    /// Abstract base class for all build phases in a target.
    public class BuildPhase {
        public let id: String
        public var files: [BuildFile]

        public init(id: String) {
            self.id = id
            self.files = []
        }

        private var nextBuildFileId: String {
            return "\(self.id)::\(files.count)"
        }

        /// Adds a new build file that refers to `fileRef`.
        @discardableResult public func addBuildFile(fileRef: FileReference, platformFilters: Set<PlatformFilter> = [], codeSignOnCopy: Bool = false, removeHeadersOnCopy: Bool = false, generatedCodeVisibility: BuildFile.GeneratedCodeVisibility? = nil, resourceRule: BuildFile.ResourceRule? = nil) -> BuildFile {
            let buildFile = BuildFile(id: nextBuildFileId, reference: fileRef, platformFilters: platformFilters, codeSignOnCopy: codeSignOnCopy, removeHeadersOnCopy: removeHeadersOnCopy)
            buildFile.generatedCodeVisibility = generatedCodeVisibility
            buildFile.resourceRule = resourceRule
            files.append(buildFile)
            return buildFile
        }

        @_disfavoredOverload @discardableResult public func addBuildFile(fileRef: FileReference, platformFilters: Set<PlatformFilter> = [], codeSignOnCopy: Bool = false, removeHeadersOnCopy: Bool = false, generatedCodeVisibility: BuildFile.GeneratedCodeVisibility? = nil) -> BuildFile {
            return addBuildFile(fileRef: fileRef, platformFilters: platformFilters, codeSignOnCopy: codeSignOnCopy, removeHeadersOnCopy: removeHeadersOnCopy, generatedCodeVisibility: generatedCodeVisibility, resourceRule: nil)
        }

        @_disfavoredOverload @discardableResult public func addBuildFile(fileRef: FileReference, platformFilters: Set<PlatformFilter>) -> BuildFile {
            return addBuildFile(fileRef: fileRef, platformFilters: platformFilters, codeSignOnCopy: false)
        }

        @_disfavoredOverload @discardableResult public func addBuildFile(fileRef: FileReference) -> BuildFile {
            return addBuildFile(fileRef: fileRef, platformFilters: [])
        }

        /// Adds a new build file that refers to the product of the target with ID `targetId`.
        @discardableResult public func addBuildFile(productOf targetId: String, platformFilters: Set<PlatformFilter> = [], codeSignOnCopy: Bool = false) -> BuildFile {
            let buildFile = BuildFile(id: nextBuildFileId, targetId: targetId, platformFilters: platformFilters, codeSignOnCopy: codeSignOnCopy)
            files.append(buildFile)
            return buildFile
        }

        @_disfavoredOverload @discardableResult public func addBuildFile(productOf targetId: String, platformFilters: Set<PlatformFilter>) -> BuildFile {
            return addBuildFile(productOf: targetId, platformFilters: platformFilters, codeSignOnCopy: false)
        }

        @_disfavoredOverload @discardableResult public func addBuildFile(productOf targetId: String) -> BuildFile {
            return addBuildFile(productOf: targetId, platformFilters: [])
        }
    }

    /// A "headers" build phase, i.e. one that copies headers into a directory of the product, after suitable processing.
    public class HeadersBuildPhase : BuildPhase {
        public override init(id: String) {
            super.init(id: id)
        }
    }

    /// A "sources" build phase, i.e. one that compiles sources and provides them to be linked into the executable code of the product.
    public class SourcesBuildPhase : BuildPhase {
        public override init(id: String) {
            super.init(id: id)
        }
    }

    /// A "frameworks" build phase, i.e. one that links compiled code and libraries into the executable of the product.
    public class FrameworksBuildPhase : BuildPhase {
        public override init(id: String) {
            super.init(id: id)
        }
    }

    /// A "copy files" build phase, i.e. one that copies files to an arbitrary location relative to the product.
    public class CopyFilesBuildPhase : BuildPhase {
        public let destinationSubfolder: DestinationSubfolder
        public let destinationSubpath: String
        public let runOnlyForDeploymentPostprocessing: Bool

        public init(id: String, destinationSubfolder: DestinationSubfolder, destinationSubpath: String = "", runOnlyForDeploymentPostprocessing: Bool = false) {
            self.destinationSubfolder = destinationSubfolder
            self.destinationSubpath = destinationSubpath
            self.runOnlyForDeploymentPostprocessing = runOnlyForDeploymentPostprocessing

            super.init(id: id)
        }

        public enum DestinationSubfolder: Sendable {
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
        }
    }

    /// A "shell script" build phase, i.e. one that runs a custom shell script.
    public class ShellScriptBuildPhase : BuildPhase {
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

        public init(id: String, name: String, shellPath: String, scriptContents: String, inputPaths: [String], outputPaths: [String], emitEnvironment: Bool, alwaysOutOfDate: Bool, runOnlyForDeploymentPostprocessing: Bool, originalObjectID: String, sandboxingOverride: SandboxingOverride, alwaysRunForInstallHdrs: Bool) {
            self.name = name
            self.shellPath = shellPath
            self.scriptContents = scriptContents
            self.inputPaths = inputPaths
            self.outputPaths = outputPaths
            self.emitEnvironment = emitEnvironment
            self.alwaysOutOfDate = alwaysOutOfDate
            self.runOnlyForDeploymentPostprocessing = runOnlyForDeploymentPostprocessing
            self.originalObjectID = originalObjectID
            self.sandboxingOverride = sandboxingOverride
            self.alwaysRunForInstallHdrs = false
            super.init(id: id)
        }

        convenience public init(id: String, name: String, shellPath: String, scriptContents: String, inputPaths: [String], outputPaths: [String], emitEnvironment: Bool, alwaysOutOfDate: Bool, runOnlyForDeploymentPostprocessing: Bool, originalObjectID: String, sandboxingOverride: SandboxingOverride) {
            self.init(id: id, name: name, shellPath: shellPath, scriptContents: scriptContents, inputPaths: inputPaths, outputPaths: outputPaths, emitEnvironment: emitEnvironment, alwaysOutOfDate: alwaysOutOfDate, runOnlyForDeploymentPostprocessing: runOnlyForDeploymentPostprocessing, originalObjectID: originalObjectID, sandboxingOverride: sandboxingOverride, alwaysRunForInstallHdrs: false)
        }

        convenience public init(id: String, name: String, shellPath: String, scriptContents: String, inputPaths: [String], outputPaths: [String], emitEnvironment: Bool, alwaysOutOfDate: Bool, runOnlyForDeploymentPostprocessing: Bool, originalObjectID: String) {
            self.init(id: id, name: name, shellPath: shellPath, scriptContents: scriptContents, inputPaths: inputPaths, outputPaths: outputPaths, emitEnvironment: emitEnvironment, alwaysOutOfDate: alwaysOutOfDate, runOnlyForDeploymentPostprocessing: runOnlyForDeploymentPostprocessing, originalObjectID: originalObjectID, sandboxingOverride: .basedOnBuildSetting)
        }
    }

    public enum SandboxingOverride: Sendable {
        case forceDisabled
        case forceEnabled
        case basedOnBuildSetting

        public var valueForPIF: String {
            switch self {
            case .forceDisabled: return "forceDisabled"
            case .forceEnabled: return "forceEnabled"
            case .basedOnBuildSetting: return "basedOnBuildSetting"
            }
        }
    }

    public class CopyBundleResourcesBuildPhase : BuildPhase {
        public override init(id: String) {
            super.init(id: id)
        }
    }

    public struct PlatformFilter: Hashable, Sendable {
        public var platform: String
        public var environment: String

        public init(platform: String, environment: String = "") {
            self.platform = platform
            self.environment = environment
        }
    }

    public class BuildRule {
        public let id: String
        public var name: String
        public var input: Input
        public var action: Action

        public enum Input: Sendable {
            case fileType(_ identifier: String)
            case filePattern(_ pattern: String)
        }

        public enum Action: Sendable {
            case compiler(_ identifier: String)
            case shellScriptWithFileList(_ contents: String, inputPaths: [String], inputFileListPaths: [String], outputPaths: [String], outputFileListPaths: [String], outputFilesCompilerFlags: [String]?, dependencyInfo: DependencyInfoFormat?, runOncePerArchitecture: Bool)

            public enum DependencyInfoFormat: Sendable {
                case dependencyInfo(String)
                case makefile(String)
                case makefiles([String])
            }
        }

        public init(id: String, name: String, input: Input, action: Action) {
            self.id = id
            self.name = name
            self.input = input
            self.action = action
        }
    }

    public final class CustomTask: Sendable {
        public let commandLine: [String]
        public let environment: [(String, String)]
        public let workingDirectory: String?
        public let executionDescription: String
        public let inputFilePaths: [String]
        public let outputFilePaths: [String]
        public let enableSandboxing: Bool
        public let preparesForIndexing: Bool

        public init(commandLine: [String], environment: [(String, String)], workingDirectory: String?, executionDescription: String, inputFilePaths: [String], outputFilePaths: [String], enableSandboxing: Bool, preparesForIndexing: Bool) {
            self.commandLine = commandLine
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.executionDescription = executionDescription
            self.inputFilePaths = inputFilePaths
            self.outputFilePaths = outputFilePaths
            self.enableSandboxing = enableSandboxing
            self.preparesForIndexing = preparesForIndexing
        }
    }

    /// A build file, representing the membership of either a file or target product reference in a build phase.
    public class BuildFile {
        public let id: String
        public let ref: Ref
        public enum Ref: Sendable {
            case reference(id: String)
            case targetProduct(id: String)
        }
        public var headerVisibility: HeaderVisibility? = nil
        public enum HeaderVisibility: String, Sendable {
            case `public` = "public"
            case `private` = "private"
        }

        public var generatedCodeVisibility: GeneratedCodeVisibility? = nil
        public enum GeneratedCodeVisibility: Sendable {
            case `public`
            case `private`
            case project
            case noCodegen
        }

        public var platformFilters: Set<PlatformFilter> = []

        public let codeSignOnCopy: Bool

        public let removeHeadersOnCopy: Bool

        public var resourceRule: ResourceRule?
        public enum ResourceRule: String, Sendable {
            case process
            case copy
            case embedInCode
        }

        public init(id: String, reference: FileReference, platformFilters: Set<PlatformFilter> = [], codeSignOnCopy: Bool = false, removeHeadersOnCopy: Bool = false) {
            self.id = id
            self.ref = .reference(id: reference.id)
            self.platformFilters = platformFilters
            self.codeSignOnCopy = codeSignOnCopy
            self.removeHeadersOnCopy = removeHeadersOnCopy
        }
        @_disfavoredOverload public convenience init(id: String, reference: FileReference, platformFilters: Set<PlatformFilter>) {
            self.init(id: id, reference: reference, platformFilters: platformFilters, codeSignOnCopy: false)
        }
        @_disfavoredOverload public convenience init(id: String, reference: FileReference) {
            self.init(id: id, reference: reference, platformFilters: [], codeSignOnCopy: false)
        }
        public init(id: String, targetId: String, platformFilters: Set<PlatformFilter> = [], codeSignOnCopy: Bool = false, removeHeadersOnCopy: Bool = false) {
            self.id = id
            self.ref = .targetProduct(id: targetId)
            self.platformFilters = platformFilters
            self.codeSignOnCopy = codeSignOnCopy
            self.removeHeadersOnCopy = removeHeadersOnCopy
        }
        @_disfavoredOverload public convenience init(id: String, targetId: String, platformFilters: Set<PlatformFilter>) {
            self.init(id: id, targetId: targetId, platformFilters: platformFilters, codeSignOnCopy: false)
        }
        @_disfavoredOverload public convenience init(id: String, targetId: String) {
            self.init(id: id, targetId: targetId, platformFilters: [], codeSignOnCopy: false)
        }
    }

    /// A build configuration, which is a named collection of build settings.
    public class BuildConfig {
        public let id: String
        public let name: String
        public let settings: BuildSettings
        public let impartedBuildProperties: ImpartedBuildProperties

        public init(id: String, name: String, settings: BuildSettings, impartedBuildSettings: BuildSettings) {
            precondition(!name.isEmpty)
            self.id = id
            self.name = name
            self.settings = settings
            self.impartedBuildProperties = ImpartedBuildProperties(settings: impartedBuildSettings)
        }

        public convenience init(id: String, name: String, settings: BuildSettings) {
            self.init(id: id, name: name, settings: settings, impartedBuildSettings: BuildSettings())
        }
    }

    public class ImpartedBuildProperties {
        public let settings: BuildSettings

        public init(settings: BuildSettings) {
            self.settings = settings
        }
    }

    /// A set of build settings, which is represented as a struct of optional build settings.  This is not optimally efficient, but it is great for code completion and type-checking.
    public struct BuildSettings: Sendable {
        public enum Declaration: String, CaseIterable, Sendable {
            case ARCHS
            case GCC_PREPROCESSOR_DEFINITIONS
            case FRAMEWORK_SEARCH_PATHS
            case HEADER_SEARCH_PATHS
            case IPHONEOS_DEPLOYMENT_TARGET
            case OTHER_CFLAGS
            case OTHER_CPLUSPLUSFLAGS
            case OTHER_LDFLAGS
            case OTHER_SWIFT_FLAGS
            case SPECIALIZATION_SDK_OPTIONS
            case SWIFT_VERSION
            case SWIFT_ACTIVE_COMPILATION_CONDITIONS
        }

        public enum Platform: CaseIterable, Sendable {
            case macOS
            case macCatalyst
            case iOS

            // Special case to support arm64e-only iOS app builds with SwiftPM dependencies. Don't use it for anything else!
            case _iOSDevice

            case tvOS
            case watchOS
            case xrOS

            case _iOS

            case driverKit

            case linux
            case android
            case windows
            case wasi
            case openbsd

            public var asConditionStrings: [String] {
                let filters = [self].toPlatformFilter().map { (filter: PIF.PlatformFilter) -> String in
                    if filter.environment.isEmpty {
                        return filter.platform
                    } else {
                        return "\(filter.platform)-\(filter.environment)"
                    }
                }.sorted()
                return ["__platform_filter=\(filters.joined(separator: ";"))"]
            }
        }

        public var platformSpecificSettings = [Platform: [Declaration: [String]]]()

        public init() {
            for platform in Platform.allCases {
                platformSpecificSettings[platform] = [Declaration: [String]]()
                for declaration in Declaration.allCases {
                    platformSpecificSettings[platform]![declaration] = ["$(inherited)"]
                }
            }
        }

        // Note: although some of these build settings sound like booleans, they are all either strings or arrays of strings, because even a boolean may be a macro reference expression.
        public var APPLICATION_EXTENSION_API_ONLY: String?
        public var APP_PLAYGROUND_GENERATE_ASSET_CATALOG: String?
        public var APP_PLAYGROUND_GENERATED_ASSET_CATALOG_APPICON_NAME: String?
        public var APP_PLAYGROUND_GENERATED_ASSET_CATALOG_GLOBAL_ACCENT_COLOR_NAME: String?
        public var APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PLACEHOLDER_APPICON: String?
        public var APP_PLAYGROUND_GENERATED_ASSET_CATALOG_PRESET_ACCENT_COLOR: String?
        public var ASSETCATALOG_COMPILER_APPICON_NAME: String?
        public var ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: String?
        public var BUILD_LIBRARY_FOR_DISTRIBUTION: String?
        public var BUILD_PACKAGE_FOR_DISTRIBUTION: String?
        public var BUILT_PRODUCTS_DIR: String?
        public var CLANG_CXX_LANGUAGE_STANDARD: String?
        public var CLANG_ENABLE_MODULES: String?
        public var CLANG_ENABLE_OBJC_ARC: String?
        public var CODE_SIGNING_REQUIRED: String?
        public var CODE_SIGN_ENTITLEMENTS: String?
        public var CODE_SIGN_ENTITLEMENTS_CONTENTS: String?
        public var CODE_SIGN_IDENTITY: String?
        public var CODE_SIGN_INJECT_BASE_ENTITLEMENTS: String?
        public var COMBINE_HIDPI_IMAGES: String?
        public var COMPILER_WORKING_DIRECTORY: String?
        public var MERGEABLE_LIBRARY: String?
        public var COPY_PHASE_STRIP: String?
        public var COREML_CODEGEN_LANGUAGE: String?
        public var COREML_CODEGEN_SWIFT_VERSION: String?
        public var COREML_COMPILER_CONTAINER: String?
        public var DEBUG_INFORMATION_FORMAT: String?
        public var DEFINES_MODULE: String?
        public var DEVELOPMENT_TEAM: String?
        public var DRIVERKIT_DEPLOYMENT_TARGET: String?
        public var XROS_DEPLOYMENT_TARGET: String?
        public var _IOS_DEPLOYMENT_TARGET: String?
        public var DYLIB_INSTALL_NAME_BASE: String?
        public var EMBEDDED_CONTENT_CONTAINS_SWIFT: String?
        public var ENABLE_APP_SANDBOX: String?
        public var ENABLE_HARDENED_RUNTIME: String?
        public var ENABLE_NS_ASSERTIONS: String?
        public var ENABLE_PLAYGROUND_RESULTS: String?
        public var ENABLE_TESTABILITY: String?
        public var ENABLE_TESTING_SEARCH_PATHS: String?
        public var ENTITLEMENTS_REQUIRED: String?
        public var EMBED_PACKAGE_RESOURCE_BUNDLE_NAMES: [String]?
        public var EXECUTABLE_NAME: String?
        public var FRAMEWORK_SEARCH_PATHS: [String]?
        public var GENERATE_INFOPLIST_FILE: String?
        public var GCC_C_LANGUAGE_STANDARD: String?
        public var GCC_OPTIMIZATION_LEVEL: String?
        public var GCC_PREPROCESSOR_DEFINITIONS: [String]?
        public var GENERATE_EMBED_IN_CODE_ACCESSORS: String?
        public var GENERATE_MASTER_OBJECT_FILE: String?
        public var GENERATE_RESOURCE_ACCESSORS: String?
        public var HEADER_SEARCH_PATHS: [String]?
        public var INFOPLIST_FILE: String?
        public var INFOPLIST_FILE_CONTENTS: String?
        public var INFOPLIST_KEY_LSApplicationCategoryType: String?
        public var INFOPLIST_KEY_UIApplicationSceneManifest_Generation: String?
        public var INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad: [String]?
        public var INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: [String]?
        public var INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents: String?
        public var INFOPLIST_KEY_UILaunchScreen_Generation: String?
        public var INSTALLAPI_COPY_PHASE: String?
        public var INSTALLHDRS_COPY_PHASE: String?
        public var IPHONEOS_DEPLOYMENT_TARGET: String?
        public var IS_ZIPPERED: String?
        public var KEEP_PRIVATE_EXTERNS: String?
        public var LD_RUNPATH_SEARCH_PATHS: [String]?
        public var LD_WARN_DUPLICATE_LIBRARIES: String?
        public var LIBRARY_SEARCH_PATHS: [String]?
        public var LINKER_DRIVER: String?
        public var CLANG_COVERAGE_MAPPING_LINKER_ARGS: String?
        public var CURRENT_PROJECT_VERSION: String?
        public var MACH_O_TYPE: String?
        public var MACOSX_DEPLOYMENT_TARGET: String?
        public var MARKETING_VERSION: String?
        public var MERGE_LINKED_LIBRARIES: String?
        public var MODULEMAP_FILE_CONTENTS: String?
        public var MODULEMAP_PATH: String?
        public var MODULEMAP_FILE: String?
        public var ONLY_ACTIVE_ARCH: String?
        public var OTHER_CFLAGS: [String]?
        public var OTHER_CPLUSPLUSFLAGS: [String]?
        public var OTHER_LDFLAGS: [String]?
        public var OTHER_LDRFLAGS: [String]?
        public var OTHER_SWIFT_FLAGS: [String]?
        public var PACKAGE_RESOURCE_BUNDLE_NAME: String?
        public var PACKAGE_RESOURCE_TARGET_KIND: String?
        public var PACKAGE_REGISTRY_SIGNATURE: String?
        public var PACKAGE_TARGET_NAME_CONFLICTS_WITH_PRODUCT_NAME: String?
        public var PRELINK_FLAGS: [String]?
        public var PRODUCT_BUNDLE_IDENTIFIER: String?
        public var PRODUCT_MODULE_NAME: String?
        public var PRODUCT_NAME: String?
        public var PROJECT_NAME: String?
        public var SDKROOT: String?
        public var SDK_VARIANT: String?
        public var SKIP_INSTALL: String?
        public var SKIP_BUILDING_DOCUMENTATION: String?
        public var SKIP_CLANG_STATIC_ANALYZER: String?
        public var STRIP_INSTALLED_PRODUCT: String?
        public var INSTALL_PATH: String?
        public var SUPPORTED_PLATFORMS: [String]?
        public var SUPPORTS_MACCATALYST: String?
        public var SUPPORTS_TEXT_BASED_API: String?
        public var SUPPRESS_WARNINGS: String?
        public var SWIFT_ACTIVE_COMPILATION_CONDITIONS: [String]?
        public var SWIFT_ADD_TOOLCHAIN_SWIFTSYNTAX_SEARCH_PATHS: String?
        public var SWIFT_FORCE_STATIC_LINK_STDLIB: String?
        public var SWIFT_FORCE_DYNAMIC_LINK_STDLIB: String?
        public var SWIFT_INSTALL_OBJC_HEADER: String?
        public var SWIFT_LOAD_BINARY_MACROS: [String]?
        public var SWIFT_MODULE_ALIASES: [String]?
        public var SWIFT_WARNINGS_AS_WARNINGS_GROUPS: [String]?
        public var SWIFT_WARNINGS_AS_ERRORS_GROUPS: [String]?
        public var SWIFT_OBJC_INTERFACE_HEADER_NAME: String?
        public var SWIFT_OBJC_INTERFACE_HEADER_DIR: String?
        public var SWIFT_OPTIMIZATION_LEVEL: String?
        public var SWIFT_IMPLEMENTS_MACROS_FOR_MODULE_NAMES: [String]?
        public var SWIFT_INSTALL_MODULE: String?
        public var SWIFT_PACKAGE_NAME: String?
        public var SWIFT_VERSION: String?
        public var SWIFT_ENABLE_BARE_SLASH_REGEX: String?
        public var SWIFT_USER_MODULE_VERSION: String?
        public var TAPI_DYLIB_INSTALL_NAME: String?
        public var TARGET_BUILD_SUBPATH: String?
        public var TARGET_NAME: String?
        public var TARGET_BUILD_DIR: String?
        public var TARGETED_DEVICE_FAMILY: String?
        public var TVOS_DEPLOYMENT_TARGET: String?
        public var USE_HEADERMAP: String?
        public var USES_SWIFTPM_UNSAFE_FLAGS: String?
        public var WATCHOS_DEPLOYMENT_TARGET: String?
    }
}

public extension Array where Element == PIF.BuildSettings.Platform {
    func toPlatformFilter() -> Set<PIF.PlatformFilter> {
        var result: [PIF.PlatformFilter] = []
        for platform in self {
            switch platform {
            case .macOS:
                result.append(.init(platform: "macos"))

            case .macCatalyst:
                result.append(.init(platform: "ios", environment: "maccatalyst"))

            case .iOS:
                result.append(.init(platform: "ios"))
                result.append(.init(platform: "ios", environment: "simulator"))

            case ._iOSDevice:
                result.append(.init(platform: "ios"))

            case .tvOS:
                result.append(.init(platform: "tvos"))
                result.append(.init(platform: "tvos", environment: "simulator"))

            case .watchOS:
                result.append(.init(platform: "watchos"))
                result.append(.init(platform: "watchos", environment: "simulator"))

            case .xrOS:
                result.append(.init(platform: "xros"))
                result.append(.init(platform: "xros", environment: "simulator"))

            case ._iOS:
                result.append(.init(platform: "xros"))
                result.append(.init(platform: "xros", environment: "simulator"))

            case .driverKit:
                result.append(.init(platform: "driverkit"))

            case .linux:
                result.append(.init(platform: "linux", environment: "gnu"))

            case .android:
                result.append(.init(platform: "linux", environment: "android"))
                result.append(.init(platform: "linux", environment: "androideabi"))

            case .windows:
                result.append(.init(platform: "windows", environment: "msvc"))

            case .wasi:
                result.append(.init(platform: "wasi"))

            case .openbsd:
                result.append(.init(platform: "openbsd"))
            }
        }
        return Set(result)
    }
}

/// Represents a filetype recognized by the Xcode build system.
public struct SwiftBuildFileType: Sendable {
    public var fileTypes: Set<String>
    public var fileTypeIdentifier: String

    public init(fileTypes: Set<String>, fileTypeIdentifier: String) {
        self.fileTypes = fileTypes
        self.fileTypeIdentifier = fileTypeIdentifier
    }

    public init(fileType: String, fileTypeIdentifier: String) {
        self.init(fileTypes: [fileType], fileTypeIdentifier: fileTypeIdentifier)
    }

    public static let xcassets: SwiftBuildFileType = SwiftBuildFileType(
        fileType: "xcassets",
        fileTypeIdentifier: "folder.abstractassetcatalog"
    )

    public static let xcdatamodeld: SwiftBuildFileType = SwiftBuildFileType(
        fileType: "xcdatamodeld",
        fileTypeIdentifier: "wrapper.xcdatamodeld"
    )

    public static let xcdatamodel: SwiftBuildFileType = SwiftBuildFileType(
        fileType: "xcdatamodel",
        fileTypeIdentifier: "wrapper.xcdatamodel"
    )

    public static let xcmappingmodel: SwiftBuildFileType = SwiftBuildFileType(
        fileType: "xcmappingmodel",
        fileTypeIdentifier: "wrapper.xcmappingmodel"
    )

    public static let mlmodel: SwiftBuildFileType = SwiftBuildFileType(
        fileType: "mlmodel",
        fileTypeIdentifier: "file.mlmodel"
    )

    public static let mlpackage: SwiftBuildFileType = SwiftBuildFileType(
        fileType: "mlpackage",
        fileTypeIdentifier: "folder.mlpackage"
    )

    public static let metal: SwiftBuildFileType = SwiftBuildFileType(
        fileType: "metal",
        fileTypeIdentifier: "sourcecode.metal"
    )

    public static let referenceobject: SwiftBuildFileType = SwiftBuildFileType(
        fileType: "referenceobject",
        fileTypeIdentifier: "file.referenceobject"
    )

    public static let all: [SwiftBuildFileType] = [
        .xcassets,
        .xcdatamodeld,
        .xcdatamodel,
        .xcmappingmodel,
        .mlmodel,
        .mlpackage,
        .metal,
        .referenceobject,
    ]
}
