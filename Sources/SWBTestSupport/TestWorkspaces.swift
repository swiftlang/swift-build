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

import class Foundation.Bundle
import class Foundation.ProcessInfo

package import SWBCore
package import SWBProtocol
package import SWBUtil
package import Testing
package import SWBMacro

private protocol Resolver {
    /// The name of the containing workspace
    var workspaceName: String { get }

    /// The `sourceRoot` path.
    var sourceRoot: Path { get }

    /// Find a file reference with the given name, or target reference corresponding to a product with the given name.
    func findAuto(_ name: String) throws -> TestBuildableItem

    /// Find a file reference GUID with the given name.
    func findFile(_ name: String) throws -> String

    /// Find a target with the given name.  Returns `nil` if no target of that name can be found.
    func findTarget(_ name: String) -> (any TestInternalTarget)?

    /// Find the project for the given target.
    func findProject(for target: any TestInternalTarget) throws -> TestProject
}

private enum TestBuildableItem {
    case reference(guid: String)
    case targetProduct(guid: String)
}

package protocol TestItem: AnyObject {}

private protocol TestInternalItem: TestItem {
    static var guidCode: String { get }
    var guidIdentifier: String { get }
    var guid: String { get }
}
extension TestInternalItem {
    var guid: String {
        return "\(Self.guidCode)\(guidIdentifier)"
    }
}

private let _nextGuidIdentifier = LockedValue(1)
private func nextGuidIdentifier() -> String {
    return _nextGuidIdentifier.withLock { value in
        defer { value += 1 }
        return String(value)
    }
}

/// A top-level object.
private protocol TestInternalObjectItem: TestInternalItem {
    /// The object signature.
    var signature: String { get }

    /// Convert the item into its standalone PIF object.
    func toObject(_ resolver: any Resolver) throws -> PropertyListItem
}


package protocol TestStructureItem { }
private protocol TestInternalStructureItem: TestInternalItem, TestStructureItem, Sendable {
    func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.GroupTreeReference
}

// Support .toProtocol() on individual items, using a mock resolver.
private struct MockResolver: Resolver {
    var workspaceName: String {
        fatalError("unexpected request for \(#function)")
    }
    var sourceRoot: Path {
        fatalError("unexpected request for \(#function)")
    }
    func findAuto(_ name: String) -> TestBuildableItem {
        fatalError("unexpected request for \(#function)")
    }
    func findFile(_ name: String) -> String {
        fatalError("unexpected request for \(#function)")
    }
    func findTarget(_ name: String) -> (any TestInternalTarget)? {
        fatalError("unexpected request for \(#function)")
    }
    func findProject(for target: any TestInternalTarget) throws -> TestProject {
        fatalError("unexpected request for \(#function)")
    }
}
extension TestStructureItem {
    package func toProtocol() throws -> SWBProtocol.Reference {
        return try (self as! (any TestInternalStructureItem)).toProtocol(MockResolver())
    }
}
extension TestTarget {
    package func toProtocol() throws -> SWBProtocol.Target {
        return try (self as! (any TestInternalTarget)).toProtocol(MockResolver())
    }
}

package enum TestSourceTree: Equatable, Sendable {
    case absolute
    case groupRelative
    case buildSetting(String) // FIXME: This should be a MacroExpressionSource.
}

extension TestSourceTree {
    fileprivate func toProtocol() -> SWBProtocol.SourceTree {
        switch self {
        case .absolute: return .absolute
        case .groupRelative: return .groupRelative
        case .buildSetting(let value): return .buildSetting(value)
        }
    }
}

package final class TestFile: TestInternalStructureItem, CustomStringConvertible {
    static let guidCode = "FR"
    package let name: String
    private let _guid: String?
    private let path: String?
    private let projectDirectory: String?
    private let fileTypeId: String?
    private let regionVariantName: String?
    private let fileTextEncoding: FileTextEncoding?
    private let sourceTree: TestSourceTree
    private let expectedSignature: String?

    /// We use stable GUIDs for file references, since they are referenced indirectly.
    ///
    /// Test projects are expected to not have collisions in these.
    package var guid: String {
        return actualGUID
    }

    var actualGUID: String {
        return _guid ?? (TestFile.guidCode + guidIdentifier)
    }

    var guidIdentifier: String {
        return name + (regionVariantName ?? "")
    }

    package init(_ name: String, guid: String? = nil, path: String? = nil, projectDirectory: String? = nil, fileType: String? = nil, regionVariantName: String? = nil, fileTextEncoding: FileTextEncoding? = nil, sourceTree: TestSourceTree = .groupRelative, expectedSignature: String? = nil) {
        self.name = name
        self._guid = guid
        self.path = path
        self.projectDirectory = projectDirectory
        self.fileTypeId = fileType
        self.regionVariantName = regionVariantName
        self.fileTextEncoding = fileTextEncoding
        self.sourceTree = sourceTree
        self.expectedSignature = expectedSignature
    }

    private var fileType: String {
        // FIXME: This should be able to just use some method on the actual FileType specs?
        guard fileTypeId == nil else { return fileTypeId! }
        switch Path(path ?? name).fileSuffix {
        case ".a":
            return "archive.ar"
        case ".app":
            return "wrapper.application"
        case ".appex":
            return "wrapper.app-extension"
        case ".applescript":
            return "sourcecode.applescript"
        case ".atlas":
            return "folder.skatlas"
        case ".bundle":
            return "wrapper.cfbundle"
        case ".s":
            return "sourcecode.asm"
        case ".c":
            return "sourcecode.c.c"
        case ".cl":
            return "sourcecode.opencl"
        case ".cpp":
            return "sourcecode.cpp.cpp"
        case ".d":
            return "sourcecode.dtrace"
        case ".dae", ".DAE":
            return "text.xml.dae"
        case ".dat":
            return "file"
        case ".defs":
            return "sourcecode.mig"
        case ".dylib":
            return "compiled.mach-o.dylib"
        case ".entitlements":
            return "text.plist.entitlements"
        case ".exp":
            return "sourcecode.exports"
        case ".hpp", ".hp", ".hh", ".hxx", ".h++", ".ipp", ".pch++":
            return "sourcecode.cpp.h"
        case ".iconset":
            return "folder.iconset"
        case ".iig":
            return "sourcecode.iig"
        case ".instrpkg":
            return "com.apple.instruments.package-definition"
        case ".intentdefinition":
            return "file.intentdefinition"
        case ".intents":
            return "wrapper.intents"
        case ".js":
            return "sourcecode.javascript"
        case ".jpg", ".jpeg":
            return "image.jpeg"
        case ".m":
            return "sourcecode.c.objc"
        case ".mm":
            return "sourcecode.cpp.objcpp"
        case ".metal":
            return "sourcecode.metal"
        case ".pch", ".h", ".H":
            return "sourcecode.c.h"
        case ".framework":
            return "wrapper.framework"
        case ".l":
            return "sourcecode.lex"
        case ".mlmodel":
            return "file.mlmodel"
        case ".mlpackage":
            return "folder.mlpackage"
        case ".map", ".modulemap":
            return "sourcecode.module-map"
        case ".nib":
            return "file.nib"
        case ".o":
            return "compiled.mach-o.objfile"
        case ".plist":
            return "text.plist"
        case ".vocabulary":
            return "text.plist.vocabulary"
        case ".plugindata":
            return "com.apple.xcode.plugindata"
        case ".png":
            return "image.png"
        case ".xcprivacy":
            return "text.plist.app-privacy"
        case ".r":
            return "sourcecode.rez"
        case ".referenceobject":
            return "file.referenceobject"
        case ".rkassets":
            return "folder.rkassets"
        case ".scnassets":
            return "wrapper.scnassets"
        case ".scncache":
            return "wrapper.scncache"
        case ".storyboard":
            return "file.storyboard"
        case ".strings":
            return "text.plist.strings"
        case ".stringsdict":
            return "text.plist.stringsdict"
        case ".xcstrings":
            return "text.json.xcstrings"
        case ".swift":
            return "sourcecode.swift"
        case ".tbd":
            return "sourcecode.text-based-dylib-definition"
        case ".tif", ".tiff":
            return "image.tiff"
        case ".txt":
            return "text"
        case ".uicatalog":
            return "file.uicatalog"
        case ".xcassets":
            return "folder.assetcatalog"
        case ".xcdatamodeld":
            return "wrapper.xcdatamodel"
        case ".xcfilelist":
            return "text"
        case ".xcmappingmodel":
            return "wrapper.xcmappingmodel"
        case ".xcstickers":
            return "folder.stickers"
        case ".xcconfig":
            return "text.xcconfig"
        case ".xcdatamodel":
            return "wrapper.xcdatamodel"
        case ".xcappextensionpoints":
            return "text.plist.xcappextensionpoints"
        case ".xcframework":
            return "wrapper.xcframework"
        case ".xcspec":
            return "text.plist.xcspec"
        case ".xib":
            return "file.xib"
        case ".xpc":
            return "wrapper.xpc-service"
        case ".y":
            return "sourcecode.yacc"
        case ".ym":
            return "sourcecode.yacc"
        case ".docc":
            return "folder.documentationcatalog"
        case ".tightbeam":
            return "sourcecode.tightbeam"
        case let ext where ext.hasPrefix(".fake-"):
            // If this is a fake extension, just return "file".
            return "file"
        case let ext:
            fatalError("unknown extension: \(ext)")
        }
    }

    fileprivate func toProtocol(_ resolver: any Resolver) -> SWBProtocol.GroupTreeReference {
        return SWBProtocol.FileReference(guid: actualGUID, sourceTree: sourceTree.toProtocol(), path: .string(path ?? name), fileTypeIdentifier: fileType, regionVariantName: regionVariantName, fileTextEncoding: fileTextEncoding, expectedSignature: self.expectedSignature)
    }

    package var description: String {
        return "<TestFile: \(path ?? name)>"
    }
}

package final class TestGroup: TestInternalItem, TestInternalStructureItem, CustomStringConvertible, Sendable {
    static let guidCode = "G"
    let guidIdentifier = nextGuidIdentifier()
    fileprivate let name: String
    fileprivate let path: String?
    private let sourceTree: TestSourceTree?
    fileprivate let children: [any TestInternalStructureItem]

    private let overriddenGuid: String?

    package var guid: String {
        return overriddenGuid ?? "\(TestGroup.guidCode)\(guidIdentifier)"
    }

    package init(_ name: String, guid: String? = nil, path: String? = nil, sourceTree: TestSourceTree? = nil, children: [any TestStructureItem] = []) {
        self.name = name
        self.overriddenGuid = guid
        self.path = path
        self.sourceTree = sourceTree
        self.children = children.map { $0 as! (any TestInternalStructureItem) }
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.GroupTreeReference {
        return try toProtocol(resolver, isRoot: false)
    }

    fileprivate func toProtocol(_ resolver: any Resolver, isRoot: Bool) throws -> SWBProtocol.FileGroup {
        let sourceTree = self.sourceTree ?? (isRoot ? .buildSetting("PROJECT_DIR") : .groupRelative)
        return try SWBProtocol.FileGroup(guid: guid, sourceTree: sourceTree.toProtocol(), path: .string(path ?? (sourceTree == .buildSetting("PROJECT_DIR") ? "" : name)), name: name, children: children.map{ try $0.toProtocol(resolver) })
    }

    package var description: String {
        return "<TestGroup: \(path ?? name)>"
    }
}

package final class TestVariantGroup: TestInternalItem, TestInternalStructureItem, CustomStringConvertible {
    static let guidCode = "VG"
    let guidIdentifier = nextGuidIdentifier()
    fileprivate let name: String
    fileprivate let children: [any TestInternalStructureItem]

    package init(_ name: String, children: [any TestStructureItem] = []) {
        self.name = name
        self.children = children.map { $0 as! (any TestInternalStructureItem) }
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.GroupTreeReference {
        return try SWBProtocol.VariantGroup(guid: guid, sourceTree: .groupRelative, path: .string(""), name: name, children: children.map{ try $0.toProtocol(resolver) })
    }

    package var description: String {
        return "<TestVariantGroup: \(name)>"
    }
}

package final class TestVersionGroup: TestInternalItem, TestInternalStructureItem, CustomStringConvertible {
    static let guidCode = "VersG"
    let guidIdentifier = nextGuidIdentifier()
    fileprivate let name: String
    fileprivate let path: String?
    private let sourceTree: TestSourceTree?
    fileprivate let children: [any TestInternalStructureItem]

    package init(_ name: String, path: String? = nil, sourceTree: TestSourceTree? = nil, children: [any TestStructureItem] = []) {
        self.name = name
        self.path = path
        self.sourceTree = sourceTree
        self.children = children.map { $0 as! (any TestInternalStructureItem) }
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.GroupTreeReference {
        let sourceTree = self.sourceTree ?? .groupRelative
        return try SWBProtocol.VersionGroup(guid: guid, sourceTree: .groupRelative, path: .string(path ?? (sourceTree == .buildSetting("PROJECT_DIR") ? "" : name)), children: children.map{ try $0.toProtocol(resolver) })
    }

    package var description: String {
        return "<TestVersionGroup: \(path ?? name)>"
    }
}

package final class TestBuildFile: TestInternalItem, Sendable {
    package enum BuildableItemName: Sendable {
        case auto(String)
        case file(String)
        case target(String)
        case namedReference(name: String, fileTypeIdentifier: String)
    }

    package enum HeaderVisibility: Sendable {
        case `public`
        case `private`
    }

    package enum MigCodegenFiles: String, Sendable {
        case client
        case server
        case both
    }

    package enum ResourceRule: String, Sendable {
        case process
        case copy
        case embedInCode
    }

    static let guidCode = "BF"
    let guidIdentifier = nextGuidIdentifier()
    /// While `BuildFile` does not have a name property, for ease of testing `TestBuildFile` does, and the guid of the file it represents will be looked up using the name.
    let buildableItemName: BuildableItemName
    let file: TestFile?
    let resourceRule: ResourceRule
    let codeSignOnCopy: Bool?
    let removeHeadersOnCopy: Bool?
    let headerVisibility: HeaderVisibility?
    let additionalArgs: [String]?
    let decompress: Bool
    let migCodegenFiles: MigCodegenFiles?
    let shouldLinkWeakly: Bool?
    let assetTags: Set<String>
    let intentsCodegenVisibility: IntentsCodegenVisibility
    let platformFilters: Set<PlatformFilter>
    let shouldWarnIfNoRuleToProcess: Bool

    package init(_ buildableItemName: BuildableItemName, codeSignOnCopy: Bool? = nil, removeHeadersOnCopy: Bool? = nil, headerVisibility: HeaderVisibility? = nil, additionalArgs: [String]? = nil, decompress: Bool = false, migCodegenFiles: MigCodegenFiles? = nil, shouldLinkWeakly: Bool? = nil, assetTags: Set<String> = Set(), intentsCodegenVisibility: IntentsCodegenVisibility = .noCodegen, platformFilters: Set<PlatformFilter> = [], shouldWarnIfNoRuleToProcess: Bool = true, resourceRule: ResourceRule = .process) {
        self.buildableItemName = buildableItemName
        self.file = nil
        self.codeSignOnCopy = codeSignOnCopy
        self.removeHeadersOnCopy = removeHeadersOnCopy
        self.headerVisibility = headerVisibility
        self.additionalArgs = additionalArgs
        self.decompress = decompress
        self.migCodegenFiles = migCodegenFiles
        self.shouldLinkWeakly = shouldLinkWeakly
        self.assetTags = assetTags
        self.intentsCodegenVisibility = intentsCodegenVisibility
        self.platformFilters = platformFilters
        self.shouldWarnIfNoRuleToProcess = shouldWarnIfNoRuleToProcess
        self.resourceRule = resourceRule
    }

    package convenience init(_ fileName: String, codeSignOnCopy: Bool? = nil, removeHeadersOnCopy: Bool? = nil, headerVisibility: HeaderVisibility? = nil, additionalArgs: [String]? = nil, decompress: Bool = false, migCodegenFiles: MigCodegenFiles? = nil, shouldLinkWeakly: Bool? = nil, assetTags: Set<String> = Set(), intentsCodegenVisibility: IntentsCodegenVisibility = .noCodegen, platformFilters: Set<PlatformFilter> = [], shouldWarnIfNoRuleToProcess: Bool = true) {
        self.init(.auto(fileName), codeSignOnCopy: codeSignOnCopy, removeHeadersOnCopy: removeHeadersOnCopy, headerVisibility: headerVisibility, additionalArgs: additionalArgs, decompress: decompress, migCodegenFiles: migCodegenFiles, shouldLinkWeakly: shouldLinkWeakly, assetTags: assetTags, intentsCodegenVisibility: intentsCodegenVisibility, platformFilters: platformFilters, shouldWarnIfNoRuleToProcess: shouldWarnIfNoRuleToProcess)
    }

    package init(_ file: TestFile, codeSignOnCopy: Bool? = nil, removeHeadersOnCopy: Bool? = nil, headerVisibility: HeaderVisibility? = nil, additionalArgs: [String]? = nil, decompress: Bool = false, migCodegenFiles: MigCodegenFiles? = nil, shouldLinkWeakly: Bool? = nil, assetTags: Set<String> = Set(), intentsCodegenVisibility: IntentsCodegenVisibility = .noCodegen, platformFilters: Set<PlatformFilter> = [], shouldWarnIfNoRuleToProcess: Bool = true, resourceRule: ResourceRule = .process) {
        self.buildableItemName = .auto(file.name)
        self.file = file
        self.codeSignOnCopy = codeSignOnCopy
        self.removeHeadersOnCopy = removeHeadersOnCopy
        self.headerVisibility = headerVisibility
        self.additionalArgs = additionalArgs
        self.decompress = decompress
        self.migCodegenFiles = migCodegenFiles
        self.shouldLinkWeakly = shouldLinkWeakly
        self.assetTags = assetTags
        self.intentsCodegenVisibility = intentsCodegenVisibility
        self.platformFilters = platformFilters
        self.shouldWarnIfNoRuleToProcess = shouldWarnIfNoRuleToProcess
        self.resourceRule = resourceRule
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildFile {
        let buildableItemGUID: SWBProtocol.BuildFile.BuildableItemGUID
        switch buildableItemName {
        case let .auto(name):
            if let guid = self.file?.guid {
                buildableItemGUID = .reference(guid: guid)
            } else {
                switch try resolver.findAuto(name) {
                case let .reference(guid):
                    buildableItemGUID = .reference(guid: guid)
                case let .targetProduct(guid):
                    buildableItemGUID = .targetProduct(guid: guid)
                }
            }
        case let .file(name):
            buildableItemGUID = try .reference(guid: self.file?.guid ?? resolver.findFile(name))
        case let .target(name):
            // Note: falling back to "name" is wrong, as a target's name isn't going to be a valid GUID,
            // but we need a non-nil value here, and it will just fail to resolve more gracefully later on.
            buildableItemGUID = .targetProduct(guid: resolver.findTarget(name)?.guid ?? name)
        case let .namedReference(name, fileTypeIdentifier):
            buildableItemGUID = .namedReference(name: name, fileTypeIdentifier: fileTypeIdentifier)
        }
        return SWBProtocol.BuildFile(guid: guid, buildableItemGUID: buildableItemGUID, additionalArgs: additionalArgs.map{ .stringList($0) }, decompress: decompress, headerVisibility: headerVisibility?.toProtocol(), migCodegenFiles: migCodegenFiles?.toProtocol(), intentsCodegenVisibility: intentsCodegenVisibility, resourceRule: resourceRule.toProtocol(), codeSignOnCopy: codeSignOnCopy ?? false, removeHeadersOnCopy: removeHeadersOnCopy ?? false, shouldLinkWeakly: shouldLinkWeakly ?? false, assetTags: assetTags, platformFilters: platformFilters, shouldWarnIfNoRuleToProcess: shouldWarnIfNoRuleToProcess)
    }
}

extension TestBuildFile.HeaderVisibility {
    fileprivate func toProtocol() -> SWBProtocol.BuildFile.HeaderVisibility {
        switch self {
        case .public: return .public
        case .private: return .private
        }
    }
}

extension TestBuildFile.MigCodegenFiles {
    fileprivate func toProtocol() -> SWBProtocol.BuildFile.MigCodegenFiles {
        switch self {
        case .client: return .client
        case .server: return .server
        case .both: return .both
        }
    }
}

extension TestBuildFile.ResourceRule {
    fileprivate func toProtocol() -> SWBProtocol.BuildFile.ResourceRule {
        switch self {
        case .copy: return .copy
        case .embedInCode: return .embedInCode
        case .process: return .process
        }
    }
}

extension TestBuildFile: ExpressibleByStringLiteral {
    package typealias UnicodeScalarLiteralType = StringLiteralType
    package typealias ExtendedGraphemeClusterLiteralType = StringLiteralType

    package convenience init(unicodeScalarLiteral value: UnicodeScalarLiteralType) {
        self.init(value)
    }
    package convenience init(extendedGraphemeClusterLiteral value: ExtendedGraphemeClusterLiteralType) {
        self.init(value)
    }
    package convenience init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}

package protocol TestBuildPhase { }
fileprivate protocol TestInternalBuildPhase: TestInternalItem, TestBuildPhase, Sendable {
    func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildPhase
}

package final class TestCopyFilesBuildPhase: TestInternalBuildPhase {
    static let guidCode = "CFBP"
    let guidIdentifier = nextGuidIdentifier()
    private let buildFiles: [TestBuildFile]
    private let destinationSubfolder: String
    private let destinationSubpath: String
    private let onlyForDeployment: Bool

    package enum TestDestinationSubfolder: Sendable {
        case absolute
        case builtProductsDir
        case buildSetting(String)

        package static let wrapper = Self.buildSetting("$(WRAPPER_NAME)")
        package static let resources = Self.buildSetting("$(UNLOCALIZED_RESOURCES_FOLDER_PATH)")
        package static let frameworks = Self.buildSetting("$(FRAMEWORKS_FOLDER_PATH)")
        package static let sharedFrameworks = Self.buildSetting("$(SHARED_FRAMEWORKS_FOLDER_PATH)")
        package static let sharedSupport = Self.buildSetting("$(SHARED_SUPPORT_FOLDER_PATH)")
        package static let plugins = Self.buildSetting("$(PLUGINS_FOLDER_PATH)")
        package static let javaResources = Self.buildSetting("$(JAVA_FOLDER_PATH)")

        package var pathString: String {
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

    package init(_ buildFiles: [TestBuildFile] = [], destinationSubfolder: TestDestinationSubfolder, destinationSubpath: String = "", onlyForDeployment: Bool = true) {
        self.buildFiles = buildFiles
        self.destinationSubfolder = destinationSubfolder.pathString
        self.destinationSubpath = destinationSubpath
        self.onlyForDeployment = onlyForDeployment
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildPhase {
        return try SWBProtocol.CopyFilesBuildPhase(
            guid: guid,
            buildFiles: buildFiles.map { try $0.toProtocol(resolver) },
            destinationSubfolder: .string(destinationSubfolder),
            destinationSubpath: .string(destinationSubpath),
            runOnlyForDeploymentPostprocessing: onlyForDeployment)
    }
}

package final class TestAppleScriptBuildPhase: TestInternalBuildPhase {
    static let guidCode = "ASBP"
    let guidIdentifier = nextGuidIdentifier()
    private let buildFiles: [TestBuildFile]

    package init(_ buildFiles: [TestBuildFile] = [], onlyForDeployment: Bool = true) {
        self.buildFiles = buildFiles
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildPhase {
        return try SWBProtocol.AppleScriptBuildPhase(guid: guid, buildFiles: buildFiles.map{ try $0.toProtocol(resolver) })
    }
}

package final class TestFrameworksBuildPhase: TestInternalBuildPhase {
    static let guidCode = "FBP"
    let guidIdentifier = nextGuidIdentifier()
    private let buildFiles: [TestBuildFile]

    package init(_ buildFiles: [TestBuildFile] = []) {
        self.buildFiles = buildFiles
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildPhase {
        return try SWBProtocol.FrameworksBuildPhase(guid: guid, buildFiles: buildFiles.map{ try $0.toProtocol(resolver) })
    }
}

package final class TestHeadersBuildPhase: TestInternalBuildPhase {
    static let guidCode = "HBP"
    let guidIdentifier = nextGuidIdentifier()
    private let buildFiles: [TestBuildFile]

    package init(_ buildFiles: [TestBuildFile] = []) {
        self.buildFiles = buildFiles
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildPhase {
        return try SWBProtocol.HeadersBuildPhase(guid: guid, buildFiles: buildFiles.map{ try $0.toProtocol(resolver) })
    }
}
package final class TestShellScriptBuildPhase: TestInternalBuildPhase {
    static let guidCode = "SSBP"
    let guidIdentifier = nextGuidIdentifier()
    private let overriddenGuid: String?
    private let name: String
    private let shellPath: String
    private let originalObjectID: String
    private let contents: String
    private let inputs: [String]
    private let inputFileLists: [String]
    private let outputs: [String]
    private let outputFileLists: [String]
    private let onlyForDeployment: Bool
    private let emitEnvironment: Bool
    private let sandboxingOverride: SWBProtocol.SandboxingOverride
    private let dependencyInfo: SWBProtocol.DependencyInfo?
    private let alwaysOutOfDate: Bool
    private let alwaysRunForInstallHdrs: Bool

    var guid: String {
        return overriddenGuid ?? "\(Self.guidCode)\(guidIdentifier)"
    }

    package init(name: String, guid: String? = nil, shellPath: String = "/bin/sh", originalObjectID: String, contents: String = "", inputs: [String] = [], inputFileLists: [String] = [], outputs: [String] = [], outputFileLists: [String] = [], onlyForDeployment: Bool = false, emitEnvironment: Bool = false, dependencyInfo: SWBProtocol.DependencyInfo? = nil, alwaysOutOfDate: Bool = false, sandboxingOverride: SWBProtocol.SandboxingOverride = .basedOnBuildSetting, alwaysRunForInstallHdrs: Bool = false) {
        self.name = name
        self.overriddenGuid = guid
        self.shellPath = shellPath
        self.originalObjectID = originalObjectID
        self.contents = contents
        self.inputs = inputs
        self.inputFileLists = inputFileLists
        self.outputs = outputs
        self.outputFileLists = outputFileLists
        self.onlyForDeployment = onlyForDeployment
        self.emitEnvironment = emitEnvironment
        self.dependencyInfo = dependencyInfo
        self.alwaysOutOfDate = alwaysOutOfDate
        self.sandboxingOverride = sandboxingOverride
        self.alwaysRunForInstallHdrs = alwaysRunForInstallHdrs
    }

    fileprivate func toProtocol(_ resolver: any Resolver) -> SWBProtocol.BuildPhase {
        let inputs = self.inputs.map{ MacroExpressionSource.string($0) }
        let outputs = self.outputs.map{ MacroExpressionSource.string($0) }
        let inputFileLists = self.inputFileLists.map{ MacroExpressionSource.string($0) }
        let outputFileLists = self.outputFileLists.map{ MacroExpressionSource.string($0) }
        return SWBProtocol.ShellScriptBuildPhase(
            guid: guid,
            name: name,
            // FIXME: This is not a path.
            shellPath: Path(shellPath),
            scriptContents: contents,
            originalObjectID: originalObjectID,
            inputFilePaths: inputs,
            inputFileListPaths: inputFileLists,
            outputFilePaths: outputs,
            outputFileListPaths: outputFileLists,
            emitEnvironment: emitEnvironment,
            runOnlyForDeploymentPostprocessing: onlyForDeployment,
            dependencyInfo: dependencyInfo,
            alwaysOutOfDate: alwaysOutOfDate,
            sandboxingOverride: sandboxingOverride,
            alwaysRunForInstallHdrs: alwaysRunForInstallHdrs
        )
    }
}

package final class TestResourcesBuildPhase: TestInternalBuildPhase {
    static let guidCode = "RBP"
    let guidIdentifier = nextGuidIdentifier()
    private let buildFiles: [TestBuildFile]

    package init(_ buildFiles: [TestBuildFile] = [], onlyForDeployment: Bool = true) {
        self.buildFiles = buildFiles
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildPhase {
        return try SWBProtocol.ResourcesBuildPhase(guid: guid, buildFiles: buildFiles.map{ try $0.toProtocol(resolver) })
    }
}

package final class TestRezBuildPhase: TestInternalBuildPhase {
    static let guidCode = "ZBP"
    let guidIdentifier = nextGuidIdentifier()
    private let buildFiles: [TestBuildFile]

    package init(_ buildFiles: [TestBuildFile] = []) {
        self.buildFiles = buildFiles
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildPhase {
        return try SWBProtocol.RezBuildPhase(guid: guid, buildFiles: buildFiles.map{ try $0.toProtocol(resolver) })
    }
}

package final class TestSourcesBuildPhase: TestInternalBuildPhase {
    static let guidCode = "SBP"
    let guidIdentifier = nextGuidIdentifier()
    private let buildFiles: [TestBuildFile]

    package init(_ buildFiles: [TestBuildFile] = []) {
        self.buildFiles = buildFiles
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildPhase {
        return try SWBProtocol.SourcesBuildPhase(guid: guid, buildFiles: buildFiles.map{ try $0.toProtocol(resolver) })
    }
}

package final class TestBuildRule: TestInternalItem, Sendable {
    static let guidCode = "BR"
    let guidIdentifier = nextGuidIdentifier()
    private let name: String
    private let inputSpecifier: SWBProtocol.BuildRule.InputSpecifier
    private let actionSpecifier: SWBProtocol.BuildRule.ActionSpecifier

    package init(name: String = "Test Build Rule", fileTypeIdentifier: String, compilerIdentifier: String) {
        self.name = name
        self.inputSpecifier = .fileType(identifier: fileTypeIdentifier)
        self.actionSpecifier = .compiler(identifier: compilerIdentifier)
    }

    package init(name: String = "Test Build Rule", filePattern: String, compilerIdentifier: String) {
        self.name = name
        self.inputSpecifier = .patterns(.string(filePattern))
        self.actionSpecifier = .compiler(identifier: compilerIdentifier)
    }

    package convenience init(name: String = "Test Build Rule", fileTypeIdentifier: String, script: String, inputs: [String] = [], outputs: [String] = [], outputFilesCompilerFlags: [[String]] = [], dependencyInfo: SWBProtocol.DependencyInfo? = nil, runOncePerArchitecture: Bool? = nil) {
        self.init(name: name, inputSpecifier: .fileType(identifier: fileTypeIdentifier), script: script, inputs: inputs, inputFileLists: [], outputs: outputs, outputFileLists: [], outputFilesCompilerFlags: outputFilesCompilerFlags, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
    }

    package convenience init(name: String = "Test Build Rule", filePattern: String, script: String, inputs: [String] = [], outputs: [String] = [], outputFilesCompilerFlags: [[String]] = [], dependencyInfo: SWBProtocol.DependencyInfo? = nil, runOncePerArchitecture: Bool? = nil) {
        self.init(name: name, inputSpecifier: .patterns(.string(filePattern)), script: script, inputs: inputs, inputFileLists: [], outputs: outputs, outputFileLists: [], outputFilesCompilerFlags: outputFilesCompilerFlags, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
    }

    package convenience init(name: String = "Test Build Rule", filePattern: String, script: String, inputs: [String] = [], inputFileLists: [String] = [], outputs: [String] = [], outputFileLists: [String] = [], outputFilesCompilerFlags: [[String]] = [], dependencyInfo: SWBProtocol.DependencyInfo? = nil, runOncePerArchitecture: Bool? = nil) {
        self.init(name: name, inputSpecifier: .patterns(.string(filePattern)), script: script, inputs: inputs, inputFileLists: inputFileLists, outputs: outputs, outputFileLists: outputFileLists, outputFilesCompilerFlags: outputFilesCompilerFlags, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture)
    }

    private init(name: String, inputSpecifier: SWBProtocol.BuildRule.InputSpecifier, script: String, inputs: [String], inputFileLists: [String], outputs: [String], outputFileLists: [String], outputFilesCompilerFlags: [[String]], dependencyInfo: SWBProtocol.DependencyInfo?, runOncePerArchitecture: Bool?) {
        self.name = name
        self.inputSpecifier = inputSpecifier

        let outputs = outputs.enumerated().map{ (entry) -> SWBProtocol.BuildRule.ShellScriptOutputInfo in
                let (i, output) = entry
                if i < outputFilesCompilerFlags.count {
                    return .init(path: .string(output), additionalCompilerFlags: .stringList(outputFilesCompilerFlags[i]))
                } else {
                    return .init(path: .string(output), additionalCompilerFlags: nil)
                }
            }
        self.actionSpecifier = .shellScript(contents: script, inputs: inputs.map{ .string($0) }, inputFileLists: inputFileLists.map { .string($0) }, outputs: outputs, outputFileLists: outputFileLists.map { .string($0) }, dependencyInfo: dependencyInfo, runOncePerArchitecture: runOncePerArchitecture ?? true)
    }

    fileprivate func toProtocol(_ resolver: any Resolver) -> SWBProtocol.BuildRule {
        return SWBProtocol.BuildRule(guid: guid, name: name, inputSpecifier: inputSpecifier, actionSpecifier: actionSpecifier)
    }
}

package final class TestCustomTask: Sendable {
    package let commandLine: [String]
    package let environment: [String: String]
    package let workingDirectory: String
    package let executionDescription: String
    package let inputs: [String]
    package let outputs: [String]
    package let enableSandboxing: Bool
    package let preparesForIndexing: Bool

    package init(commandLine: [String], environment: [String : String], workingDirectory: String, executionDescription: String, inputs: [String], outputs: [String], enableSandboxing: Bool, preparesForIndexing: Bool) {
        self.commandLine = commandLine
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.executionDescription = executionDescription
        self.inputs = inputs
        self.outputs = outputs
        self.enableSandboxing = enableSandboxing
        self.preparesForIndexing = preparesForIndexing
    }

    fileprivate func toProtocol(_ resolver: any Resolver) -> SWBProtocol.CustomTask {
        return SWBProtocol.CustomTask(
            commandLine: commandLine.map { MacroExpressionSource.string($0) },
            environment: environment.map { (MacroExpressionSource.string($0), MacroExpressionSource.string($1)) },
            workingDirectory: MacroExpressionSource.string(workingDirectory),
            executionDescription: MacroExpressionSource.string(executionDescription),
            inputFilePaths: inputs.map { MacroExpressionSource.string($0) },
            outputFilePaths: outputs.map { MacroExpressionSource.string($0) },
            enableSandboxing: enableSandboxing,
            preparesForIndexing: preparesForIndexing
        )
    }
}

package typealias PlatformFilter = SWBProtocol.PlatformFilter

package final class TestTargetDependency: Sendable {
    package let name: String
    package let platformFilters: Set<PlatformFilter>

    package init(_ name: String, platformFilters: Set<PlatformFilter> = []) {
        self.name = name
        self.platformFilters = platformFilters
    }

    fileprivate func toProtocol(_ resolver: any Resolver) -> SWBProtocol.TargetDependency {
        return SWBProtocol.TargetDependency(guid: resolver.findTarget(name)?.guid ?? name, name: name, platformFilters: platformFilters)
    }
}

extension TestTargetDependency: ExpressibleByStringLiteral {
    package typealias StringLiteralType = String

    package convenience init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}

package protocol TestTarget: Sendable {
    var guid: String { get }
    var name: String { get }
}
private protocol TestInternalTarget: TestInternalObjectItem, TestTarget {
    var name: String { get }

    var signature: String { get }

    func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.Target
}
extension TestInternalTarget {
    fileprivate func toObject(_ resolver: any Resolver) throws -> PropertyListItem {
        let serializer = MsgPackSerializer()
        try serializer.serialize(toProtocol(resolver))
        return .plDict([
            "signature": .plString(signature),
            "type": .plString("target"),
            "contents": .plDict(["data": .plArray(serializer.byteString.bytes.map { .plInt(Int($0)) })])
        ])
    }
}

package final class TestStandardTarget: TestInternalTarget, Sendable {
    package var signature: String { return "TARGET@v11_\(guid)" }

    // Redeclaring this as public, so clients can use it.
    package var guid: String {
        return overriddenGuid ?? "\(Swift.type(of: self).guidCode)-\(name)-\(guidIdentifier)"
    }

    package enum TargetType: Sendable {
        case application
        case commandLineTool
        case hostBuildTool
        case framework
        case staticFramework
        case staticLibrary
        case objectFile
        case dynamicLibrary
        case bundle
        case xpcService
        case applicationExtension
        case extensionKitExtension
        case xcodeExtension
        case unitTest
        case uiTest
        case multiDeviceUITest
        case systemExtension
        case driverExtension
        case kernelExtension
        case watchKitAppContainer
        case watchKitApp
        case watchKitExtension
        case messagesApp
        case messagesExtension
        case messagesStickerPackExtension
        case instrumentsPackage
        case inAppPurchaseContent
        case appClip

        // This only still exists to test the deprecation error message
        case watchKit1App

        var productTypeIdentifier: String {
            switch self {
            case .application:
                return "com.apple.product-type.application"
            case .commandLineTool:
                return "com.apple.product-type.tool"
            case .hostBuildTool:
                return "com.apple.product-type.tool.host-build"
            case .framework:
                return "com.apple.product-type.framework"
            case .staticFramework:
                return "com.apple.product-type.framework.static"
            case .staticLibrary:
                return "com.apple.product-type.library.static"
            case .objectFile:
                return "com.apple.product-type.objfile"
            case .dynamicLibrary:
                return "com.apple.product-type.library.dynamic"
            case .bundle:
                return "com.apple.product-type.bundle"
            case .xpcService:
                return "com.apple.product-type.xpc-service"
            case .applicationExtension:
                return "com.apple.product-type.app-extension"
            case .extensionKitExtension:
                return "com.apple.product-type.extensionkit-extension"
            case .xcodeExtension:
                return "com.apple.product-type.xcode-extension"
            case .unitTest:
                return "com.apple.product-type.bundle.unit-test"
            case .uiTest:
                return "com.apple.product-type.bundle.ui-testing"
            case .multiDeviceUITest:
                return "com.apple.product-type.bundle.multi-device-ui-testing"
            case .systemExtension:
                return "com.apple.product-type.system-extension"
            case .driverExtension:
                return "com.apple.product-type.driver-extension"
            case .kernelExtension:
                return "com.apple.product-type.kernel-extension"
            case .watchKitAppContainer:
                return "com.apple.product-type.application.watchapp2-container"
            case .watchKit1App:
                return "com.apple.product-type.application.watchapp"
            case .watchKitApp:
                return "com.apple.product-type.application.watchapp2"
            case .watchKitExtension:
                return "com.apple.product-type.watchkit2-extension"
            case .messagesApp:
                return "com.apple.product-type.application.messages"
            case .messagesExtension:
                return "com.apple.product-type.app-extension.messages"
            case .messagesStickerPackExtension:
                return "com.apple.product-type.app-extension.messages-sticker-pack"
            case .instrumentsPackage:
                return "com.apple.product-type.instruments-package"
            case .inAppPurchaseContent:
                return "com.apple.product-type.in-app-purchase-content"
            case .appClip:
                return "com.apple.product-type.application.on-demand-install-capable"
            }
        }

        func computeProductReferenceName(_ name: String) -> String {
            switch self {
            case .application,
                 .watchKit1App,
                 .watchKitApp,
                 .watchKitAppContainer,
                 .messagesApp,
                 .appClip:
                return "\(name).app"
            case .commandLineTool,
                 .hostBuildTool:
                return "\(name)"
            case .framework,
                 .staticFramework:
                return "\(name).framework"
            case .staticLibrary:
                return "lib\(name).a"
            case .objectFile:
                return "\(name).o"
            case .dynamicLibrary:
                // FIXME: This should be based on the target platform, not the host. See also: <rdar://problem/29410050> Swift Build doesn't support product references with non-constant basenames
                guard let suffix = try? ProcessInfo.processInfo.hostOperatingSystem().imageFormat.dynamicLibraryExtension else {
                    return ""
                }
                return "lib\(name).\(suffix)"
            case .bundle:
                return "\(name).bundle"
            case .xpcService:
                return "\(name).xpc"
            case .applicationExtension,
                 .extensionKitExtension,
                 .xcodeExtension,
                 .watchKitExtension,
                 .messagesExtension,
                 .messagesStickerPackExtension:
                return "\(name).appex"
            case .unitTest, .uiTest, .multiDeviceUITest:
                return "\(name).xctest"
            case .systemExtension:
                return "\(name).systemextension"
            case .driverExtension:
                return "\(name).dext"
            case .kernelExtension:
                return "\(name).kext"
            case .instrumentsPackage:
                return "\(name).instrdst"
            case .inAppPurchaseContent:
                return "\(name)"
            }
        }
    }

    static let guidCode = "T"
    let guidIdentifier = nextGuidIdentifier()
    package let name: String
    private let type: TargetType
    private let buildConfigurations: [TestBuildConfiguration]
    private let buildPhases: [any TestInternalBuildPhase]
    private let buildRules: [TestBuildRule]
    private let customTasks: [TestCustomTask]
    private let dependencies: [TestTargetDependency]
    private let explicitProductReferenceName: String?
    private let predominantSourceCodeLanguage: SWBCore.StandardTarget.SourceCodeLanguage
    private let provisioningSourceData: [ProvisioningSourceData]
    private let overriddenGuid: String?
    private let dynamicTargetVariantName: String?
    private let approvedByUser: Bool

    /// Create a test target
    package init(_ name: String, guid: String? = nil, type: TargetType, buildConfigurations: [TestBuildConfiguration]? = nil, buildPhases: [any TestBuildPhase] = [], buildRules: [TestBuildRule] = [], customTasks: [TestCustomTask] = [], dependencies: [TestTargetDependency] = [], productReferenceName: String? = nil, predominantSourceCodeLanguage: SWBCore.StandardTarget.SourceCodeLanguage = .undefined, provisioningSourceData: [ProvisioningSourceData] = [], dynamicTargetVariantName: String? = nil, approvedByUser: Bool = true) {
        self.name = name
        self.overriddenGuid = guid
        self.type = type
        self.buildConfigurations = buildConfigurations ?? [TestBuildConfiguration("Debug")]
        self.buildPhases = buildPhases.map { $0 as! (any TestInternalBuildPhase) }
        self.buildRules = buildRules
        self.customTasks = customTasks
        self.dependencies = dependencies
        self.explicitProductReferenceName = productReferenceName ?? {
            // Try to correctly determine the product reference if not specified explicitly
            let productNames = Set((buildConfigurations ?? []).compactMap { $0.buildSettings["PRODUCT_NAME"] })
            if productNames.count > 1 {
                preconditionFailure("productReferenceName must be explicitly set for this target because it cannot be determined automatically in this context")
            }

            // Just return nil; we'll end up using the target name
            if productNames.first == "$(TARGET_NAME)" {
                return nil
            }

            if productNames.first?.contains("$") == true {
                preconditionFailure("productReferenceName must be explicitly set for this target because it cannot be determined automatically in this context (build setting references are not evaluated here)")
            }

            return productNames.first.map { type.computeProductReferenceName($0) }
        }()
        self.predominantSourceCodeLanguage = predominantSourceCodeLanguage
        self.provisioningSourceData = provisioningSourceData
        self.dynamicTargetVariantName = dynamicTargetVariantName
        self.approvedByUser = approvedByUser
    }

    fileprivate var productReferenceGUID: String {
        return "PR\(guidIdentifier)"
    }

    fileprivate var productReferenceName: String {
        return explicitProductReferenceName ?? type.computeProductReferenceName(name)
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.Target {
        let ref = SWBProtocol.ProductReference(guid: productReferenceGUID, name: productReferenceName)
        let performanceTestsBaselinePath = try (type == .unitTest) ? resolver.findProject(for: self).getPath(resolver).join("xcshareddata/xcbaselines").join("\(guid).xcbaseline") : nil
        return try SWBProtocol.StandardTarget(guid: guid, name: name, buildConfigurations: buildConfigurations.map{ try $0.toProtocol(resolver) }, customTasks: customTasks.map { $0.toProtocol(resolver) }, dependencies: dependencies.map{ $0.toProtocol(resolver) }, buildPhases: buildPhases.map{ try $0.toProtocol(resolver) }, buildRules: buildRules.map{ $0.toProtocol(resolver) }, productTypeIdentifier: type.productTypeIdentifier, productReference: ref, performanceTestsBaselinesPath: performanceTestsBaselinePath?.str, predominantSourceCodeLanguage: predominantSourceCodeLanguage.description, provisioningSourceData: provisioningSourceData, dynamicTargetVariantGuid: dynamicTargetVariantName?.nilIfEmpty.map(resolver.findTarget)??.guid, approvedByUser: approvedByUser)
    }
}

package final class TestAggregateTarget: TestInternalTarget {
    package var signature: String { return "TARGET@v11_\(guid)" }
    private let overriddenGuid: String?

    // Redeclaring this as public, so clients can use it.
    package var guid: String {
        return overriddenGuid ?? "\(type(of: self).guidCode)-\(name)-\(guidIdentifier)"
    }

    static let guidCode = "AT"
    let guidIdentifier = nextGuidIdentifier()
    package let name: String
    private let buildConfigurations: [TestBuildConfiguration]
    private let buildPhases: [any TestInternalBuildPhase]
    private let customTasks: [TestCustomTask]
    private let dependencies: [String]

    package init(_ name: String, guid: String? = nil, buildConfigurations: [TestBuildConfiguration]? = nil, buildPhases: [any TestBuildPhase] = [], customTasks: [TestCustomTask] = [], dependencies: [String] = []) {
        self.name = name
        self.overriddenGuid = guid
        self.buildConfigurations = buildConfigurations ?? [TestBuildConfiguration("Debug")]
        self.buildPhases = buildPhases.map { $0 as! (any TestInternalBuildPhase) }
        self.customTasks = customTasks
        self.dependencies = dependencies
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.Target {
        let deps = dependencies.map { SWBProtocol.TargetDependency(guid: resolver.findTarget($0)?.guid ?? $0, name: $0) }
        return try SWBProtocol.AggregateTarget(guid: guid, name: name, buildConfigurations: buildConfigurations.map{ try $0.toProtocol(resolver) }, customTasks: customTasks.map { $0.toProtocol(resolver) }, dependencies: deps, buildPhases: buildPhases.map{ try $0.toProtocol(resolver) })
    }
}

package final class TestExternalTarget: TestInternalTarget {
    package var signature: String { return "TARGET@v11_\(guid)" }

    // Redeclaring this as public, so clients can use it.
    package var guid: String {
        return actualGUID
    }

    var actualGUID: String {
        return "\(type(of: self).guidCode)\(guidIdentifier)"
    }

    static let guidCode = "ET"
    let guidIdentifier = nextGuidIdentifier()
    package let name: String
    private let toolPath: String
    private let arguments: String
    private let workingDirectory: String
    private let buildConfigurations: [TestBuildConfiguration]
    private let customTasks: [TestCustomTask]
    private let dependencies: [String]
    private let passBuildSettingsInEnvironment: Bool?

    package init(_ name: String, toolPath: String = "/usr/bin/make", arguments: String = "$(ACTION)", workingDirectory: String = "$(PROJECT_DIR)", buildConfigurations: [TestBuildConfiguration]? = nil, customTasks: [TestCustomTask] = [], dependencies: [String] = [], passBuildSettingsInEnvironment: Bool? = nil) {
        self.name = name
        self.toolPath = toolPath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.buildConfigurations = buildConfigurations ?? [TestBuildConfiguration("Debug")]
        self.customTasks = customTasks
        self.dependencies = dependencies
        self.passBuildSettingsInEnvironment = passBuildSettingsInEnvironment
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.Target {
        return try SWBProtocol.ExternalTarget(guid: actualGUID, name: name, buildConfigurations: buildConfigurations.map{ try $0.toProtocol(resolver) }, customTasks: customTasks.map { $0.toProtocol(resolver) }, dependencies: dependencies.map { TargetDependency(guid: resolver.findTarget($0)?.guid ?? $0, name: $0) }, toolPath: .string(toolPath), arguments: .string(arguments), workingDirectory: .string(workingDirectory), passBuildSettingsInEnvironment: passBuildSettingsInEnvironment ?? true)
    }
}

package final class TestPackageProductTarget: TestInternalTarget {
    package var signature: String { return "TARGET@v11_\(guid)" }

    // Redeclaring this as public, so clients can use it.
    package var guid: String {
        return "\(type(of: self).guidCode)\(guidIdentifier)"
    }

    static let guidCode = "PPT"
    let guidIdentifier = nextGuidIdentifier()
    package let name: String
    private let frameworksBuildPhase: TestFrameworksBuildPhase
    private let customTasks: [TestCustomTask]
    private let dependencies: [String]
    private let buildConfigurations: [TestBuildConfiguration]
    private let dynamicTargetVariantName: String?
    private let approvedByUser: Bool

    package init(_ name: String, frameworksBuildPhase: TestFrameworksBuildPhase, dynamicTargetVariantName: String? = nil, approvedByUser: Bool = true, buildConfigurations: [TestBuildConfiguration]? = nil, customTasks: [TestCustomTask] = [], dependencies: [String] = []) {
        self.name = name
        self.frameworksBuildPhase = frameworksBuildPhase
        self.dynamicTargetVariantName = dynamicTargetVariantName
        self.approvedByUser = approvedByUser
        self.buildConfigurations = buildConfigurations ?? [TestBuildConfiguration("Debug")]
        self.customTasks = customTasks
        self.dependencies = dependencies
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.Target {
        let deps = dependencies.map { SWBProtocol.TargetDependency(guid: resolver.findTarget($0)?.guid ?? $0, name: $0) }
        return try SWBProtocol.PackageProductTarget(guid: guid, name: name, buildConfigurations: buildConfigurations.map{ try $0.toProtocol(resolver) }, customTasks: customTasks.map { $0.toProtocol(resolver) }, dependencies: deps, frameworksBuildPhase: frameworksBuildPhase.toProtocol(resolver) as! SWBProtocol.FrameworksBuildPhase, dynamicTargetVariantGuid: dynamicTargetVariantName?.nilIfEmpty.map(resolver.findTarget)??.guid, approvedByUser: approvedByUser)

    }
}

package final class TestBuildConfiguration: TestInternalItem, Sendable {
    static let guidCode = "BC"
    let guidIdentifier = nextGuidIdentifier()
    fileprivate let name: String
    private let baseConfig: String?
    fileprivate let buildSettings: [String: String]
    private let impartedBuildProperties: TestImpartedBuildProperties

    package init(_ name: String, baseConfig: String? = nil, buildSettings: [String: String] = [:], impartedBuildProperties: TestImpartedBuildProperties = TestImpartedBuildProperties()) {
        self.name = name
        self.baseConfig = baseConfig
        self.buildSettings = buildSettings
        self.impartedBuildProperties = impartedBuildProperties
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.BuildConfiguration {
        let baseConfigGUID = try self.baseConfig.map{ try resolver.findFile($0) }
        return SWBProtocol.BuildConfiguration(name: name, buildSettings: buildSettings.map{ .init(key: $0.0, value: .string($0.1)) }, baseConfigurationFileReferenceGUID: baseConfigGUID, impartedBuildProperties: impartedBuildProperties.toProtocol(resolver))
    }
}

package final class TestImpartedBuildProperties: TestInternalItem, Sendable {
    static let guidCode = "BP"
    let guidIdentifier = nextGuidIdentifier()
    private let buildSettings: [String: String]

    package init(buildSettings: [String: String] = [:]) {
        self.buildSettings = buildSettings
    }

    fileprivate func toProtocol(_ resolver: any Resolver) -> SWBProtocol.ImpartedBuildProperties {
        return SWBProtocol.ImpartedBuildProperties(buildSettings: buildSettings.map{ .init(key: $0.0, value: .string($0.1)) })
    }
}

package class TestProject: TestInternalObjectItem, @unchecked Sendable {
    static let guidCode = "P"
    let guidIdentifier = nextGuidIdentifier()
    package let name: String
    fileprivate var isPackage: Bool { return false }
    package let sourceRoot: Path?
    private let defaultConfigurationName: String
    private let developmentRegion: String
    private let buildConfigurations: [TestBuildConfiguration]
    package let targets: [any TestTarget]
    fileprivate var _targets: [any TestInternalTarget] {
        return targets.map { $0 as! (any TestInternalTarget) }
    }
    fileprivate let groupTree: TestGroup
    package var signature: String { return "PROJECT@v11_\(guid)" }
    private let classPrefix: String
    private let appPreferencesBuildSettings: [String: String]
    private let overriddenGuid: String?

    // Redeclaring this as public, so clients can use it.
    package var guid: String {
        return overriddenGuid ?? "\(type(of: self).guidCode)\(guidIdentifier)"
    }

    package init(_ name: String, guid: String? = nil, sourceRoot: Path? = nil, defaultConfigurationName: String? = nil, groupTree: TestGroup, buildConfigurations: [TestBuildConfiguration]? = nil, targets: [any TestTarget] = [], developmentRegion: String? = nil, classPrefix: String = "", appPreferencesBuildSettings: [String: String] = [:]) {
        self.name = name
        self.overriddenGuid = guid
        self.sourceRoot = sourceRoot
        self.defaultConfigurationName = defaultConfigurationName ?? buildConfigurations?.first?.name ?? "Release"
        self.developmentRegion = developmentRegion ?? "English"
        self.buildConfigurations = buildConfigurations ?? [TestBuildConfiguration("Debug")]
        self.targets = targets
        self.groupTree = groupTree
        self.classPrefix = classPrefix
        self.appPreferencesBuildSettings = appPreferencesBuildSettings
    }

    fileprivate func getPath(_ resolver: any Resolver) -> Path {
        let srcroot = sourceRoot ?? resolver.sourceRoot.join(name)
        return srcroot.join("\(name).xcodeproj")
    }

    fileprivate func toObject(_ resolver: any Resolver) throws -> PropertyListItem {
        let serializer = MsgPackSerializer()
        try serializer.serialize(toProtocol(resolver))
        return .plDict([
            "signature": .plString(signature),
            "type": .plString("project"),
            "contents": .plDict(["data": .plArray(serializer.byteString.bytes.map { .plInt(Int($0)) })])
        ])
    }

    fileprivate func toProtocol(_ resolver: any Resolver) throws -> SWBProtocol.Project {
        let path = getPath(resolver)
        return try SWBProtocol.Project(guid: guid, isPackage: isPackage, xcodeprojPath: path, sourceRoot: sourceRoot ?? path.dirname, targetSignatures: _targets.map{ $0.signature }, groupTree: groupTree.toProtocol(resolver, isRoot: true), buildConfigurations: buildConfigurations.map{ try $0.toProtocol(resolver) }, defaultConfigurationName: defaultConfigurationName, developmentRegion: developmentRegion, classPrefix: classPrefix, appPreferencesBuildSettings: appPreferencesBuildSettings.map{ .init(key: $0.0, value: .string($0.1)) })
    }
}

package final class TestPackageProject: TestProject, @unchecked Sendable {
    override var isPackage: Bool {
        return true
    }
}

package final class TestWorkspace: Resolver, TestInternalItem, Sendable {
    static let guidCode = "W"
    let guidIdentifier: String = nextGuidIdentifier()
    package let name: String
    package let sourceRoot: Path
    package let projects: [TestProject]
    package var signature: String { return "WORKSPACE@v11_\(guid)" }
    private let overriddenGuid: String?

    // Redeclaring this as public, so clients can use it.
    package var guid: String {
        return overriddenGuid ?? "\(type(of: self).guidCode)\(guidIdentifier)"
    }

    package init(_ name: String, guid: String? = nil, sourceRoot: Path? = nil, projects: [TestProject], sourceLocation: SourceLocation = #_sourceLocation) {
        self.name = name
        self.overriddenGuid = guid
        self.sourceRoot = sourceRoot ?? Path.root.join("tmp").join(name)
        self.projects = projects
    }

    /// Load the test workspace into a concrete object, via a PIF.
    package func load(_ core: Core) throws -> SWBCore.Workspace {
        // Convert the workspace to a property list.
        let propertyList = try PropertyListItem(toObjects())

        // Load as a PIF.
        let loader = PIFLoader(data: propertyList, namespace: core.specRegistry.internalMacroNamespace)
        return try loader.load(workspaceSignature: signature)
    }

    /// Load the test workspace into a helper which can provide various derived objects.
    package func loadHelper(_ core: Core) throws-> WorkspaceTestHelper {
        return WorkspaceTestHelper(try load(core), core: core)
    }

    package func toObjects() throws -> [PropertyListItem] {
        return try [toObject(self)] + projects.map{ try $0.toObject(self) } + projects.flatMap{ try $0._targets.map{ try $0.toObject(self) } }
    }

    fileprivate func toObject(_ resolver: any Resolver) -> PropertyListItem {
        let serializer = MsgPackSerializer()
        serializer.serialize(toProtocol(resolver))
        return .plDict([
            "signature": .plString(signature),
            "type": .plString("workspace"),
            "contents": .plDict(["data": .plArray(serializer.byteString.bytes.map { .plInt(Int($0)) })])
        ])
    }

    fileprivate func toProtocol(_ resolver: any Resolver) -> SWBProtocol.Workspace {
        return SWBProtocol.Workspace(guid: guid, name: name, path: sourceRoot.join("\(name).xcworkspace"), projectSignatures: projects.map{ $0.signature })
    }

    var workspaceName: String {
        return name
    }

    package func findSourceFiles() -> [Path] {
        var result: [Path] = []
        func visit(_ path: Path, _ item: any TestInternalStructureItem) {
            switch item {
            case let file as TestFile:
                result.append(path.join(file.name))

            case let group as TestGroup:
                for item in group.children {
                    let subpath: Path
                    if let groupPath = group.path {
                        subpath = path.join(groupPath)
                    } else {
                        subpath = path
                    }
                    visit(subpath, item)
                }

            case let group as TestVariantGroup:
                // Variant groups don't have a path, so we don't add to the subpath here to visit their children.
                for item in group.children {
                    visit(path, item)
                }

            case let group as TestVersionGroup:
                // Version groups get added to the results, and their children get added to the results.
                result.append(path.join(group.name))
                for item in group.children {
                    let subpath: Path
                    if let groupPath = group.path {
                        subpath = path.join(groupPath)
                    } else {
                        subpath = path
                    }
                    visit(subpath, item)
                }

            default:
                break
            }
        }

        for project in projects {
            visit(project.getPath(self).dirname, project.groupTree)
        }

        return result
    }

    fileprivate func findAuto(_ name: String) throws -> TestBuildableItem {
        for project in projects {
            // Look in the product references.
            for target in project._targets {
                guard let standardTarget = target as? TestStandardTarget else { continue }

                // FIXME: <rdar://119010301> This should not resolve to a product reference if the target is in a different project (unless a project reference is involved, which I don't think the test model presently supports).  This can result in subtle issues not being caught by the test when logic which relies on using a product reference (or not) is a factor.  For example some of the mergeable libraries logic.
                if standardTarget.productReferenceName == name {
                    return .targetProduct(guid: standardTarget.guid)
                }
            }

            // Look in the group tree.
            if let result = visit(name, project.groupTree) {
                return .reference(guid: result)
            }
        }

        throw StubError.error("unable to find file (or target) in workspace named: '\(name)'")
    }

    fileprivate func findFile(_ name: String) throws -> String {
        for project in projects {
            // Look in the group tree.
            if let result = visit(name, project.groupTree) {
                return result
            }
        }

        throw StubError.error("unable to find file in workspace named: '\(name)'")
    }

    private func visit(_ name: String, _ item: any TestInternalStructureItem) -> String? {
        switch item {
        case let file as TestFile:
            return file.guid == name || Path(file.name).ends(with: name) ? file.guid : nil
        case let group as TestGroup:
            for item in group.children {
                if let result = visit(name, item) {
                    return result
                }
            }
            return nil
        case let variantGroup as TestVariantGroup:
            return variantGroup.name == name ? variantGroup.guid : nil
        case let versionGroup as TestVersionGroup:
            return versionGroup.name == name ? versionGroup.guid : nil
        default:
            fatalError("unrecognized group item: \(item)")
        }
    }

    package func findTarget(name: String, project: String?) throws -> any TestTarget {
        let targets = projects.filter { $0.name == project || project == nil }.map { $0.targets }.reduce([], +).filter { $0.name == name }
        if let onlyTarget = targets.only {
            return onlyTarget
        }

        if !targets.isEmpty {
            if let project = project {
                throw StubError.error("Multiple targets named '\(name)' in project '\(project)'")
            }

            throw StubError.error("Multiple targets named '\(name)'; specify project name to disambiguate")
        }

        if let project {
            throw StubError.error("No target named '\(name)' in project '\(project)'")
        }

        throw StubError.error("No target named '\(name)'")
    }

    fileprivate func findTarget(_ name: String) -> (any TestInternalTarget)? {
        for project in projects {
            for target in project._targets {
                if target.name == name {
                    return target
                }
            }
        }
        return nil
    }

    fileprivate func findProject(for target: any TestInternalTarget) throws -> TestProject {
        for project in projects {
            for aTarget in project._targets {
                if aTarget === target {
                    return project
                }
            }
        }
        throw StubError.error("could not find project for target \(target)")
    }
}

/// A helper object for fetching test data from a workspace.
package final class WorkspaceTestHelper: Sendable {
    /// The core in use.
    package let core: Core

    /// The wrapped workspace.
    package let workspace: SWBCore.Workspace

    /// A temporary workspace context.
    package let workspaceContext: WorkspaceContext

    init(_ workspace: SWBCore.Workspace, core: Core) {
        self.core = core
        self.workspace = workspace
        self.workspaceContext = WorkspaceContext(core: core, workspace: workspace, processExecutionCache: .sharedForTesting)
        self.workspaceContext.updateUserInfo(UserInfo(user: "exampleUser", group: "exampleGroup", uid: 1234, gid:12345, home: Path("/Users/exampleUser"), environment: [:]))
        self.workspaceContext.updateSystemInfo(SystemInfo(operatingSystemVersion: Version(99, 98, 97), productBuildVersion: "99A98", nativeArchitecture: "x86_64"))
    }

    /// The project in the workspace, if there is only one.
    package var project: SWBCore.Project {
        precondition(workspace.projects.count == 1)
        return workspace.projects[0]
    }

    /// Fetch mock settings for the workspace.
    ///
    /// These settings are for the build action and an empty environment.
    ///
    /// - Parameters:
    ///   - project: The project to get settings for.
    ///   - target: The target to get settings for.
    package func settings(buildRequestContext: BuildRequestContext, project: SWBCore.Project, target: SWBCore.Target? = nil, configuration: String? = "Debug") -> Settings {
        let parameters = BuildParameters(action: .build, configuration: configuration)
        return Settings(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: parameters, project: project, target: target, includeExports: false)
    }

    /// Create a global scope using the default mock settings.
    package func globalScope(buildRequestContext: BuildRequestContext, project: SWBCore.Project, target: SWBCore.Target? = nil, configuration: String? = "Debug") -> MacroEvaluationScope {
        return settings(buildRequestContext: buildRequestContext, project: project, target: target, configuration: configuration).globalScope
    }
}

extension UserPreferences {
    package static let defaultForTesting = UserPreferences(
        enableDebugActivityLogs: false,
        enableBuildDebugging: false,
        enableBuildSystemCaching: true,
        activityTextShorteningLevel: .default,
        usePerConfigurationBuildLocations: nil,
        allowsExternalToolExecution: false)

    package func with(
        enableDebugActivityLogs: Bool? = nil,
        enableBuildDebugging: Bool? = nil,
        enableBuildSystemCaching: Bool? = nil,
        activityTextShorteningLevel: ActivityTextShorteningLevel? = nil,
        usePerConfigurationBuildLocations: Bool?? = .none,
        allowsExternalToolExecution: Bool? = nil
    ) -> UserPreferences {
        let usePerConfigurationBuildLocationsValue: Bool?
        switch usePerConfigurationBuildLocations {
        case let .some(.some(value)):
            usePerConfigurationBuildLocationsValue = value
        case .some(.none):
            usePerConfigurationBuildLocationsValue = nil
        case .none:
            usePerConfigurationBuildLocationsValue = self.usePerConfigurationBuildLocations
        }

        return UserPreferences(
            enableDebugActivityLogs: enableDebugActivityLogs ?? self.enableDebugActivityLogs,
            enableBuildDebugging: enableBuildDebugging ?? self.enableBuildDebugging,
            enableBuildSystemCaching: enableBuildSystemCaching ?? self.enableBuildSystemCaching,
            activityTextShorteningLevel: activityTextShorteningLevel ?? self.activityTextShorteningLevel,
            usePerConfigurationBuildLocations: usePerConfigurationBuildLocationsValue,
            allowsExternalToolExecution: allowsExternalToolExecution ?? self.allowsExternalToolExecution
        )
    }
}
