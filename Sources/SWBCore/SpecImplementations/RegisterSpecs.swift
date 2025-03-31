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
private import TSCBasic
public import Foundation

extension SWBUtil.AbsolutePath {
    // FIXME: Sink down to SWBUtil with an implementation not bound to TSC. It's also not clear that this should be non-failable, as "Because both paths are absolute, they always have a common ancestor (the root path, if nothing else)." is not true on Windows.
    public func relative(to other: SWBUtil.AbsolutePath) -> SWBUtil.RelativePath {
        try! RelativePath(validating: TSCBasic.AbsolutePath(validating: path.str).relative(to: TSCBasic.AbsolutePath(validating: other.path.str)).pathString)
    }
}

public struct BuiltinSpecsExtension: SpecificationsExtension {
    public init() {
    }

    public func specificationTypes() -> [any SpecType.Type] {
        [
            ArchitectureSpec.self,
            BuildPhaseSpec.self,
            BuildSettingsSpec.self,
            BuildSystemSpec.self,
            CommandLineToolSpec.self,
            CompilerSpec.self,
            FileTypeSpec.self,
            LinkerSpec.self,
            PackageTypeSpec.self,
            ProductTypeSpec.self,
            PlatformSpec.self,
            ProjectOverridesSpec.self,
        ]
    }

    public func specificationClasses() -> [any SpecIdentifierType.Type] {
        [
            AppShortcutStringsMetadataCompilerSpec.self,
            CodesignToolSpec.self,
            CopyToolSpec.self,
            ClangStatCacheSpec.self,
            DocumentationCompilerSpec.self,
            TAPISymbolExtractor.self,
            SwiftSymbolExtractor.self,
            DsymutilToolSpec.self,
            InfoPlistToolSpec.self,
            LaunchServicesRegisterToolSpec.self,
            LdLinkerSpec.self,
            LibtoolLinkerSpec.self,
            LipoToolSpec.self,
            MkdirToolSpec.self,
            PLUtilToolSpec.self,
            ProductPackagingToolSpec.self,
            ShellScriptToolSpec.self,
            StripToolSpec.self,
            SwiftStdLibToolSpec.self,
            SwiftABICheckerToolSpec.self,
            SwiftABIGenerationToolSpec.self,
            SwiftCompilerSpec.self,
            SymlinkToolSpec.self,
            ModulesVerifierToolSpec.self,
            ClangModuleVerifierInputGeneratorSpec.self,
            TAPIToolSpec.self,
            TiffUtilToolSpec.self,
            TouchToolSpec.self,
            UnifdefToolSpec.self,
            ValidateEmbeddedBinaryToolSpec.self,
            ValidateProductToolSpec.self,
            GenerateAppPlaygroundAssetCatalog.self,

            // specification classes for C Compiler tools
            AbstractCCompilerSpec.self,
            ClangCompilerSpec.self,
            ClangStaticAnalyzerSpec.self,
        ]
    }

    public func specificationClassesClassic() -> [any SpecClassType.Type] {
        [
            // File type specs
            ApplicationWrapperFileTypeSpec.self,
            CFBundleWrapperFileTypeSpec.self,
            FrameworkWrapperFileTypeSpec.self,
            HTMLFileTypeSpec.self,
            MachOFileTypeSpec.self,
            PlistFileTypeSpec.self,
            PlugInKitPluginWrapperFileTypeSpec.self,
            SpotlightImporternWrapperFileTypeSpec.self,
            StaticFrameworkWrapperFileTypeSpec.self,
            XCFrameworkWrapperFileTypeSpec.self,
            XPCServiceWrapperFileTypeSpec.self,

            // Product type specs
            ApplicationProductTypeSpec.self,
            ApplicationExtensionProductTypeSpec.self,
            BundleProductTypeSpec.self,
            DynamicLibraryProductTypeSpec.self,
            FrameworkProductTypeSpec.self,
            KernelExtensionProductTypeSpec.self,
            StandaloneExecutableProductTypeSpec.self,
            StaticFrameworkProductTypeSpec.self,
            StaticLibraryProductTypeSpec.self,
            ToolProductTypeSpec.self,
            XCTestBundleProductTypeSpec.self,
        ]
    }

    // spec implementations (custom classes we provide which have no backing spec file at all).
    public func specificationImplementations() -> [any SpecImplementationType.Type] {
        [
            ConcatenateToolSpec.self,
            CreateAssetPackManifestToolSpec.self,
            CreateBuildDirectorySpec.self,
            MergeInfoPlistSpec.self,
            ProcessSDKImportsSpec.self,
            ProcessXCFrameworkLibrarySpec.self,
            RegisterExecutionPolicyExceptionToolSpec.self,
            SwiftHeaderToolSpec.self,
            TAPIMergeToolSpec.self,
            ValidateDevelopmentAssets.self,
            ConstructStubExecutorFileListToolSpec.self,
            GateSpec.self,
            MasterObjectLinkSpec.self,
            SetAttributesSpec.self,
            WriteFileSpec.self,
            SignatureCollectionSpec.self,

            // specification implementations for C Compiler tools
            ClangPreprocessorSpec.self,
            ClangAssemblerSpec.self,
            ClangModuleVerifierSpec.self,
        ]
    }

    public func specificationFiles(resourceSearchPaths: [SWBUtil.Path]) -> Bundle? {
        findResourceBundle(nameWhenInstalledInToolchain: "SwiftBuild_SWBCore", resourceSearchPaths: resourceSearchPaths, defaultBundle: Bundle.module)
    }
}
