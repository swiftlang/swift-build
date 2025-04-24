#[[
This source file is part of the Swift open source project

Copyright (c) 2014 - 2025 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
]]

file(TO_NATIVE_PATH "${CMAKE_CURRENT_BINARY_DIR}"
  _SWBCore_NATIVE_CMAKE_CURRENT_BINARY_DIR)
file(CONFIGURE
  OUTPUT resource_bundle_accessor.swift
  CONTENT [[
  import Foundation
  extension Foundation.Bundle {
    static let module: Bundle = {
      let mainPath = Bundle.main.bundleURL.appendingPathComponent("SwiftBuild_SWBCore.resources").path
      let buildPath = #"@_SWBCore_NATIVE_CMAKE_CURRENT_BINARY_DIR@\SwiftBuild_SWBCore.resources"#
      let preferredBundle = Bundle(path: mainPath)
      guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
        Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
      }
      return bundle
    }()
  }
  ]]
  ESCAPE_QUOTES @ONLY NEWLINE_STYLE LF)

add_library(SWBCore
  ActivityReporting.swift
  Apple/DeviceFamily.swift
  Apple/InterfaceBuilderShared.swift
  BuildFileFilteringContext.swift
  BuildFileResolution.swift
  BuildParameters.swift
  BuildRequest.swift
  BuildRequestContext.swift
  BuildRuleAction.swift
  BuildRuleCondition.swift
  BuildRuleSet.swift
  CapturedBuildInfo.swift
  ClangModuleVerifier/ModuleVerifierFilenameMap.swift
  ClangModuleVerifier/ModuleVerifierFramework.swift
  ClangModuleVerifier/ModuleVerifierHeader.swift
  ClangModuleVerifier/ModuleVerifierLanguage.swift
  ClangModuleVerifier/ModuleVerifierModuleMap.swift
  ClangModuleVerifier/ModuleVerifierModuleMapFileVerifier.swift
  ClangModuleVerifier/ModuleVerifierTarget.swift
  ClangModuleVerifierOutputParser.swift
  ClangSerializedDiagnostics.swift
  CommandLineArgument.swift
  ConfiguredTarget.swift
  Core.swift
  CustomTaskTypeDescription.swift
  DependencyInfoEditPayload.swift
  DependencyResolution.swift
  DiagnosticSupport.swift
  EnvironmentBindings.swift
  ExecutableTask.swift
  Extensions/DeveloperDirectoryExtension.swift
  Extensions/DiagnosticToolingExtension.swift
  Extensions/EnvironmentExtension.swift
  Extensions/FeatureAvailabilityExtension.swift
  Extensions/InputFileGroupingStrategyExtension.swift
  Extensions/PlatformInfoExtension.swift
  Extensions/SDKRegistryExtension.swift
  Extensions/SDKVariantInfoExtension.swift
  Extensions/SettingsBuilderExtension.swift
  Extensions/SpecificationsExtension.swift
  Extensions/ToolchainRegistryExtension.swift
  FileSystemSignatureBasedCache.swift
  FileToBuild.swift
  LibclangVendored/ArrayExtensions.swift
  LibclangVendored/CStringArray.swift
  LibclangVendored/Libclang.swift
  LibSwiftDriver/LibSwiftDriver.swift
  LibSwiftDriver/PlannedBuild.swift
  LinkageDependencyResolver.swift
  MacCatalystInfo.swift
  MacroConfigFileLoader.swift
  MacroEvaluationExtensions.swift
  MacroExpressionSourceExtensions.swift
  OnDemandResources.swift
  OptimizationRemarks.swift
  PlannedNode.swift
  PlannedTask.swift
  PlannedTaskAction.swift
  PlatformEnvironment.swift
  PlatformFiltering.swift
  PlatformRegistry.swift
  Process.swift
  ProcessExecutionCache.swift
  ProductTypeIdentifier.swift
  ProjectModel/BuildConfiguration.swift
  ProjectModel/BuildFile.swift
  ProjectModel/BuildPhase.swift
  ProjectModel/BuildRule.swift
  ProjectModel/DependencyInfoFormat.swift
  ProjectModel/FilePathResolver.swift
  ProjectModel/FileTextEncoding.swift
  ProjectModel/ImpartedBuildProperties.swift
  ProjectModel/PIFLoader.swift
  ProjectModel/PlatformFilter.swift
  ProjectModel/Project.swift
  ProjectModel/ProjectModelItem.swift
  ProjectModel/Reference.swift
  ProjectModel/ReferenceLookupContext.swift
  ProjectModel/Target.swift
  ProjectModel/Workspace.swift
  ProjectModel/WorkspaceHeaderIndex.swift
  ProvisionalTask.swift
  Provisioning.swift
  ProvisioningTaskInputs.swift
  SDKRegistry.swift
  Settings/BuildRuleFile.swift
  Settings/BuiltinMacros.swift
  Settings/CASOptions.swift
  Settings/RecursiveSearchPathResolver.swift
  Settings/Settings.swift
  Settings/StackedSearchPaths.swift
  ShellScript.swift
  SigningSupport.swift
  SwiftSDK.swift
  SpecImplementations/CommandLineToolSpec.swift
  SpecImplementations/CompilerSpec.swift
  Specs/CoreBuildSystem.xcspec
  Specs/ExternalBuildSystem.xcspec
  SpecImplementations/FileTypes.swift
  SpecImplementations/LinkerSpec.swift
  Specs/NativeBuildSystem.xcspec
  SpecImplementations/ProductTypes.swift
  SpecImplementations/PropertyDomainSpec.swift
  SpecImplementations/RegisterSpecs.swift
  SpecImplementations/SpecParser.swift
  SpecImplementations/SpecRegistry.swift
  SpecImplementations/Specs.swift
  SpecImplementations/Tools/AppShortcutStringsMetadataCompiler.swift
  SpecImplementations/Tools/CCompiler.swift
  SpecImplementations/Tools/ClangModuleVerifierInputGenerator.swift
  SpecImplementations/Tools/ClangStatCache.swift
  SpecImplementations/Tools/CodeSign.swift
  SpecImplementations/Tools/ConcatenateTool.swift
  SpecImplementations/Tools/ConstructStubExecutorFileListTool.swift
  SpecImplementations/Tools/CopyTool.swift
  SpecImplementations/Tools/CreateAssetPackManifestTool.swift
  SpecImplementations/Tools/CreateBuildDirectory.swift
  SpecImplementations/Tools/DocumentationCompiler.swift
  SpecImplementations/Tools/DsymutilTool.swift
  SpecImplementations/Tools/Gate.swift
  SpecImplementations/Tools/GCCCompatibleCompilerSupport.swift
  SpecImplementations/Tools/GenerateAppPlaygroundAssetCatalog.swift
  SpecImplementations/Tools/InfoPlistTool.swift
  SpecImplementations/Tools/LaunchServicesRegisterTool.swift
  SpecImplementations/Tools/LinkerTools.swift
  SpecImplementations/Tools/Lipo.swift
  SpecImplementations/Tools/MasterObjectLink.swift
  SpecImplementations/Tools/MergeInfoPlist.swift
  SpecImplementations/Tools/MkdirTool.swift
  SpecImplementations/Tools/ModulesVerifierTool.swift
  SpecImplementations/Tools/PLUtilTool.swift
  SpecImplementations/Tools/ProcessSDKImports.swift
  SpecImplementations/Tools/ProcessXCFrameworkLibrary.swift
  SpecImplementations/Tools/ProductPackaging.swift
  SpecImplementations/Tools/RegisterExecutionPolicyException.swift
  SpecImplementations/Tools/SetAttributes.swift
  SpecImplementations/Tools/ShellScriptTool.swift
  SpecImplementations/Tools/SignatureCollection.swift
  SpecImplementations/Tools/StripTool.swift
  SpecImplementations/Tools/SwiftABICheckerTool.swift
  SpecImplementations/Tools/SwiftABIGenerationTool.swift
  SpecImplementations/Tools/SwiftCompiler.swift
  SpecImplementations/Tools/SwiftHeaderTool.swift
  SpecImplementations/Tools/SwiftStdLibTool.swift
  SpecImplementations/Tools/SwiftSymbolExtractor.swift
  SpecImplementations/Tools/SymlinkTool.swift
  SpecImplementations/Tools/TAPISymbolExtractor.swift
  SpecImplementations/Tools/TAPITools.swift
  SpecImplementations/Tools/TiffUtilTool.swift
  SpecImplementations/Tools/TouchTool.swift
  SpecImplementations/Tools/UnifdefTool.swift
  SpecImplementations/Tools/ValidateDevelopmentAssets.swift
  SpecImplementations/Tools/ValidateEmbeddedBinaryTool.swift
  SpecImplementations/Tools/ValidateProductTool.swift
  SpecImplementations/Tools/WriteFile.swift
  SWBFeatureFlag.swift
  TargetDependencyResolver.swift
  TargetPlatformDiagnostics.swift
  TaskGeneration.swift
  TaskResult.swift
  ToolchainRegistry.swift
  ToolInfo/ClangToolInfo.swift
  Tuning.swift
  WorkspaceContext.swift
  WorkspaceSettingsCache.swift
  XCFramework.swift)
set_target_properties(SWBCore PROPERTIES
  Swift_LANGUAGE_VERSION 5)
target_link_libraries(SWBCore PUBLIC
  SWBMacro
  SWBProtocol
  SWBServiceCore
  SWBUtil
  SWBCAS
  SWBLLBuild
  SwiftDriver)
target_sources(SWBCore PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}/resource_bundle_accessor.swift")
