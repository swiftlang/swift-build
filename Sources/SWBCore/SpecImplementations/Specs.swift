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
public import SWBMacro

/// Helper function for processing macro diagnostics.
extension SpecParser {
    package func handleMacroDiagnostic(_ diag: MacroExpressionDiagnostic, _ message: String) {
        switch diag.level {
        case .warning:
            warning("\(message): \(diag)")
        case .error:
            error("\(message): \(diag)")
        }
    }
}

/// Base class for all spec types.
open class Spec: @unchecked Sendable {
    class var typeName: String {
        preconditionFailure("subclass responsibility")
    }

    /// Default to not using a subregistry.
    public class var subregistryName: String {
        return ""
    }

    /// Default to not using a custom class type.
    public class var defaultClassType: (any SpecType.Type)? {
        return nil
    }

    /// Default implementation.
    class public func parseSpec(_ delegate: any SpecParserDelegate, _ proxy: SpecProxy, _ basedOnSpec: Spec?) -> Spec {
        // Create the parser to use.
        let parser = SpecParser(delegate, proxy)

        // Parse the data.
        let result = Self.init(parser, basedOnSpec)

        // Run the completion parsing code.
        parser.complete()

        return result
    }

    /// The spec proxy information.
    @_spi(Testing) public let proxyPath: Path
    @_spi(Testing) public let proxyDomain: String
    @_spi(Testing) public let proxyIdentifier: String

    /// The domain of the spec.
    public let domain: String

    /// The identifier of the spec.
    public let identifier: String

    /// The basedOn spec, if defined.
    @_spi(Testing) public let basedOnSpec: Spec?

    /// The name of the spec, often for display purposes.
    public let name: String

    init(_ registry: SpecRegistry, _ proxy: SpecProxy) {
        self.proxyPath = proxy.path
        self.proxyDomain = proxy.domain
        self.proxyIdentifier = proxy.identifier
        self.basedOnSpec = nil
        self.name = proxy.identifier
        self.domain = proxy.domain
        self.identifier = proxy.identifier
    }

    required public init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        self.proxyPath = parser.proxy.path
        self.proxyDomain = parser.proxy.domain
        self.proxyIdentifier = parser.proxy.identifier
        self.basedOnSpec = basedOnSpec
        self.name = parser.parseString("Name") ?? parser.proxy.identifier
        self.domain = parser.proxy.domain
        self.identifier = parser.proxy.identifier

        // Parse common attributes.
        //
        // FIXME: Audit these to eliminate the ones that are unused once the dust settles.
        parser.parseBool("IsAbstract")
        parser.parseString("Description")
    }

    public func conformsTo<T: Spec>(_ type: T) -> Bool {
        // FIXME: This should do a UTI-like conformance test. For the moment, however, we just check the `BasedOn` chain.
        if type === self { return true }
        guard let basedOnSpec = basedOnSpec as? T else { return false }
        return basedOnSpec.conformsTo(type)
    }

    public func conformsToAny<T: Spec>(_ types: [T]) -> Bool {
        return types.contains(where: conformsTo)
    }

    public func conformsTo(identifier: String) -> Bool {
        if self.identifier == identifier { return true }
        return basedOnSpec?.conformsTo(identifier: identifier) ?? false
    }
}

// Specs use reference semantics.
extension Spec: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }

    public static func ==(lhs: Spec, rhs: Spec) -> Bool {
        return lhs === rhs
    }
}

extension Spec: CustomStringConvertible {
    public var description: String {
        return "\(type(of: self))(identifier: \(self.identifier), domain: \(self.domain))"
    }
}

public final class ArchitectureSpec : Spec, SpecType, @unchecked Sendable {
    class public override var typeName: String {
        return "Architecture"
    }
    class public override var subregistryName: String {
        return "Architecture"
    }

    /// The architecture name.
    public let canonicalName: String

    /// The macro that controls this setting, if declared.
    @_spi(Testing) public let archSetting: MacroDeclaration?

    /// For "virtual" arch settings, the list of archs it represents.
    @_spi(Testing) public let realArchs: MacroStringListExpression?

    /// The list of compatible architectures.
    public let compatibilityArchs: [String]

    /// If set, this constrains when this architecture appears in `ARCHS_STANDARD`.
    public let deploymentTargetRange: Range<Version>?

    /// If this architecture appears in ARCHS outside its deploymentTargetRange, emit an error
    let errorOutsideDeploymentTargetRange: Bool

    /// This emits a deprecation warning if the arch is used
    let deprecated: Bool

    /// This emits a deprecation error if the arch is used
    public let deprecatedError: Bool

    /// Returns `true` if this arch spec represents an actual architecture, not some virtual or build setting pseudo-architecture.
    public var isRealArch: Bool {
        return self.archSetting == nil && self.realArchs == nil
    }

    /// Returns `true` (the default) if the architecture supports mergeable libraries.
    let supportsMergeableLibraries: Bool

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        // Get the canonical name.
        //
        // FIXME: In practice, architecture settings come in two flavors, virtual and non-virtual. These should just be made two distinct subclasses because they honor different keys and have different behaviors. For now, though, we can't enforce anything because the CanonicalName defaults to the identifier, so we can't just use it as a clue to what kind of setting we have.
        canonicalName = parser.parseString("CanonicalName") ?? parser.proxy.identifier

        // Bind the virtual arch setting macro and expression, if used.
        let realArchNames = parser.parseStringList("RealArchitectures")
        if let name = parser.parseString("ArchitectureSetting") {
            // Infer the macro type by the presence of a list of archs. This just happens to work correctly.
            //
            // FIXME: We should make this explicit in the spec.
            let isList = realArchNames != nil

            do {
                if isList {
                    archSetting = try parser.delegate.internalMacroNamespace.declareStringListMacro(name)
                } else {
                    archSetting = try parser.delegate.internalMacroNamespace.declareStringMacro(name)
                }
            } catch {
                parser.error("unable to bind architecture setting name '\(name)': \(error)")
                archSetting = nil
            }

            // Parse the architectures list, if present.
            if realArchNames != nil {
                realArchs = parser.delegate.internalMacroNamespace.parseStringList(realArchNames!)
            } else {
                realArchs = nil
            }
        } else {
            archSetting = nil
            if realArchNames != nil {
                parser.error("cannot define 'RealArchitectures' with no 'ArchitectureSetting'")
            }
            realArchs = nil
        }

        // FIXME: Make the MacOSX Architectures INTERNAL version of this use an array, for consistency.
        compatibilityArchs = parser.parseCommandLineString("CompatibilityArchitectures", inherited: true) ?? []

        deploymentTargetRange = { () -> Range<Version>? in
            let key = "DeploymentTargetRange"
            do {
                guard let range = parser.parseStringList(key) else { return nil }
                guard range.count == 2 else { throw StubError.error("expected 2 entries, but got: \(range)") }

                let lower = try Version(range[0])
                let upper = try Version(range[1])
                guard lower < upper else { throw StubError.error("expected that \(lower) < \(upper)") }

                return Range(uncheckedBounds: (lower, upper))
            }
            catch {
                parser.error("\(key): \(error)")
                return nil
            }
        }()

        errorOutsideDeploymentTargetRange = parser.parseBool("ErrorOutsideDeploymentTargetRange") ?? false
        deprecated = parser.parseBool("Deprecated") ?? false
        deprecatedError = parser.parseBool("DeprecatedError") ?? false
        supportsMergeableLibraries = parser.parseBool("SupportsMergeableLibraries") ?? true

        // Parse and ignore keys we have no use for.
        //
        // FIXME: Eliminate any of these fields which are unused.
        parser.parseBool("ListInEnum")
        parser.parseString("PerArchBuildSettingName")
        parser.parseString("SortNumber")
        super.init(parser, basedOnSpec)
    }
}

public final class ProjectOverridesSpec : Spec, SpecType, @unchecked Sendable {
    class public override var typeName: String {
        return "ProjectOverrides"
    }

    /// The name of the project to apply overrides to.
    let projectName: String

    /// The default build settings to use for this package type.
    let buildSettings: MacroValueAssignmentTable

    /// A link to the bug report to fix the issue requiring this override.
    let bugReport: String

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        projectName = parser.parseRequiredString("ProjectName")
        buildSettings = parser.parseRequiredBuildSettings("BuildSettingOverrides")
        bugReport = parser.parseRequiredString("BugReport")
        super.init(parser, basedOnSpec)
    }
}

public class FileTypeSpec : Spec, SpecType, @unchecked Sendable {
    class public override var typeName: String {
        return "FileType"
    }
    class public override var subregistryName: String {
        return "FileType"
    }

    /// Returns `true` if this file type represents a bundle.
    public let isBundle: Bool

    /// Returns `true` if this file type represents a framework.
    public let isFramework: Bool

    /// The extensions matched by this file type.
    public let extensions: Set<String>

    /// The language dialect, suitable for passing to clang via its `-x` option.  This will be `nil` if the file type does not define the language dialect.
    public let languageDialect: GCCCompatibleLanguageDialect?

    /// Whether a file of this type can be embedded in a product. For example: frameworks, xpc services, and app extensions.
    public let isEmbeddableInProduct: Bool

    /// Whether a file of this type should be code signed after being copied.
    public let codeSignOnCopy: Bool

    /// Whether a file of this type should be validated after being copied.
    public let validateOnCopy: Bool

    /// Returns `true` if the `isWrapperFolder` value is set in the XCSpec for the file spec.
    public let isWrapper: Bool

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        let basedOnFileTypeSpec = basedOnSpec as? FileTypeSpec ?? nil

        self.isBundle = parser.parseBool("IsBundle") ?? basedOnFileTypeSpec?.isBundle ?? false
        self.isFramework = parser.parseBool("IsFrameworkWrapper") ?? basedOnFileTypeSpec?.isFramework ?? false

        self.extensions = Set<String>(parser.parseStringList("Extensions") ?? [])

        if let gccDialectName = parser.parseString("GccDialectName"), !gccDialectName.isEmpty {
            self.languageDialect = GCCCompatibleLanguageDialect(dialectName: gccDialectName)
        } else {
            self.languageDialect = nil
        }

        self.isEmbeddableInProduct = parser.parseBool("IsEmbeddable") ?? false
        self.validateOnCopy = parser.parseBool("ValidateOnCopy") ?? false
        self.codeSignOnCopy = parser.parseBool("CodeSignOnCopy") ?? false

        self.isWrapper = parser.parseBool("IsWrapperFolder") ?? false

        // Parse and ignore keys we have no use for.
        //
        // FIXME: Eliminate any of these fields which are unused.
        parser.parseBool("AppliesToBuildRules")
        parser.parseObject("BuildPhaseInjectionsWhenEmbedding")
        parser.parseBool("CanSetIncludeInIndex")
        parser.parseBool("ChangesCauseDependencyGraphInvalidation")
        parser.parseObject("ComponentParts")
        parser.parseString("ComputerLanguage")
        parser.parseBool("ContainsNativeCode")
        parser.parseStringList("ExtraPropertyNames")
        parser.parseString("FallbackAutoroutingBuildPhase")
        parser.parseBool("IncludeInIndex")
        parser.parseBool("IsApplication")
        parser.parseBool("IsBuildPropertiesFile")
        parser.parseBool("IsDocumentation")
        parser.parseBool("IsDynamicLibrary")
        parser.parseBool("IsExecutable")
        parser.parseBool("IsExecutableWithGUI")
        parser.parseBool("IsFolder")
        parser.parseBool("IsLibrary")
        parser.parseBool("IsPreprocessed")
        parser.parseBool("IsProjectWrapper")
        parser.parseBool("IsScannedForIncludes")
        parser.parseBool("IsSourceCode")
        parser.parseBool("IsStaticLibrary")
        parser.parseBool("IsStaticFrameworkWrapper")
        parser.parseBool("IsSwiftSourceCode")
        parser.parseBool("IsTargetWrapper")
        parser.parseBool("IsTextFile")
        parser.parseBool("IsTransparent")
        parser.parseStringList("FilenamePatterns")
        parser.parseString("Language")
        parser.parseObject("MagicWord")
        parser.parseStringList("MIMETypes")
        parser.parseString("Permissions")
        parser.parseString("PlistStructureDefinition")
        parser.parseStringList("Prefix")
        parser.parseBool("RemoveHeadersOnCopy")
        parser.parseBool("RequiresHardTabs")
        parser.parseString("UTI")
        parser.parseStringList("TypeCodes")

        super.init(parser, basedOnSpec)
    }
}

public final class PackageTypeSpec : Spec, SpecType, @unchecked Sendable {
    class public override var typeName: String {
        return "PackageType"
    }
    class public override var subregistryName: String {
        return "PackageType"
    }

    /// The default build settings to use for this package type.
    @_spi(Testing) public let buildSettings: MacroValueAssignmentTable
    /// The file type of the product reference produced by targets with this package type.
    @_spi(Testing) public let productReferenceFileTypeIdentifier: String?

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        // Get the build settings and merge with those from the base spec.
        var buildSettings = parser.parseRequiredBuildSettings("DefaultBuildSettings", baseSettings: (basedOnSpec as? PackageTypeSpec)?.buildSettings)

        // Add the PACKAGE_TYPE setting to the default settings.
        buildSettings.push(BuiltinMacros.PACKAGE_TYPE, literal: parser.proxy.identifier)

        self.buildSettings = buildSettings

        // Parse the info about the product reference produced by targets with this package type.
        var prFileTypeIdent: String? = nil
        if let productRefPlist = parser.parseObject("ProductReference") {
            if case .plDict(let productRefDict) = productRefPlist {
                if let fileTypeIdent = productRefDict["FileType"] {
                    if case .plString(let value) = fileTypeIdent {
                        prFileTypeIdent = value
                    }
                }
                // TODO: Product reference name
                // TODO: Product reference 'is launchable'
            }
        }
        productReferenceFileTypeIdentifier = prFileTypeIdent

        super.init(parser, basedOnSpec)
    }

    /// Structure which encapsulates information about a product directory which we might want to create early in building a target.
    public struct ProductStructureDirectoryInfo: Sendable {
        public let buildSetting: PathMacroDeclaration
        public let dontCreateIfProducedByAnotherTask: Bool

        public init(_ buildSetting: PathMacroDeclaration, dontCreateIfProducedByAnotherTask: Bool = true) {
            self.buildSetting = buildSetting
            self.dontCreateIfProducedByAnotherTask = dontCreateIfProducedByAnotherTask
        }
    }

    /// Build settings to evaluate to determine the directory paths for the product structure.  These are all relative to $(TARGET_BUILD_DIR).
    ///
    /// This array is ordered from what should be the highest directory to the lowest, so that if multiple settings would create the same directory, we prefer to create it using a particular setting.
    public static let productStructureDirectories = [
        ProductStructureDirectoryInfo(BuiltinMacros.WRAPPER_NAME, dontCreateIfProducedByAnotherTask: false),
        ProductStructureDirectoryInfo(BuiltinMacros.CONTENTS_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.VERSIONS_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.EXECUTABLE_FOLDER_PATH),
        // EXECUTABLES_FOLDER_PATH appears to be unused
        ProductStructureDirectoryInfo(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH),
        // LOCALIZED_RESOURCES_FOLDER_PATH appears to be unused
        ProductStructureDirectoryInfo(BuiltinMacros.FRAMEWORKS_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.PLUGINS_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.EXTENSIONS_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.PRIVATE_HEADERS_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.PUBLIC_HEADERS_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.SCRIPTS_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.SHARED_FRAMEWORKS_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.SHARED_SUPPORT_FOLDER_PATH),
        ProductStructureDirectoryInfo(BuiltinMacros.XPCSERVICES_FOLDER_PATH),
    ]
}

public final class PlatformSpec : Spec, SpecType, @unchecked Sendable {
    class public override var typeName: String {
        return "Platform"
    }
    class public override var subregistryName: String {
        return "Platform"
    }
}

public final class BuildSettingsSpec : PropertyDomainSpec, SpecType, @unchecked Sendable {
    class public override var typeName: String {
        return "BuildSettings"
    }
}

public final class BuildSystemSpec : PropertyDomainSpec, SpecType, @unchecked Sendable {
    class public override var typeName: String {
        return "BuildSystem"
    }
    class public override var subregistryName: String {
        return "BuildSystem"
    }
}

public final class BuildPhaseSpec : Spec, SpecType, @unchecked Sendable {
    class public override var typeName: String {
        return "BuildPhase"
    }
    class public override var subregistryName: String {
        return "BuildPhase"
    }
}
