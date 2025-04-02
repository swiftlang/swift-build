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

public class ProductTypeSpec : Spec, SpecType, @unchecked Sendable {
    /// The level to elevate the deprecation message as.
    public enum DeprecationLevel {
        case warning
        case error

        /// Provides a conversion for the deprecation level, returning `nil` when no value matches a given level.
        init?(level: String) {
            switch level.lowercased() {
            case "warning": self = .warning
            case "error": self = .error
            default: return nil
            }
        }
    }

    /// The information for the deprecation of the product type.
    public struct DeprecationInfo {
        /// The additional reason provided for deprecation. This is surfaced to the user.
        @_spi(Testing) public let reason: String

        /// The level in which the deprecation should be reported.
        @_spi(Testing) public let level: DeprecationLevel
    }

    class public override var typeName: String {
        return "ProductType"
    }
    class public override var subregistryName: String {
        return "ProductType"
    }

    /// Provides defaults below project/target settings. Contains BasedOn spec's settings as well.
    @_spi(Testing) public let buildSettings: MacroValueAssignmentTable

    /// Overrides project/target settings. Contains BasedOn spec's settings as well. Private because we provide API via `func overridingBuildSettings`.
    private let overridingBuildSettingsTable: MacroValueAssignmentTable?

    /// The default package type for this product.
    @_spi(Testing) public let defaultPackageTypeIdentifier: String

    /// Whether this product type is a wrapped type.
    public let isWrapper: Bool

    public let hasInfoPlist: Bool?

    /// The runpath search path for the Frameworks directory in this product type, if any.
    public func frameworksRunpathSearchPath(in scope: MacroEvaluationScope) -> Path? {
        if conformsTo(identifier: "com.apple.product-type.application") {
            return scope.evaluate(BuiltinMacros.SHALLOW_BUNDLE)
                ? Path("@executable_path/Frameworks")
                : Path("@executable_path/../Frameworks")
        }
        return nil
    }

    /// Whether this product type supports having compiler sanitizer libraries embedded in it.
    public let canEmbedCompilerSanitizerLibraries: Bool

    /// Whether binaries embedded in products of this type should be validated after they're copied.
    public let validateEmbeddedBinaries: Bool

    /// The identifier of the tool spec to run to validate products of this type.
    public let productValidationToolSpecIdentifier: String?

    public struct BuildPhaseFileRefAddition {
        public let path: MacroStringExpression
        public let regionVariantName: MacroStringExpression
    }

    /// Allows a product type to inject files in build phases
    public let buildPhaseFileRefAdditions: [String: [BuildPhaseFileRefAddition]]

    /// Allows a product type to merge content into the target's Info.plist (if any)
    public let infoPlistAdditions: PropertyListItem?

    /// Allows a product type to provide a default set of entitlements (if any).
    public let defaultEntitlements: PropertyListItem

    /// The information, if any, about the deprecation of the product type.
    public let deprecationInfo: DeprecationInfo?

    public let supportedPlatforms: [String]

    private static let booleanizedInfoPlistKeys = Set([
        "ITSWatchOnlyContainer",
        "LSApplicationIsStickerProvider",
        "LSApplicationLaunchProhibited",
        "XCTContainsUITests",
    ])

    private static let booleanizedEntitlements = Set([
        "com.apple.developer.driverkit",
        "com.apple.developer.on-demand-install-capable",
    ])

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        // Get the build settings and merge with those from the base spec.
        //
        // FIXME: Rename this to DefaultBuildSettings for consistency.
        buildSettings = parser.parseRequiredBuildSettings("DefaultBuildProperties", baseSettings: (basedOnSpec as? ProductTypeSpec)?.buildSettings)
        overridingBuildSettingsTable = parser.parseBuildSettings("OverridingBuildSettings", baseSettings: (basedOnSpec as? ProductTypeSpec)?.overridingBuildSettingsTable)

        let packageTypes = parser.parseRequiredStringList("PackageTypes")
        if packageTypes.count >= 1 {
            defaultPackageTypeIdentifier = packageTypes[0]
        } else {
            parser.error("at least one entry for 'PackageTypes' must be defined")
            defaultPackageTypeIdentifier = "com.apple.package-type.wrapper"
        }

        isWrapper = parser.parseBool("IsWrapper") ?? false
        hasInfoPlist = parser.parseBool("HasInfoPlist")

        self.canEmbedCompilerSanitizerLibraries = parser.parseBool("CanEmbedCompilerSanitizerLibraries") ?? false
        self.validateEmbeddedBinaries = parser.parseBool("ValidateEmbeddedBinaries") ?? false

        // Parse the 'Validation' structure in the product type spec, if there is one.
        var productValidationToolSpecIdentifier: String? = nil
        if case .plDict(let plist)? = parser.parseObject("Validation") {
            if let specIdItem = plist["ValidationToolSpec"] {
                if case .plString(let specId) = specIdItem {
                    productValidationToolSpecIdentifier = specId
                }
                else {
                    parser.error("Value for 'ValidationToolSpec' in the 'Validation' dictionary for product type '\(parser.proxy.identifier)' must be a string but is: \(specIdItem)")
                }
            }

            // We skip the 'Checks' key, since it is apparently unused.  The one definition of it in existing specs will never do anything.
        }
        self.productValidationToolSpecIdentifier = productValidationToolSpecIdentifier

        self.buildPhaseFileRefAdditions = { () -> [String: [BuildPhaseFileRefAddition]]? in
            let keyPath = "BuildPhaseFileRefAdditions"
            guard let item = parser.parseObject(keyPath) else { return nil }
            guard case .plDict(let dict) = item else { parser.error("Expected dict in \(keyPath)"); return nil }
            var result = [String: [BuildPhaseFileRefAddition]](minimumCapacity: dict.count)

            for (identifier, valuesPL) in dict {
                let phaseKeyPath = "\(keyPath)['\(identifier)']"
                guard case .plArray(let valuesArray) = valuesPL else { parser.error("Expected array in \(phaseKeyPath)"); return nil }
                var resultValues = [BuildPhaseFileRefAddition]()

                for (index, valuePL) in valuesArray.enumerated() {
                    let fileKeyPath = "\(phaseKeyPath)['\(identifier)'][\(index)]"
                    guard case .plDict(let valueDict) = valuePL else {
                        parser.error("Expected dict in \(fileKeyPath), but got \(valuesPL)")
                        return nil
                    }

                    // Path must be present and must be a string
                    guard case .plString(let path)? = valueDict["Path"] else {
                        parser.error("Expected string in \(fileKeyPath)['Path']")
                        return nil
                    }

                    // RegionVariantName must be a non-empty string if it is present, if it is missing this indicates non-localized content
                    let regionVariantName: String? = {
                        guard let regionVariantNamePL = valueDict["RegionVariantName"] else {
                            return nil
                        }
                        guard case .plString(let regionVariantName) = regionVariantNamePL, !regionVariantName.isEmpty else {
                            parser.warning("Expected non-empty string in \(fileKeyPath)['RegionVariantName']")
                            return nil
                        }
                        return regionVariantName
                    }()

                    resultValues.append(BuildPhaseFileRefAddition(path: BuiltinMacros.namespace.parseString(path), regionVariantName: BuiltinMacros.namespace.parseString(regionVariantName ?? "")))
                }

                result[identifier] = resultValues
            }

            return result
            }() ?? [:]

        self.infoPlistAdditions = parser.parseObject("InfoPlistAdditions")?.withConcreteBooleans(forKeys: ProductTypeSpec.booleanizedInfoPlistKeys)

        self.defaultEntitlements = parser.parseObject("DefaultEntitlements")?.withConcreteBooleans(forKeys: ProductTypeSpec.booleanizedEntitlements) ?? .plDict([:])

        // !!!owensd:20180706 - PBX uses `DeprecationReason` to deprecate a given product type.
        self.deprecationInfo = {
            if let reason = parser.parseString("DeprecationReason") {
                // Having no `DeprecationLevel` is fine and in that case, the default should be 'warning'. However, an invalid value is not allowed.
                let parsedLevel = parser.parseString("DeprecationLevel") ?? "warning"
                if let level = DeprecationLevel(level: parsedLevel) {
                    return DeprecationInfo(reason: reason, level: level)
                }
                else {
                    parser.error("invalid 'DeprecationLevel' value of '\(parsedLevel)'")
                }
            }
            // If the spec has `DeprecationLevel` set without `DeprecationReason`, this is a spec error and we should notify the author.
            else if parser.parseString("DeprecationLevel") != nil {
                parser.error("expected 'DeprecationReason' if key 'DeprecationLevel' is used.")
            }

            return nil
        }()

        self.supportedPlatforms = parser.parseStringList("Platforms") ?? []

        // Parse and ignore keys we have no use for.
        //
        // FIXME: Eliminate any of these fields which are unused.
        parser.parseBool("AddWatchCompanionRequirement")
        parser.parseBool("AllowEmbedding")
        parser.parseObject("AllowedFileTypes")
        parser.parseObject("AllowedBuildPhases")
        parser.parseBool("AlwaysPerformSeparateStrip")
        parser.parseBool("CanEmbedAddressSanitizerLibraries")
        parser.parseBool("DisableSchemeAutocreation")
        parser.parseBool("HasInfoPlistStrings")
        parser.parseBool("IsBundleIdentifierRequired")
        parser.parseBool("IsCapabilitiesUnsupported")
        parser.parseBool("IsEmbeddable")
        parser.parseBool("IsJava")
        parser.parseBool("RunsOnProxy")
        parser.parseBool("SupportsZeroLink")
        parser.parseBool("WantsBundleIdentifierEditing")
        parser.parseBool("WantsGeneralTargetEditingOnly")
        parser.parseBool("WantsInfoEditorHidden")
        parser.parseBool("WantsSigningEditing")
        parser.parseBool("WantsSimpleTargetEditing")
        parser.parseBool("WantsSimpleTargetEditingWithoutCapabilities")
        parser.parseObject("BuildPhaseInjectionsWhenEmbedding")
        parser.parseString("DefaultTargetName")
        parser.parseString("IconNamePrefix")
        parser.parseString("RequiredBuiltProductsDir")
        // These unit test keys are used both by the legacy OCUnit test spec, and the more modern unit and UI test specs.
        parser.parseBool("IsUITest")
        parser.parseBool("IsMultiDeviceUITest")
        parser.parseBool("IsUnitTest")
        parser.parseBool("IsExternalTest")
        parser.parseBool("SupportsHostingTests")
        parser.parseBool("SupportsBeingUITestTarget")

        super.init(parser, basedOnSpec)
    }

    public func additionalArgs(for toolSpec: CommandLineToolSpec) -> [String] {
        return []
    }

    /// Computes and returns additional arguments to pass to the linker appropriate for the product type.  Also returns a list of additional paths to treat as inputs to the link command, if appropriate.
    func computeAdditionalLinkerArgs(_ producer: any CommandProducer, scope: MacroEvaluationScope) -> (args: [String], inputs: [Path]) {
        return ([], [])
    }

    fileprivate func computeDylibArgs(_ producer: any CommandProducer, _ scope: MacroEvaluationScope) -> [String] {
        var args = [String]()

        if producer.isApplePlatform {
            let compatibilityVersion = scope.evaluate(BuiltinMacros.DYLIB_COMPATIBILITY_VERSION)
            if !compatibilityVersion.isEmpty {
                switch scope.evaluate(BuiltinMacros.LINKER_DRIVER) {
                case .clang:
                    args += ["-compatibility_version", compatibilityVersion]
                case .swiftc:
                    args += ["-Xlinker", "-compatibility_version", "-Xlinker", compatibilityVersion]
                }
            }

            let currentVersion = scope.evaluate(BuiltinMacros.DYLIB_CURRENT_VERSION)
            if !currentVersion.isEmpty {
                switch scope.evaluate(BuiltinMacros.LINKER_DRIVER) {
                case .clang:
                    args += ["-current_version", currentVersion]
                case .swiftc:
                    args += ["-Xlinker", "-current_version", "-Xlinker", currentVersion]
                }
            }
        }

        return args
    }

    public func productStructureSymlinkDescriptors(_ scope: MacroEvaluationScope) -> Set<SymlinkDescriptor> {
        return []
    }

    /// Returns whether the product type supports InstallAPI.
    ///
    /// This does not necessarily indicate that the target will create tasks to run `tapi` and produce TBD files, as that is further constrained by the target's `MACH_O_TYPE` and other build settings.
    ///
    /// In particular, Swift compilation runs during InstallAPI builds even when building static libraries, but only generates TBD files when building dylibs.
    public var supportsInstallAPI: Bool {
        return ProductTypeIdentifier(identifier).supportsInstallAPI
    }

    public var supportsEagerLinking: Bool {
        return ProductTypeIdentifier(identifier).supportsEagerLinking
    }

    /// Returns whether the product type supports Swift ABI checker.
    public var supportsSwiftABIChecker: Bool {
        return false
    }

    /// Returns whether the product type supports generating a module map file.
    public var supportsGeneratingModuleMap: Bool {
        // Most product types don't support generating module maps.
        return false
    }

    /// Returns whether the product type supports embedding Swift standard libraries inside it.
    public var supportsEmbeddingSwiftStandardLibraries: Bool {
        // Most product types don't support having the Swift libraries embedded in them.
        return false
    }

    /// Returns whether the product type only compiles in "preferred" asset types when building for Mac Catalyst 14.0 or later.
    public var onlyPreferredAssets: Bool {
        return false
    }

    /// Returns whether the product type supports defining a module.
    /// If a product type doesn't return `true` for this property then enabling `DEFINES_MODULE` has no
    /// effect on passing the `PRODUCT_MODULE_NAME` into code generators such as `intentbuilderc`.
    public var supportsDefinesModule: Bool {
        return false
    }

    /// Returns whether the product type's target should be configured as a mergeable library (have `MERGEABLE_LIBRARY` set in target specialization) if an merged binary target depends on it, as part of superimposed properties in `DependencyResolver`.
    public func autoConfigureAsMergeableLibrary(_ scope: MacroEvaluationScope) -> Bool {
        return false
    }

    /// Returns the default entitlements to use for this product type.
    public func productTypeEntitlements(_ scope: MacroEvaluationScope, platform: Platform?, fs: any FSProxy) throws -> PropertyListItem {
        return defaultEntitlements
    }

    /// Computes additional build settings to be added as overrides to a `Settings` object being constructed.
    public func overridingBuildSettings(_ scope: MacroEvaluationScope, platform: Platform?) -> (table: MacroValueAssignmentTable?, warnings: [String], errors: [String]) {
        return (overridingBuildSettingsTable, [], [])
    }

    public func validate(provisioning: ProvisioningTaskInputs) -> (warnings: [String], errors: [String]) {
        return ([], [])
    }
}


// MARK: Bundle product types


public class BundleProductTypeSpec : ProductTypeSpec, SpecClassType, @unchecked Sendable {
    public class var className: String {
        return "PBXBundleProductType"
    }

    // autoConfigureAsMergeableLibrary() is not overridden here: Even if its MACH_O_TYPE has been changed to 'mh_dylib', automatically building a generic bundle as mergeable is outside what we want to handle automatically.  (We might change our mind in the future.)

    // This was originally implemented in an extension in InfoPlistTaskProducer.swift for rdar://78512102, but it has been adopted in other places so has been moved here.  It might be that this logic doesn't even belong on this class.
	public static func validateBuildComponents(_ buildComponents: [String], scope: MacroEvaluationScope) -> Bool
	{
		return buildComponents.contains("build") || (buildComponents.contains("installLoc") && scope.evaluate(BuiltinMacros.INSTALLLOC_LANGUAGE).isEmpty) || buildComponents.contains("exportLoc")
	}
}

public final class ApplicationProductTypeSpec : BundleProductTypeSpec, @unchecked Sendable {
    class public override var className: String {
        return "PBXApplicationProductType"
    }

    public override var supportsEmbeddingSwiftStandardLibraries: Bool {
        return true
    }

    public override var onlyPreferredAssets: Bool {
        return true
    }

    public override func validate(provisioning: ProvisioningTaskInputs) -> (warnings: [String], errors: [String]) {
        var (warnings, errors) = super.validate(provisioning: provisioning)
        if conformsTo(identifier: "com.apple.product-type.application.on-demand-install-capable") {
            if provisioning.isEnterpriseTeam == true {
                warnings.append("App Clips are not supported when signing with an enterprise team.")
            }
        }
        return (warnings, errors)
    }
}

public final class ApplicationExtensionProductTypeSpec: BundleProductTypeSpec, @unchecked Sendable {
    public override class var className: String {
        return "PBXApplicationExtensionProductType"
    }
}

public class FrameworkProductTypeSpec : BundleProductTypeSpec, @unchecked Sendable {
    class public override var className: String {
        return "PBXFrameworkProductType"
    }

    public override var supportsSwiftABIChecker: Bool {
        return true
    }

    public override var supportsDefinesModule: Bool {
        return true
    }

    // FIXME: Once we have build setting operators, we can replace this function which creates the descriptors in code with the version below which computes a static array and defers evaluation to when the caller desires.
    // FIXME: This should really be part of the package type spec, not the product type spec.
    override public func productStructureSymlinkDescriptors(_ scope: MacroEvaluationScope) -> Set<SymlinkDescriptor> {
        var descriptors = Set<SymlinkDescriptor>()

        let wrapperFolderPath = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR).normalize().join(scope.evaluate(BuiltinMacros.WRAPPER_NAME))
        let versionFolderName = Path(Path(scope.evaluateAsString(BuiltinMacros.VERSIONS_FOLDER_PATH)).basename)
        let frameworkVersionFolderPath = versionFolderName.join(scope.evaluateAsString(BuiltinMacros.FRAMEWORK_VERSION))
        let currentVersionFolderPath = versionFolderName.join(scope.evaluateAsString(BuiltinMacros.CURRENT_VERSION))

        // Versions/Current -> A
        descriptors.insert(
            SymlinkDescriptor(
                location: wrapperFolderPath.join(currentVersionFolderPath),
                toPath: Path(scope.evaluateAsString(BuiltinMacros.FRAMEWORK_VERSION)),
                effectiveToPath: nil
            ) )
        // Resources -> Versions/Current/Resources
        let unlocalizedResourcesFolderName = Path(scope.evaluateAsString(BuiltinMacros.UNLOCALIZED_RESOURCES_FOLDER_PATH)).basename
        descriptors.insert(
            SymlinkDescriptor(
            	location: wrapperFolderPath.join(unlocalizedResourcesFolderName),
                toPath: currentVersionFolderPath.join(unlocalizedResourcesFolderName),
                effectiveToPath: frameworkVersionFolderPath.join(unlocalizedResourcesFolderName)
            ) )
        // Headers -> Versions/Current/Headers
        let headersResourcesFolderName = Path(scope.evaluateAsString(BuiltinMacros.PUBLIC_HEADERS_FOLDER_PATH)).basename
        descriptors.insert(
            SymlinkDescriptor(
            	location: wrapperFolderPath.join(headersResourcesFolderName),
                toPath: currentVersionFolderPath.join(headersResourcesFolderName),
                effectiveToPath: frameworkVersionFolderPath.join(headersResourcesFolderName)
            ) )
        // PrivateHeaders -> Versions/Current/PrivateHeaders
        let privateHeadersFolderName = Path(scope.evaluateAsString(BuiltinMacros.PRIVATE_HEADERS_FOLDER_PATH)).basename
        descriptors.insert(
            SymlinkDescriptor(
            	location: wrapperFolderPath.join(privateHeadersFolderName),
                toPath: currentVersionFolderPath.join(privateHeadersFolderName),
                effectiveToPath: frameworkVersionFolderPath.join(privateHeadersFolderName)
            ) )
        // Modules -> Versions/Current/Modules
        let modulesFolderName = Path(scope.evaluateAsString(BuiltinMacros.MODULES_FOLDER_PATH)).basename
        descriptors.insert(
            SymlinkDescriptor(
            	location: wrapperFolderPath.join(modulesFolderName),
                toPath: currentVersionFolderPath.join(modulesFolderName),
                effectiveToPath: frameworkVersionFolderPath.join(modulesFolderName)
            ) )
        // Frameworks -> Versions/Current/Frameworks
        let frameworksFolderName = Path(scope.evaluateAsString(BuiltinMacros.FRAMEWORKS_FOLDER_PATH)).basename
        descriptors.insert(
            SymlinkDescriptor(
                location: wrapperFolderPath.join(frameworksFolderName),
                toPath: currentVersionFolderPath.join(frameworksFolderName),
                effectiveToPath: frameworkVersionFolderPath.join(frameworksFolderName)
            ) )
        // PlugIns -> Versions/Current/PlugIns
        let pluginsFolderName = Path(scope.evaluateAsString(BuiltinMacros.PLUGINS_FOLDER_PATH)).basename
        descriptors.insert(
            SymlinkDescriptor(
            	location: wrapperFolderPath.join(pluginsFolderName),
                toPath: currentVersionFolderPath.join(pluginsFolderName),
                effectiveToPath: frameworkVersionFolderPath.join(pluginsFolderName)
            ) )
        // Extensions -> Versions/Current/Extensions
        let extensionsFolderName = Path(scope.evaluateAsString(BuiltinMacros.EXTENSIONS_FOLDER_PATH)).basename
        descriptors.insert(
            SymlinkDescriptor(
                location: wrapperFolderPath.join(extensionsFolderName),
                toPath: currentVersionFolderPath.join(extensionsFolderName),
                effectiveToPath: frameworkVersionFolderPath.join(extensionsFolderName)
            ) )
        // <binary-name> -> Versions/Current/<binary-name>
        let executableName = scope.evaluateAsString(BuiltinMacros.EXECUTABLE_NAME)
        descriptors.insert(
            SymlinkDescriptor(
            	location: wrapperFolderPath.join(executableName),
                toPath: currentVersionFolderPath.join(executableName),
                effectiveToPath: frameworkVersionFolderPath.join(executableName)
            ) )
        // XPCServices -> Versions/Current/XPCServices
        let xpcServicesFolderName = Path(scope.evaluateAsString(BuiltinMacros.XPCSERVICES_FOLDER_PATH)).basename
        descriptors.insert(
            SymlinkDescriptor(
            	location: wrapperFolderPath.join(xpcServicesFolderName),
                toPath: currentVersionFolderPath.join(xpcServicesFolderName),
                effectiveToPath: frameworkVersionFolderPath.join(xpcServicesFolderName)
            ) )
        // ExtraModules -> Versions/Current/ExtraModules
        if scope.evaluate(BuiltinMacros.BUILD_PACKAGE_FOR_DISTRIBUTION) {
            descriptors.insert(
                SymlinkDescriptor(
                    location: wrapperFolderPath.join("ExtraModules"),
                    toPath: currentVersionFolderPath.join("ExtraModules"),
                    effectiveToPath: frameworkVersionFolderPath.join("ExtraModules")
                ) )
        }

        return descriptors
    }

/*
    /// Build setting expressions to evaluate to determine how to create symbolic links for the product structure.
    static let productStructureSymlinkBuildSettings = [SymlinkDescriptor]([
        // Versions/Current -> A
        SymlinkDescriptor(
            location: BuiltinMacros.namespace.parseString("$(TARGET_BUILT_DIR)/$(WRAPPER_NAME)/$(VERSIONS_PATH)/$(CURRENT_VERSION)"),
            toPath: BuiltinMacros.namespace.parseString("$(FRAMEWORK_VERSION)")),
        // Resources -> Versions/Current/Resources
        SymlinkDescriptor(
            location: BuiltinMacros.namespace.parseString("$(TARGET_BUILT_DIR)/$(WRAPPER_NAME)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH:file)"),
            toPath: BuiltinMacros.namespace.parseString("$(VERSIONS_PATH)/$(CURRENT_VERSION)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH:file)")),
        // Headers -> Versions/Current/Headers
        SymlinkDescriptor(
            location: BuiltinMacros.namespace.parseString("$(TARGET_BUILT_DIR)/$(WRAPPER_NAME)/$(PUBLIC_HEADERS_FOLDER_PATH:file)"),
            toPath: BuiltinMacros.namespace.parseString("$(VERSIONS_PATH)/$(CURRENT_VERSION)/$(PUBLIC_HEADERS_FOLDER_PATH:file)")),
        // PrivateHeaders -> Versions/Current/PrivateHeaders
        SymlinkDescriptor(
            location: BuiltinMacros.namespace.parseString("$(TARGET_BUILT_DIR)/$(WRAPPER_NAME)/$(PRIVATE_HEADERS_FOLDER_PATH:file)"),
            toPath: BuiltinMacros.namespace.parseString("$(VERSIONS_PATH)/$(CURRENT_VERSION)/$(PRIVATE_HEADERS_FOLDER_PATH:file)")),
        // Modules -> Versions/Current/Modules
        SymlinkDescriptor(
     location: BuiltinMacros.namespace.parseString("$(TARGET_BUILT_DIR)/$(WRAPPER_NAME)/$(MODULES_FOLDER_PATH:file)"),
            toPath: BuiltinMacros.namespace.parseString("$(VERSIONS_PATH)/$(CURRENT_VERSION)/$(MODULES_FOLDER_PATH:file)")),
        // PlugIns -> Versions/Current/PlugIns
        SymlinkDescriptor(
            location: BuiltinMacros.namespace.parseString("$(TARGET_BUILT_DIR)/$(WRAPPER_NAME)/$(PLUGINS_FOLDER_PATH:file)"),
            toPath: BuiltinMacros.namespace.parseString("$(VERSIONS_PATH)/$(CURRENT_VERSION)/$(PLUGINS_FOLDER_PATH:file)")),
        // Extensions -> Versions/Current/Extensions
        SymlinkDescriptor(
            location: BuiltinMacros.namespace.parseString("$(TARGET_BUILT_DIR)/$(WRAPPER_NAME)/$(EXTENSIONS_FOLDER_PATH:file)"),
            toPath: BuiltinMacros.namespace.parseString("$(VERSIONS_PATH)/$(CURRENT_VERSION)/$(EXTENSIONS_FOLDER_PATH:file)")),
        // <binary-name> -> Versions/Current/<binary-name>
        SymlinkDescriptor(
            location: BuiltinMacros.namespace.parseString("$(TARGET_BUILT_DIR)/$(WRAPPER_NAME)/$(EXECUTABLE_NAME)"),
            toPath: BuiltinMacros.namespace.parseString("$(VERSIONS_PATH)/$(CURRENT_VERSION)/$(EXECUTABLE_NAME)")),
        // XPCServices -> Versions/Current/XPCServices
        SymlinkDescriptor(
            location: BuiltinMacros.namespace.parseString("$(TARGET_BUILT_DIR)/$(WRAPPER_NAME)/$(XPCSERVICES_FOLDER_PATH:file)"),
            toPath: BuiltinMacros.namespace.parseString("$(VERSIONS_PATH)/$(CURRENT_VERSION)/$(XPCSERVICES_FOLDER_PATH:file)")),
    ])
*/

    override func computeAdditionalLinkerArgs(_ producer: any CommandProducer, scope: MacroEvaluationScope) -> (args: [String], inputs: [Path]) {
        if scope.evaluate(BuiltinMacros.MACH_O_TYPE) != "staticlib" {
            return (computeDylibArgs(producer, scope), [])
        }
        return ([], [])
    }

    /// Returns whether the product type supports generating a module map file.
    public override var supportsGeneratingModuleMap: Bool {
        return true
    }

    public override func autoConfigureAsMergeableLibrary(_ scope: MacroEvaluationScope) -> Bool {
        return scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_dylib"
    }
}

public final class StaticFrameworkProductTypeSpec : FrameworkProductTypeSpec, @unchecked Sendable {
    class public override var className: String {
        return "XCStaticFrameworkProductType"
    }
}

public final class KernelExtensionProductTypeSpec : BundleProductTypeSpec, @unchecked Sendable {
    class public override var className: String {
        return "XCKernelExtensionProductType"
    }
}

/// The product type for XCTest unit and UI test bundles.
public final class XCTestBundleProductTypeSpec : BundleProductTypeSpec, @unchecked Sendable {
    class public override var className: String {
        return "PBXXCTestBundleProductType"
    }

    required init(_ parser: SpecParser, _ basedOnSpec: Spec?) {
        super.init(parser, basedOnSpec)
    }

    public override var supportsEmbeddingSwiftStandardLibraries: Bool {
        return true
    }

    public class func usesXCTRunner(_ scope: MacroEvaluationScope) -> Bool {
        return scope.evaluate(BuiltinMacros.USES_XCTRUNNER)
    }

    public class func usesTestHost(_ scope: MacroEvaluationScope) -> Bool {
        return !scope.evaluate(BuiltinMacros.TEST_HOST).isEmpty && !scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION)
    }

    public class func getPlatformDeveloperVariantLibraryPath(_ scope: MacroEvaluationScope, _ platform: Platform?) -> Path {
        let variantPath = Path(scope.evaluate(BuiltinMacros.TEST_FRAMEWORK_DEVELOPER_VARIANT_SUBPATH))
        return Path(scope.evaluate(BuiltinMacros.PLATFORM_DIR)).join("Developer").join(variantPath).join("Library")
    }

    /// The path to the XCTRunner.app _source_ path which will be copied into the target build dir under a new name.
    public class func testRunnerAppSourcePath(_ scope: MacroEvaluationScope, _ platform: Platform?) -> Path {
        let path = Path(scope.evaluate(BuiltinMacros.XCTRUNNER_PATH))
        if path.isAbsolute {
            return path
        } else if !path.isEmpty {
            return getPlatformDeveloperVariantLibraryPath(scope, platform).join(path)
        } else {
            return getPlatformDeveloperVariantLibraryPath(scope, platform).join("Xcode/Agents/XCTRunner.app")
        }
    }

    public override func productTypeEntitlements(_ scope: MacroEvaluationScope, platform: Platform?, fs: any FSProxy) throws -> PropertyListItem {
        if type(of: self).usesXCTRunner(scope) {
            let testRunnerAppPath = type(of: self).testRunnerAppSourcePath(scope, platform)
            let platformWrapperContentsDir = scope.evaluate(BuiltinMacros._WRAPPER_CONTENTS_DIR)
            let testRunnerResourcePath = scope.evaluate(BuiltinMacros._WRAPPER_RESOURCES_DIR)

            let path = testRunnerAppPath.join(platformWrapperContentsDir, preserveRoot: true).join(testRunnerResourcePath, preserveRoot: true).join("RunnerEntitlements.plist")

            return try PropertyList.fromBytes(fs.read(path).bytes)
        }

        return try super.productTypeEntitlements(scope, platform: platform, fs: fs)
    }

    public override func overridingBuildSettings(_ scope: MacroEvaluationScope, platform: Platform?) -> (table: MacroValueAssignmentTable?, warnings: [String], errors: [String]) {
        var (tableOpt, warnings, errors) = super.overridingBuildSettings(scope, platform: platform)
        var table = tableOpt ?? MacroValueAssignmentTable(namespace: scope.namespace)

        let isDeviceBuild = platform?.isDeploymentPlatform == true && platform?.identifier != "com.apple.platform.macosx"
        if isDeviceBuild {
            // For tests running on devices (not simulators) we always want to generate dSYMs so that symbolication can give file and line information about test failures.
            table.push(BuiltinMacros.DEBUG_INFORMATION_FORMAT, literal: "dwarf-with-dsym")
        }

        // Add to the macro definition table based on how tests are being run (XCTRunner, TEST_HOST, or neither).
        if type(of: self).usesXCTRunner(scope) {
            addXCTRunnerSettings(to: &table, scope, platform, &warnings, &errors)
        }
        else if type(of: self).usesTestHost(scope) {
            addTestHostSettings(to: &table, Path(scope.evaluate(BuiltinMacros.TEST_HOST)), scope, platform, &warnings, &errors)
        }

        return ((table.isEmpty && errors.isEmpty) ? nil : table, warnings, errors)
    }

    /// When `USES_XCTRUNNER` is enabled (which it is by default for UI tests), the test bundle gets built into the `$(PRODUCT_NAME)-Runner.app` bundle.
    private func addXCTRunnerSettings(to table: inout MacroValueAssignmentTable, _ scope: MacroEvaluationScope, _ platform: Platform?, _ warnings: inout [String], _ errors: inout [String]) {
        table.push(BuiltinMacros.XCTRUNNER_PRODUCT_NAME, table.namespace.parseString("$(PRODUCT_NAME)-Runner.app"))

        // Define TARGET_BUILD_SUBPATH so the target builds to $(TARGET_BUILD_DIR)/$(TARGET_BUILD_SUBPATH) (or slightly different for deployment location builds).
        // <rdar://problem/18902931> Should PBXXCTestBundleProductType override BUILT_PRODUCTS_DIR when it overrides TARGET_BUILD_DIR?
        table.push(BuiltinMacros.TARGET_BUILD_SUBPATH, table.namespace.parseString("/$(XCTRUNNER_PRODUCT_NAME)$(_WRAPPER_CONTENTS_DIR)/PlugIns"))
        table.push(BuiltinMacros.DWARF_DSYM_FOLDER_PATH, table.namespace.parseString("$(TARGET_BUILD_DIR)"))        // Do we really want dSYMs to go inside of the host app's PlugIns dir?

        // Entitlements are always required for a UI test target.
        table.push(BuiltinMacros.ENTITLEMENTS_REQUIRED, literal: true)
        // The provisioning profile gets placed in the runner app, not in the test bundle.
        table.push(BuiltinMacros.PROVISIONING_PROFILE_DESTINATION_PATH, table.namespace.parseString("$(TARGET_BUILD_DIR)/.."))
    }

    /// When `TEST_HOST` is set (which, for unit tests being run against an app, it typically is set to the path to the app's binary), the test bundle is built into the `PlugIns` folder of the bundle it's testing.
    private func addTestHostSettings(to table: inout MacroValueAssignmentTable, _ testHost: Path, _ scope: MacroEvaluationScope, _ platform: Platform?, _ warnings: inout [String], _ errors: inout [String]) {
        guard testHost.isAbsolute else {
            errors.append("$(TEST_HOST) is not an absolute path.")
            return
        }
        let targetBuildDir = scope.evaluate(BuiltinMacros.TARGET_BUILD_DIR)
        let testHost = adjustedTestHost(originalTestHost: testHost, addingSettingsToTable: &table, scope)

// This check is disabled due to <rdar://problem/43032765>.  See UnsupportedBehaviorTaskConstructionTests.testOverridingTargetBuildDirInApplicationUnitTestTarget().
//        guard targetBuildDir.isAncestor(of: testHost) else {
//            // TEST_HOST must be inside of TARGET_BUILD_DIR.
//            errors.append("$(TEST_HOST) is not a descendant of $(TARGET_BUILD_DIR) (\(testHost.str) !<= \(targetBuildDir.str))")
//            return
//        }

        // testHost is a path to the executable for the app, we need to strip off the executable to get the contents directory:
        //     ./MacApp.app/Contents/MacOS/MacApp OR
        //     ./iOSApp.app/iOSApp (SHALLOW_BUNDLE)
        let contentsDir = scope.evaluate(BuiltinMacros.SHALLOW_BUNDLE) ? testHost.dirname : testHost.dirname.dirname

        // Append the plugin dir so that test bundles are built to that location.  This path must be a descendant of $(TARGET_BUILD_DIR).
        let modifiedTargetBuildDir = contentsDir.join("PlugIns")
        guard let targetBuildSubpath = modifiedTargetBuildDir.relativeSubpath(from: targetBuildDir) else {
            // It's not clear how we can best guide the user if this fails - it's probably due to a strange project configuration.  But given that the user can set TEST_HOST to anything, we don't want to crash here.
            var pluginsDirRelativeToTestHost = testHost.join("..")
            if !scope.evaluate(BuiltinMacros.SHALLOW_BUNDLE) {
                pluginsDirRelativeToTestHost = pluginsDirRelativeToTestHost.join("..")
            }
            pluginsDirRelativeToTestHost = pluginsDirRelativeToTestHost.join("PlugIns")
            errors.append("could not compute relative build path for TEST_HOST: PlugIns folder relative to $(TEST_HOST) is not a descendant of $(TARGET_BUILD_DIR) (\(pluginsDirRelativeToTestHost.str) !<= \(targetBuildDir.str))")
            return
        }

        // Define TARGET_BUILD_SUBPATH so the target builds to $(TARGET_BUILD_DIR)/$(TARGET_BUILD_SUBPATH) (or slightly different for deployment location builds).
        // <rdar://problem/18902931> Should PBXXCTestBundleProductType override BUILT_PRODUCTS_DIR when it overrides TARGET_BUILD_DIR?
        table.push(BuiltinMacros.TARGET_BUILD_SUBPATH, table.namespace.parseLiteralString("/\(targetBuildSubpath)"))
        table.push(BuiltinMacros.DWARF_DSYM_FOLDER_PATH, table.namespace.parseString("$(TARGET_BUILD_DIR)"))

        table.push(BuiltinMacros._BUILDABLE_SERIALIZATION_KEY, literal: "test-bundle-with-host: \(testHost)")

        // Inject a runpath search path to the host app's Frameworks directory if it isn't already present to ensure the embedded libraries can be found
        let applicationProductType: ProductTypeSpec? = try? platform?.specRegistryProvider.specRegistry.getSpec("com.apple.product-type.application", domain: platform?.name ?? "")
        if let frameworksRunpath = applicationProductType?.frameworksRunpathSearchPath(in: scope)?.str {
            if !scope.evaluate(BuiltinMacros.LD_RUNPATH_SEARCH_PATHS).contains(frameworksRunpath) {
                table.push(BuiltinMacros.LD_RUNPATH_SEARCH_PATHS, BuiltinMacros.namespace.parseStringList(["$(inherited)", frameworksRunpath]))
            }
        }
    }

    private func adjustedTestHost(originalTestHost testHost: Path, addingSettingsToTable table: inout MacroValueAssignmentTable, _ scope: MacroEvaluationScope) -> Path {
        // For macCatalyst, we see TEST_HOST build settings generated for an iOS app with a shallow bundle now
        // being evaluated against a platform that uses deep bundles instead. Try to detect this situation and
        // rewrite TEST_HOST (and potentially BUNDLE_LOADER) to match the deep bundle form.

        guard scope.evaluate(BuiltinMacros.SDK_VARIANT) == MacCatalystInfo.sdkVariantName && !scope.evaluate(BuiltinMacros.DISABLE_TEST_HOST_PLATFORM_PROCESSING) else {
            return testHost
        }

        let deepBundleWrapperExecutableDir = "Contents/MacOS"
        if !scope.evaluate(BuiltinMacros.SHALLOW_BUNDLE) && !testHost.dirname.ends(with: deepBundleWrapperExecutableDir) {
            let (testHostExecutableDir, executableName) = testHost.split()
            let (testHostDir, wrapperName) = testHostExecutableDir.split()

            if testHostDir == scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR) {
                // testHost has the common expected form $(BUILT_PRODUCTS_DIR)/$(WRAPPER_NAME)/$(EXECUTABLE_NAME). Rewrite this to the deep bundle form.

                let adjustedTestHostExpression = scope.namespace.parseString("$(BUILT_PRODUCTS_DIR)/\(wrapperName)/\(deepBundleWrapperExecutableDir)/\(executableName)")

                table.push(BuiltinMacros.TEST_HOST, adjustedTestHostExpression)

                if !scope.evaluate(BuiltinMacros.BUNDLE_LOADER).isEmpty {
                    table.push(BuiltinMacros.BUNDLE_LOADER, scope.namespace.parseString("$(TEST_HOST)"))
                }

                return Path(scope.evaluate(adjustedTestHostExpression))
            }
        }

        return testHost
    }
}


// MARK: Standalone binary Product types


public class StandaloneExecutableProductTypeSpec : ProductTypeSpec, SpecClassType, @unchecked Sendable {
    public class var className: String {
        return "XCStandaloneExecutableProductType"
    }
}

public class LibraryProductTypeSpec: StandaloneExecutableProductTypeSpec, @unchecked Sendable {
    public override class var className: String {
        fatalError("This method is a subclass responsibility")
    }

    public override func autoConfigureAsMergeableLibrary(_ scope: MacroEvaluationScope) -> Bool {
        return scope.evaluate(BuiltinMacros.MACH_O_TYPE) == "mh_dylib"
    }
}

public final class DynamicLibraryProductTypeSpec : LibraryProductTypeSpec, @unchecked Sendable {
    class public override var className: String {
        return "PBXDynamicLibraryProductType"
    }

    public override var supportsSwiftABIChecker: Bool {
        return true
    }

    public override var supportsDefinesModule: Bool {
        return true
    }

    override func computeAdditionalLinkerArgs(_ producer: any CommandProducer, scope: MacroEvaluationScope) -> (args: [String], inputs: [Path]) {
        if scope.evaluate(BuiltinMacros.MACH_O_TYPE) != "staticlib" {
            return (computeDylibArgs(producer, scope), [])
        }
        return ([], [])
    }
}

public final class StaticLibraryProductTypeSpec : LibraryProductTypeSpec, @unchecked Sendable {
    class public override var className: String {
        return "PBXStaticLibraryProductType"
    }
    public override var supportsSwiftABIChecker: Bool {
        return true
    }
    public override var supportsDefinesModule: Bool {
        return true
    }
}

public final class ToolProductTypeSpec : StandaloneExecutableProductTypeSpec, @unchecked Sendable {
    class public override var className: String {
        return "PBXToolProductType"
    }
}

/// Describes a symbolic link to create.
public struct SymlinkDescriptor: Hashable
{
    /// Where the symbolic link will be created.  This should evaluate to an absolute path.
    public let location: Path
    /// The path the symbolic link points to.  This may be a relative path.
    public let toPath: Path
    /// The effective path the symbolic link points to, if we know that `toPath` is itself going to go through symbolic links.  This may be a relative path.  This is important for validation of symlink provisional tasks.
    public let effectiveToPath: Path?

    public func hash(into hasher: inout Hasher) {
        hasher.combine(location)
        hasher.combine(toPath)
    }

    public static func ==(lhs: SymlinkDescriptor, rhs: SymlinkDescriptor) -> Bool {
        return lhs.location == rhs.location && lhs.toPath == rhs.toPath
    }
}

// FIXME: Once we support build setting operators, we can use this version instead (and likely can remove the SWBUtil import for this file, since we won't be using Path anymore).
/*
/// Describes a symbolic link to create.
public struct SymlinkDescriptor
{
    /// Where the symbolic link will be created.  This should evaluate to an absolute path.
    public let location: MacroStringExpression
    /// The path the symbolic link points to.  This may be a relative path.
    public let toPath: MacroStringExpression
}
*/
