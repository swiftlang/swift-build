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
public import SWBProtocol
public import SWBMacro

/// Represents a file to be passed as input to some part of the build machinery.  May be a source file originally sent down with the PIF, or might be a temporary file.  Once a build rule action has been determined, it is assigned to the FileToBuild so it doesn’t have to be looked up again.  Note that the term “file” here is used in the loosest sense — the path can refer to any file system entity.
public struct FileToBuild : Hashable {
    /// Absolute path of the referenced file.
    public let absolutePath: Path

    /// File type.
    public let fileType: FileTypeSpec

    /// The build file for the referenced file, if any.
    public let buildFile: BuildFile?

    /// Header visibility of the file, if specified.  This is derived from the build file.
    public var headerVisibility: HeaderVisibility? {
        return buildFile?.headerVisibility
    }

    /// Additional user-specified command line arguments to pass to the build tool, if specified.
    public var additionalArgs: MacroStringListExpression?

    /// The region for this file.
    ///
    /// This is either the explicit regionVariantName or the region name from the backing build file.
    public let regionVariantName: String?

    /// Mig interfaces to generate, if specified.
    public var migCodegenFiles: MigCodegenFiles? {
        return buildFile?.migCodegenFiles
    }

    /// Whether to generate interfaces for intents files
    public var intentsCodegenVisibility: IntentsCodegenVisibility? {
        return buildFile?.intentsCodegenVisibility
    }

    /// Whether to code sign the file when copied, if specified.
    public var codeSignOnCopy: Bool {
        return buildFile?.codeSignOnCopy ?? false
    }

    /// Whether to remove headers when copied, if specified.
    public var removeHeadersOnCopy: Bool {
        return buildFile?.removeHeadersOnCopy ?? false
    }

    // FIXME: This attribute is really private to C compilers, and only used to prevent the versioning stub from using a PCH. It would be nice to find a more narrowly scoped mechanism for this.
    //
    /// Whether the file should use a prefix header, if appropriate.
    public let shouldUsePrefixHeader: Bool

    /// A suffix which can be used to define a unique basename for the file, in the context it is being built.
    public let uniquingSuffix: String

    /// If set, indexing info should use this path instead of `absolutePath`
    public let indexingInputReplacement: Path?

    /// Initializer.
    public init(absolutePath: Path, fileType: FileTypeSpec, buildFile: BuildFile? = nil, additionalArgs: MacroStringListExpression? = nil, uniquingSuffix: String = "", shouldUsePrefixHeader: Bool = true, regionVariantName: String? = nil, indexingInputReplacement: Path? = nil) {
        assert(absolutePath.isAbsolute, "path is not absolute: \(absolutePath)")
        assert(!(additionalArgs != nil && buildFile?.additionalArgs != nil), "unexpected explicit additional args and build file args")
        // We normalize the path here so this form is consistently available to CommandLineToolSpec instances.  The old build system normalized paths in almost all cases.
        self.absolutePath = absolutePath.normalize()
        self.indexingInputReplacement = indexingInputReplacement?.normalize()
        self.fileType = fileType
        self.buildFile = buildFile
        self.additionalArgs = additionalArgs ?? buildFile?.additionalArgs
        self.shouldUsePrefixHeader = shouldUsePrefixHeader
        self.uniquingSuffix = uniquingSuffix

        // Use the explicit region variant name or try to get it from the file path.
        self.regionVariantName = regionVariantName ?? absolutePath.regionVariantName
    }

    // FIXME: Figure out how this should look, maybe clients have to produce the fully formed output, instead of inferring information? We need to determine how often we know the exact file type in situations where we use this.
    //
    /// Convenience initializer, using inferred types.
    public init(absolutePath: Path, inferringTypeUsing specLookupContext: any SpecLookupContext, buildFile: BuildFile? = nil, additionalArgs: MacroStringListExpression? = nil, uniquingSuffix: String = "", shouldUsePrefixHeader: Bool = true, regionVariantName: String? = nil, indexingInputReplacement: Path? = nil) {
        let fileType = specLookupContext.lookupFileType(fileName: absolutePath.basename) ?? specLookupContext.lookupFileType(identifier: "file")!
        self.init(absolutePath: absolutePath, fileType: fileType, buildFile: buildFile, additionalArgs: additionalArgs, uniquingSuffix: uniquingSuffix, shouldUsePrefixHeader: shouldUsePrefixHeader, regionVariantName: regionVariantName, indexingInputReplacement: indexingInputReplacement)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(absolutePath)
        hasher.combine(fileType.identifier)
        hasher.combine(headerVisibility)
    }

    public static func ==(lhs: FileToBuild, rhs: FileToBuild) -> Bool {
        // QUESTION: Does the header visibility really make two files of the same type and the same path different? <rdar://problem/29980516> [Swift Build] Should FileToBuild.== be considering the headerVisibility property?
        return lhs.absolutePath == rhs.absolutePath && lhs.fileType === rhs.fileType && lhs.headerVisibility == rhs.headerVisibility
    }

    /// Fileprivate description to make FileToBuildGroup.description a bit more readable.
    fileprivate var descriptionForGroup: String {
        return "\(type(of: self))(absolutePath: \(absolutePath.str), fileType: \(fileType.identifier):\(fileType.domain == "" ? "\"\"" : fileType.domain), buildFile: \(buildFile?.description ?? "nil") additionalArgs: \(additionalArgs?.description ?? "nil"), regionVariantName: \(regionVariantName?.description ?? "nil"), shouldUsePrefixHeader: \(shouldUsePrefixHeader), uniquingSuffix: \(uniquingSuffix.isEmpty ? "\"\"" : uniquingSuffix), indexingInputReplacement: \(indexingInputReplacement?.str ?? "nil"))"
    }
}

/// Represents a group of one or more files to be processed by a single build task.  Once added to a group, a file cannot be removed from it.
public final class FileToBuildGroup : Hashable, Equatable, CustomStringConvertible {
    /// The identifier for this group.
    public let identifier: String?

    /// The files that are associated with this group.
    public var files: [FileToBuild]

    /// The assigned build rule action.
    public let assignedBuildRuleAction: (any BuildRuleAction)?

    public init(_ identifier: String? = nil, files: [FileToBuild] = [], action: (any BuildRuleAction)?) {
        self.identifier = identifier
        self.files = files
        self.assignedBuildRuleAction = action
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(files)
    }

    public static func ==(lhs: FileToBuildGroup, rhs: FileToBuildGroup) -> Bool {
        return lhs.files == rhs.files
    }

    public var description: String
    {
        // Since only the files are relevant for equality, that's all we emit here.
        let filesDescription = files.map({ $0.descriptionForGroup }).joined(separator: ", ")
        return "<\(type(of: self)):[\(filesDescription)]>"
    }
}

public protocol RegionVariable {
    var regionVariantName: String? { get }
}

extension Path: RegionVariable { }
extension FileToBuild: RegionVariable { }

extension FileToBuildGroup: RegionVariable {
    /// Returns the region variant name for a group of files.
    ///
    /// This only potentially returns a region name if there is a single file, or if all files have the same region.
    /// This makes the result completely unambiguous and order-independent.
    public var regionVariantName: String? {
        return files.regionVariantName
    }
}

extension Array: RegionVariable where Array.Element == FileToBuild {
    public var regionVariantName: String? {
        return Set(map { $0.regionVariantName }).only ?? nil
    }
}

public extension RegionVariable {
    var regionVariantPathComponent: String {
        guard let regionVariantName else { return "" }
        return regionVariantName + ".lproj/"
    }

    /// This is only relevant for the installloc action for Localization projects.
    func isValidLocalizedContent(_ scope: MacroEvaluationScope) -> Bool {
        guard let regionVariantName else { return false }
        let installLocLanguages = Set(scope.evaluate(BuiltinMacros.INSTALLLOC_LANGUAGE))
        return installLocLanguages.isEmpty || installLocLanguages.contains(regionVariantName)
    }
}
