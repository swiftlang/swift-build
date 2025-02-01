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

// MARK: PIF key constant definitions

// Generic keys used by multiple kinds of objects
public let PIFKey_guid                          = "guid"
public let PIFKey_name                          = "name"
public let PIFKey_path                          = "path"
public let PIFKey_type                          = "type"
public let PIFKey_buildConfigurations           = "buildConfigurations"
public let PIFKey_impartedBuildProperties       = "impartedBuildProperties"
public let PIFKey_platformFilters               = "platformFilters"

// Keys specific to workspaces
public let PIFKey_Workspace_projects    = "projects"

// Keys specific to projects
public let PIFKey_Project_projectDirectory              = "projectDirectory"
public let PIFKey_Project_name                          = "projectName"
public let PIFKey_Project_isPackage                     = "projectIsPackage"
public let PIFKey_Project_targets                       = "targets"
public let PIFKey_Project_groupTree                     = "groupTree"
public let PIFKey_Project_defaultConfigurationName      = "defaultConfigurationName"
public let PIFKey_Project_developmentRegion             = "developmentRegion"
public let PIFKey_Project_classPrefix                   = "classPrefix"
public let PIFKey_Project_appPreferencesBuildSettings   = "appPreferencesBuildSettings"

// Keys specific to references
public let PIFKey_Reference_sourceTree         = "sourceTree"
public let PIFKey_Reference_fileType           = "fileType"
public let PIFKey_Reference_producingTarget    = "producingTarget"
public let PIFKey_Reference_regionVariantName  = "regionVariantName"
public let PIFKey_Reference_remoteReference    = "remoteReference"
public let PIFKey_Reference_children           = "children"
public let PIFKey_Reference_fileTextEncoding   = "fileTextEncoding"
public let PIFKey_Reference_expectedSignature  = "expectedSignature"

// Keys specific to targets
public let PIFKey_Target_productReference          = "productReference"
public let PIFKey_Target_productTypeIdentifier     = "productTypeIdentifier"
public let PIFKey_Target_dependencies              = "dependencies"
public let PIFKey_Target_buildPhases               = "buildPhases"
public let PIFKey_Target_buildRules                = "buildRules"
public let PIFKey_Target_customTasks               = "customTasks"
public let PIFKey_Target_performanceTestsBaselinesPath = "performanceTestsBaselinesPath"
public let PIFKey_Target_predominantSourceCodeLanguage = "predominantSourceCodeLanguage"
public let PIFKey_Target_isPackageTarget           = "isPackageTarget"
public let PIFKey_Target_provisioningSourceData    = "provisioningSourceData"
public let PIFKey_Target_developmentTeamIdentifier = "developmentTeamIdentifier"
public let PIFKey_Target_frameworksBuildPhase      = "frameworksBuildPhase"
public let PIFKey_Target_dynamicTargetVariantGuid  = "dynamicTargetVariantGuid"
public let PIFKey_Target_approvedByUser            = "approvedByUser"

// Keys specific to external targets
public let PIFKey_ExternalTarget_toolPath                           = "toolPath"
public let PIFKey_ExternalTarget_arguments                          = "arguments"
public let PIFKey_ExternalTarget_workingDirectory                   = "workingDirectory"
public let PIFKey_ExternalTarget_passBuildSettingsInEnvironment     = "passBuildSettingsInEnvironment"

// Keys specific to build phases
public let PIFKey_BuildPhase_buildFiles                             = "buildFiles"
public let PIFKey_BuildPhase_destinationSubfolder                   = "destinationSubfolder"
public let PIFKey_BuildPhase_destinationSubpath                     = "destinationSubpath"
public let PIFKey_BuildPhase_emitEnvironment                        = "emitEnvironment"
public let PIFKey_BuildPhase_sandboxingOverride                     = "sandboxingOverride"
public let PIFKey_BuildPhase_inputFilePaths                         = "inputFilePaths"
public let PIFKey_BuildPhase_inputFileListPaths                     = "inputFileListPaths"
public let PIFKey_BuildPhase_name                                   = "name"
public let PIFKey_BuildPhase_originalObjectID                       = "originalObjectID"
public let PIFKey_BuildPhase_outputFilePaths                        = "outputFilePaths"
public let PIFKey_BuildPhase_outputFileListPaths                    = "outputFileListPaths"
public let PIFKey_BuildPhase_runOnlyForDeploymentPostprocessing     = "runOnlyForDeploymentPostprocessing"
public let PIFKey_BuildPhase_shellPath                              = "shellPath"
public let PIFKey_BuildPhase_scriptContents                         = "scriptContents"
public let PIFKey_BuildPhase_dependencyFileFormat                   = "dependencyFileFormat"
public let PIFKey_BuildPhase_dependencyFilePaths                    = "dependencyFilePaths"
public let PIFKey_BuildPhase_alwaysOutOfDate                        = "alwaysOutOfDate"
public let PIFKey_BuildPhase_alwaysRunForInstallHdrs                = "alwaysRunForInstallHdrs"

// Keys specific to build files
public let PIFKey_BuildFile_fileReference               = "fileReference"
public let PIFKey_BuildFile_targetReference             = "targetReference"
public let PIFKey_BuildFile_additionalCompilerOptions   = "additionalCompilerOptions"
public let PIFKey_BuildFile_assetTags                   = "assetTags"
public let PIFKey_BuildFile_decompress                  = "decompress"
public let PIFKey_BuildFile_headerVisibility            = "headerVisibility"
public let PIFKey_BuildFile_migCodegenFiles             = "migCodegenFiles"
public let PIFKey_BuildFile_intentsCodegenFiles         = "intentsCodegenFiles"
public let PIFKey_BuildFile_intentsCodegenVisibility    = "intentsCodegenVisibility"
public let PIFKey_BuildFile_codeSignOnCopy              = "codeSignOnCopy"
public let PIFKey_BuildFile_removeHeadersOnCopy         = "removeHeadersOnCopy"
public let PIFKey_BuildFile_linkUsingSearchPath         = "linkUsingSearchPath"
public let PIFKey_BuildFile_shouldLinkWeakly            = "shouldLinkWeakly"
public let PIFKey_BuildFile_shouldWarnIfNoRuleToProcess = "shouldWarnIfNoRuleToProcess"
public let PIFKey_BuildFile_resourceRule                = "resourceRule"

// Keys specific to build rules
public let PIFKey_BuildRule_fileTypeIdentifier                  = "fileTypeIdentifier"
public let PIFKey_BuildRule_filePatterns                        = "filePatterns"
public let PIFKey_BuildRule_compilerSpecificationIdentifier     = "compilerSpecificationIdentifier"
public let PIFKey_BuildRule_scriptContents                      = "scriptContents"
public let PIFKey_BuildRule_inputFilePaths                      = "inputFilePaths"
public let PIFKey_BuildRule_inputFileListPaths                  = "inputFileListPaths"
public let PIFKey_BuildRule_outputFilePaths                     = "outputFilePaths"
public let PIFKey_BuildRule_outputFileListPaths                 = "outputFileListPaths"
public let PIFKey_BuildRule_outputFilesCompilerFlags            = "outputFilesCompilerFlags"
public let PIFKey_BuildRule_dependencyFileFormat                = "dependencyFileFormat"
public let PIFKey_BuildRule_dependencyFilePaths                 = "dependencyFilePaths"
public let PIFKey_BuildRule_runOncePerArchitecture              = "runOncePerArchitecture"

// Keys specific to custom tasks
public let PIFKey_CustomTask_commandLine           = "commandLine"
public let PIFKey_CustomTask_environment           = "environment"
public let PIFKey_CustomTask_workingDirectory      = "workingDirectory"
public let PIFKey_CustomTask_executionDescription  = "executionDescription"
public let PIFKey_CustomTask_inputFilePaths        = "inputFilePaths"
public let PIFKey_CustomTask_outputFilePaths       = "outputFilePaths"
public let PIFKey_CustomTask_enableSandboxing      = "enableSandboxing"
public let PIFKey_CustomTask_preparesForIndexing   = "preparesForIndexing"

// Special value for PIFKey_BuildRule_fileTypeIdentifier
public let PIFKey_BuildRule_fileTypeIdentifier_pattern_proxy    = "pattern.proxy"

// Special value for PIFKey_BuildRule_compilerSpecificationIdentifier
public let PIFKey_BuildRule_compilerSpecificationIdentifier_com_apple_compilers_proxy_script  = "com.apple.compilers.proxy.script"

// Keys specific to build configurations
public let PIFKey_BuildConfiguration_buildSettings                      = "buildSettings"
public let PIFKey_BuildConfiguration_baseConfigurationFileReference     = "baseConfigurationFileReference"
