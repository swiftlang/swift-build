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
  KnownFolders.swift
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
  Specs/CommandLineToolSpec.swift
  Specs/CompilerSpec.swift
  Specs/CoreBuildSystem.xcspec
  Specs/ExternalBuildSystem.xcspec
  Specs/FileTypes.swift
  Specs/LinkerSpec.swift
  Specs/NativeBuildSystem.xcspec
  Specs/ProductTypes.swift
  Specs/PropertyDomainSpec.swift
  Specs/RegisterSpecs.swift
  Specs/SpecParser.swift
  Specs/SpecRegistry.swift
  Specs/Specs.swift
  Specs/Tools/AppIntentsMetadataCompiler.swift
  Specs/Tools/AppIntentsSSUTrainingCompiler.swift
  Specs/Tools/AppShortcutStringsMetadataCompiler.swift
  Specs/Tools/CCompiler.swift
  Specs/Tools/ClangModuleVerifierInputGenerator.swift
  Specs/Tools/ClangStatCache.swift
  Specs/Tools/CodeSign.swift
  Specs/Tools/ConcatenateTool.swift
  Specs/Tools/ConstructStubExecutorFileListTool.swift
  Specs/Tools/CopyTool.swift
  Specs/Tools/CreateAssetPackManifestTool.swift
  Specs/Tools/CreateBuildDirectory.swift
  Specs/Tools/DocumentationCompiler.swift
  Specs/Tools/DsymutilTool.swift
  Specs/Tools/Gate.swift
  Specs/Tools/GCCCompatibleCompilerSupport.swift
  Specs/Tools/GenerateAppPlaygroundAssetCatalog.swift
  Specs/Tools/InfoPlistTool.swift
  Specs/Tools/LaunchServicesRegisterTool.swift
  Specs/Tools/LinkerTools.swift
  Specs/Tools/Lipo.swift
  Specs/Tools/MasterObjectLink.swift
  Specs/Tools/MergeInfoPlist.swift
  Specs/Tools/MkdirTool.swift
  Specs/Tools/ModulesVerifierTool.swift
  Specs/Tools/PLUtilTool.swift
  Specs/Tools/ProcessSDKImports.swift
  Specs/Tools/ProcessXCFrameworkLibrary.swift
  Specs/Tools/ProductPackaging.swift
  Specs/Tools/RegisterExecutionPolicyException.swift
  Specs/Tools/SetAttributes.swift
  Specs/Tools/ShellScriptTool.swift
  Specs/Tools/SignatureCollection.swift
  Specs/Tools/StripTool.swift
  Specs/Tools/SwiftABICheckerTool.swift
  Specs/Tools/SwiftABIGenerationTool.swift
  Specs/Tools/SwiftCompiler.swift
  Specs/Tools/SwiftHeaderTool.swift
  Specs/Tools/SwiftStdLibTool.swift
  Specs/Tools/SwiftSymbolExtractor.swift
  Specs/Tools/SymlinkTool.swift
  Specs/Tools/TAPISymbolExtractor.swift
  Specs/Tools/TAPITools.swift
  Specs/Tools/TiffUtilTool.swift
  Specs/Tools/TouchTool.swift
  Specs/Tools/UnifdefTool.swift
  Specs/Tools/ValidateDevelopmentAssets.swift
  Specs/Tools/ValidateEmbeddedBinaryTool.swift
  Specs/Tools/ValidateProductTool.swift
  Specs/Tools/WriteFile.swift
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
