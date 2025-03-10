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
public import SWBUtil
public import SWBMacro


/// A task action encapsulates concrete work to be done for a task during a build.
///
/// Task actions are primarily used to capture state and execution logic for in-process tasks.
public protocol PlannedTaskAction
{
}

public struct AuxiliaryFileTaskActionContext {
    public struct Diagnostic {
        public enum Kind {
            case error
            case warning
            case note
        }

        public let kind: Kind
        public let message: String

        public init(kind: Kind, message: String) {
            self.kind = kind
            self.message = message
        }
    }

    public let output: Path
    public let input: Path
    public let permissions: Int?
    public let forceWrite: Bool
    public let diagnostics: [Diagnostic]
    public let logContents: Bool

    public init(output: Path, input: Path, permissions: Int?, forceWrite: Bool, diagnostics: [Diagnostic], logContents: Bool) {
        self.output = output
        self.input = input
        self.permissions = permissions
        self.forceWrite = forceWrite
        self.diagnostics = diagnostics
        self.logContents = logContents
    }
}

public protocol InfoPlistProcessorTaskActionContextDeserializerDelegate: DeserializerDelegate, MacroValueAssignmentTableDeserializerDelegate {
    /// The `PlatformRegistry` to use to look up platforms.
    var platformRegistry: PlatformRegistry { get }

    /// The `SDKRegistry` to use to look up SDKs.
    var sdkRegistry: SDKRegistry { get }

    /// The specification registry to use to look up `CommandLineToolSpec`s for deserializing Task.type properties.
    var specRegistry: SpecRegistry { get }
}

public struct InfoPlistProcessorTaskActionContext: PlatformBuildContext, Serializable {
    public var scope: MacroEvaluationScope
    public var productType: ProductTypeSpec?
    public var platform: Platform?
    public var sdk: SDK?
    public var sdkVariant: SDKVariant?
    public var cleanupRequiredArchitectures: [String]
    public var clientLibrariesForCodelessBundle: [String]

    public init(scope: MacroEvaluationScope, productType: ProductTypeSpec?, platform: Platform?, sdk: SDK?, sdkVariant: SDKVariant?, cleanupRequiredArchitectures: [String], clientLibrariesForCodelessBundle: [String] = []) {
        self.scope = scope
        self.productType = productType
        self.platform = platform
        self.sdk = sdk
        self.sdkVariant = sdkVariant
        self.cleanupRequiredArchitectures = cleanupRequiredArchitectures
        self.clientLibrariesForCodelessBundle = clientLibrariesForCodelessBundle
    }

    public var targetBuildVersionPlatforms: Set<BuildVersion.Platform>? {
        targetBuildVersionPlatforms(in: scope)
    }

    public func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(8)
        serializer.serialize(scope)
        serializer.serialize(platform?.identifier)
        serializer.serialize(sdk?.canonicalName)
        serializer.serialize(sdkVariant?.name)
        serializer.serialize(productType?.identifier)
        serializer.serialize(productType?.domain)
        serializer.serialize(cleanupRequiredArchitectures)
        serializer.serialize(clientLibrariesForCodelessBundle)
        serializer.endAggregate()
    }

    public init(from deserializer: any Deserializer) throws
    {
        // Get the platform registry to use to look up the platform from the deserializer's delegate.
        guard let delegate = deserializer.delegate as? (any InfoPlistProcessorTaskActionContextDeserializerDelegate) else { throw DeserializerError.invalidDelegate("delegate must be a BuildDescriptionDeserializerDelegate") }

        try deserializer.beginAggregate(8)
        let scope: MacroEvaluationScope = try deserializer.deserialize()

        let platformIdentifier: String? = try deserializer.deserialize()
        let platform: Platform?
        if let platformIdentifier {
            guard let p = delegate.platformRegistry.lookup(identifier: platformIdentifier) else {
                throw DeserializerError.deserializationFailed("Platform lookup failed for identifier: \(platformIdentifier)")
            }
            platform = p
        }
        else {
            platform = nil
        }

        let sdk: SDK?
        let sdkVariant: SDKVariant?
        if let sdkCanonicalName = try deserializer.deserialize() as String? {
            // We don't need a run destination to resolve the SDK because the serialized name is always a fully-qualified (globally unique) canonical name, not an alias.
            guard let loadedSDK = try delegate.sdkRegistry.lookup(sdkCanonicalName, activeRunDestination: nil) else {
                throw DeserializerError.deserializationFailed("SDK lookup failed for canonical name: \(sdkCanonicalName)")
            }

            if let sdkVariantName = try deserializer.deserialize() as String? {
                guard let loadedSDKVariant = loadedSDK.variant(for: sdkVariantName) else {
                    throw DeserializerError.deserializationFailed("SDK variant lookup failed for name: \(sdkVariantName)")
                }

                sdkVariant = loadedSDKVariant
            } else {
                sdkVariant = nil
            }

            sdk = loadedSDK
        } else {
            sdk = nil
            _ = deserializer.deserializeNil() // skip past SDK variant name
            sdkVariant = nil
        }

        let productTypeIdentifier: String? = try deserializer.deserialize()
        let productTypeDomain: String? = try deserializer.deserialize()

        let productType: ProductTypeSpec? = try {
            if let productTypeIdentifier, let productTypeDomain {
                guard let productType = delegate.specRegistry.getSpec(productTypeIdentifier, domain: productTypeDomain) as? ProductTypeSpec else {
                    throw DeserializerError.deserializationFailed("Product type lookup failed for identifier: \(productTypeIdentifier) in domain \(productTypeDomain)")
                }
                return productType
            }
            return nil
        }()

        let cleanupRequiredArchitectures: [String] = try deserializer.deserialize()
        let clientLibrariesForCodelessBundle: [String] = try deserializer.deserialize()

        self = InfoPlistProcessorTaskActionContext(scope: scope, productType: productType, platform: platform, sdk: sdk, sdkVariant: sdkVariant, cleanupRequiredArchitectures: cleanupRequiredArchitectures, clientLibrariesForCodelessBundle: clientLibrariesForCodelessBundle)
    }
}

public struct FileCopyTaskActionContext {
    public let skipAppStoreDeployment: Bool
    public let stubPartialCompilerCommandLine: [String]
    public let stubPartialLinkerCommandLine: [String]
    public let stubPartialLipoCommandLine: [String]
    public let partialTargetValues: [String]
    public let llvmTargetTripleOSVersion: String
    public let llvmTargetTripleSuffix: String
    public let platformName: String
    public let swiftPlatformTargetPrefix: String
    public let isMacCatalyst: Bool

    public init(skipAppStoreDeployment: Bool, stubPartialCompilerCommandLine: [String], stubPartialLinkerCommandLine: [String], stubPartialLipoCommandLine: [String], partialTargetValues: [String], llvmTargetTripleOSVersion: String, llvmTargetTripleSuffix: String, platformName: String, swiftPlatformTargetPrefix: String, isMacCatalyst: Bool) {
        self.skipAppStoreDeployment = skipAppStoreDeployment
        self.stubPartialCompilerCommandLine = stubPartialCompilerCommandLine
        self.stubPartialLinkerCommandLine = stubPartialLinkerCommandLine
        self.stubPartialLipoCommandLine = stubPartialLipoCommandLine
        self.partialTargetValues = partialTargetValues
        self.llvmTargetTripleOSVersion = llvmTargetTripleOSVersion
        self.llvmTargetTripleSuffix = llvmTargetTripleSuffix
        self.platformName = platformName
        self.swiftPlatformTargetPrefix = swiftPlatformTargetPrefix
        self.isMacCatalyst = isMacCatalyst
    }

    private func minimumSystemVersionKey(for platformName: String) -> String {
        switch platformName {
        case "driverkit":
            return "OSMinimumDriverKitVersion"
        case "macosx":
            return "LSMinimumSystemVersion"
        default:
            return "MinimumOSVersion"
        }
    }

    private enum Errors: LocalizedError {
        case couldNotDetermineDeploymentTarget(frameworkPath: Path, macOSDeploymentTarget: String)

        var errorDescription: String? {
            switch self {
            case .couldNotDetermineDeploymentTarget(let frameworkPath, let macOSDeploymentTarget):
                return "Could not determine corresponding Mac Catalyst deployment target for macOS \(macOSDeploymentTarget) while building stub executable for \(frameworkPath.basename)"
            }
        }
    }

    public func stubCommandLine(frameworkPath: Path, isDeepBundle: Bool, platformRegistry: PlatformRegistry, sdkRegistry: SDKRegistry, tempDir: Path) throws -> (compileAndLink: [(compile: [String], link: [String])], lipo: [String]) {
        let platform = platformRegistry.lookup(name: platformName)
        let bundleSupportedPlatform: String?
        switch platform?.additionalInfoPlistEntries["CFBundleSupportedPlatforms"] as? PropertyListItem {
        case .plArray(let value):
            if let value = value.only /* `CFBundleSupportedPlatforms` is expected to always contain a single value */, case let PropertyListItem.plString(platform) = value {
                bundleSupportedPlatform = platform
            } else {
                bundleSupportedPlatform = nil
            }
        default:
            bundleSupportedPlatform = nil
        }

        let targetTripleOSVersion: String
        if let bundle = Bundle(path: frameworkPath.str), let minVersion = bundle.infoDictionary?[minimumSystemVersionKey(for: platformName)] as? String, let bundleSupportedPlatform, let frameworkBundleSupportedPlatforms = bundle.infoDictionary?["CFBundleSupportedPlatforms"] as? [String], bundleSupportedPlatform == frameworkBundleSupportedPlatforms.only /* `CFBundleSupportedPlatforms` is expected to always contain a single value */ {
            let effectiveMinVersion: String
            // For MacCatalyst, we need to map the minimum version from the original framework to the corresponding iOS one.
            if isMacCatalyst, let version = try? Version(minVersion), let sdkCanonicalName = platform?.sdkCanonicalName, let sdk = try? sdkRegistry.lookup(sdkCanonicalName, activeRunDestination: nil) {
                if let minVersion = sdk.versionMap["macOS_iOSMac"]?[version] {
                    effectiveMinVersion = minVersion.description
                } else {
                    throw Errors.couldNotDetermineDeploymentTarget(frameworkPath: frameworkPath, macOSDeploymentTarget: minVersion)
                }
            } else {
                effectiveMinVersion = minVersion
            }
            // If the framework defines a minimum deployment target, prefer that,
            targetTripleOSVersion = "\(swiftPlatformTargetPrefix)\(effectiveMinVersion)"
        } else {
            // otherwise fallback to the deployment target of the embedding application.
            targetTripleOSVersion = llvmTargetTripleOSVersion
        }

        return (
            compileAndLink: partialTargetValues.map { partialTargetValue in
                    (
                        compile: stubPartialCompilerCommandLine + ["-target", "\(partialTargetValue)-\(targetTripleOSVersion)\(llvmTargetTripleSuffix)", "-o", tempDir.join("\(partialTargetValue).o").str],
                        link: stubPartialLinkerCommandLine + ["-target", "\(partialTargetValue)-\(targetTripleOSVersion)\(llvmTargetTripleSuffix)", "-o", tempDir.join("\(partialTargetValue)").str, tempDir.join("\(partialTargetValue).o").str]
                    )
                },
            lipo: stubPartialLipoCommandLine + ["-output", frameworkPath.join(isDeepBundle ? "Versions/A" : nil).join(frameworkPath.basenameWithoutSuffix).str] + partialTargetValues.map { partialTargetValue in tempDir.join("\(partialTargetValue)").str }
        )
    }
}

extension FileCopyTaskActionContext {
    public init(_ cbc: CommandBuildContext) {
        let compilerPath = cbc.producer.clangSpec.resolveExecutablePath(cbc, forLanguageOfFileType: cbc.producer.lookupFileType(languageDialect: .c))
        let linkerPath = cbc.producer.ldLinkerSpec.resolveExecutablePath(cbc, Path(cbc.producer.ldLinkerSpec.computeExecutablePath(cbc)))
        let lipoPath = cbc.producer.lipoSpec.resolveExecutablePath(cbc, Path(cbc.producer.lipoSpec.computeExecutablePath(cbc)))

        // If we couldn't find clang, skip the special stub binary handling. We may be using an Open Source toolchain which only has Swift. Also skip it for installLoc builds.
        if compilerPath.isEmpty || !compilerPath.isAbsolute || cbc.scope.evaluate(BuiltinMacros.BUILD_COMPONENTS).contains("installLoc") {
            self.init(skipAppStoreDeployment: true, stubPartialCompilerCommandLine: [], stubPartialLinkerCommandLine: [], stubPartialLipoCommandLine: [], partialTargetValues: [], llvmTargetTripleOSVersion: "", llvmTargetTripleSuffix: "", platformName: "", swiftPlatformTargetPrefix: "", isMacCatalyst: false)
            return
        }

        let scope = cbc.scope

        let partialTargetValues = scope.evaluate(BuiltinMacros.ARCHS).map { arch in
            return scope.evaluate(scope.namespace.parseString("$(CURRENT_ARCH)-$(LLVM_TARGET_TRIPLE_VENDOR)"), lookup: {
                if $0 == BuiltinMacros.CURRENT_ARCH {
                    return scope.namespace.parseLiteralString(arch)
                }
                return nil
            })
        }
        let llvmTargetTripleOSVersion = scope.evaluate(BuiltinMacros.LLVM_TARGET_TRIPLE_OS_VERSION)
        let llvmTargetTripleSuffix = scope.evaluate(BuiltinMacros.LLVM_TARGET_TRIPLE_SUFFIX)
        let platformName = scope.evaluate(BuiltinMacros.PLATFORM_NAME)
        let swiftPlatformTargetPrefix = scope.evaluate(BuiltinMacros.SWIFT_PLATFORM_TARGET_PREFIX)
        let isMacCatalyst = cbc.producer.sdkVariant?.isMacCatalyst == true

        let stubPartialCommonCommandLine = ["-isysroot", scope.evaluate(BuiltinMacros.SDKROOT).str]
        self.init(
            skipAppStoreDeployment: scope.evaluate(BuiltinMacros.ASSETCATALOG_COMPILER_SKIP_APP_STORE_DEPLOYMENT),
            stubPartialCompilerCommandLine: [compilerPath.str] + stubPartialCommonCommandLine + ["-x", "c", "-c", Path.null.str],
            stubPartialLinkerCommandLine: [linkerPath.str] + stubPartialCommonCommandLine + ["-dynamiclib", "-Xlinker", "-adhoc_codesign"],
            stubPartialLipoCommandLine: [lipoPath.str, "-create"],
            partialTargetValues: partialTargetValues,
            llvmTargetTripleOSVersion: llvmTargetTripleOSVersion,
            llvmTargetTripleSuffix: llvmTargetTripleSuffix,
            platformName: platformName,
            swiftPlatformTargetPrefix: swiftPlatformTargetPrefix,
            isMacCatalyst: isMacCatalyst)
    }
}

/// Protocol for objects that can create task actions for in-process tasks.
public protocol TaskActionCreationDelegate
{
    func createAuxiliaryFileTaskAction(_ context: AuxiliaryFileTaskActionContext) -> any PlannedTaskAction
    func createBuildDirectoryTaskAction() -> any PlannedTaskAction
    func createCodeSignTaskAction() -> any PlannedTaskAction
    func createConcatenateTaskAction() -> any PlannedTaskAction
    func createCopyPlistTaskAction() -> any PlannedTaskAction
    func createCopyStringsFileTaskAction() -> any PlannedTaskAction
    func createCopyTiffTaskAction() -> any PlannedTaskAction
    func createDeferredExecutionTaskAction() -> any PlannedTaskAction
    func createEmbedSwiftStdLibTaskAction() -> any PlannedTaskAction
    func createFileCopyTaskAction(_ context: FileCopyTaskActionContext) -> any PlannedTaskAction
    func createGenericCachingTaskAction(enableCacheDebuggingRemarks: Bool, enableTaskSandboxEnforcement: Bool, sandboxDirectory: Path, extraSandboxSubdirectories: [Path], developerDirectory: Path, casOptions: CASOptions) -> any PlannedTaskAction
    func createInfoPlistProcessorTaskAction(_ contextPath: Path) -> any PlannedTaskAction
    func createMergeInfoPlistTaskAction() -> any PlannedTaskAction
    func createLinkAssetCatalogTaskAction() -> any PlannedTaskAction
    func createLSRegisterURLTaskAction() -> any PlannedTaskAction
    func createODRAssetPackManifestTaskAction() -> any PlannedTaskAction
    func createProcessProductEntitlementsTaskAction(scope: MacroEvaluationScope, mergedEntitlements: PropertyListItem, entitlementsVariant: EntitlementsVariant, destinationPlatformName: String, entitlementsFilePath: Path?, fs: any FSProxy) -> any PlannedTaskAction
    func createProcessProductProvisioningProfileTaskAction() -> any PlannedTaskAction
    func createRegisterExecutionPolicyExceptionTaskAction() -> any PlannedTaskAction
    func createSwiftHeaderToolTaskAction() -> any PlannedTaskAction
    func createValidateProductTaskAction() -> any PlannedTaskAction
    func createConstructStubExecutorInputFileListTaskAction() -> any PlannedTaskAction
    func createClangCompileTaskAction() -> any PlannedTaskAction
    func createClangScanTaskAction() -> any PlannedTaskAction
    func createSwiftDriverTaskAction() -> any PlannedTaskAction
    func createSwiftCompilationRequirementTaskAction() -> any PlannedTaskAction
    func createSwiftCompilationTaskAction() -> any PlannedTaskAction
    func createProcessXCFrameworkTask() -> any PlannedTaskAction
    func createValidateDevelopmentAssetsTaskAction() -> any PlannedTaskAction
    func createSignatureCollectionTaskAction() -> any PlannedTaskAction
    func createClangModuleVerifierInputGeneratorTaskAction() -> any PlannedTaskAction
    func createProcessSDKImportsTaskAction() -> any PlannedTaskAction
}

extension TaskActionCreationDelegate {
    public func createDeferredExecutionTaskActionIfRequested(userPreferences: UserPreferences) -> (any PlannedTaskAction)? {
        // Asking the client delegate if a task should be deferred can be expensive, so we allow disabling this behavior via the UserPreferences struct for clients like Xcode that don't need it.
        guard userPreferences.allowsExternalToolExecution else {
            return nil
        }
        return createDeferredExecutionTaskAction()
    }
}
