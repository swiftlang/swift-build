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

public typealias XCBBuildOperation = SWBBuildOperation
public typealias XCBBuildService = SWBBuildService
public typealias XCBBuildServiceConsole = SWBBuildServiceConsole
public typealias XCBServiceConsoleCommandRegistry = SWBServiceConsoleCommandRegistry
public typealias XCBBuildServiceSession = SWBBuildServiceSession
public typealias XCBuildFileType = SwiftBuildFileType
public typealias XCBBuildOperationTaskMetrics = SWBBuildOperationTaskMetrics
public typealias XCBBuildOperationBacktraceFrame = SWBBuildOperationBacktraceFrame
public typealias XCBBuildParameters = SWBBuildParameters
public typealias XCBRunDestinationInfo = SWBRunDestinationInfo
public typealias XCBArenaInfo = SWBArenaInfo
public typealias XCBSettingsTable = SWBSettingsTable
public typealias XCBSettingsOverrides = SWBSettingsOverrides
public typealias XCBBuildCommand = SWBBuildCommand
public typealias XCBConfiguredTarget = SWBConfiguredTarget
public typealias XCBBuildRequest = SWBBuildRequest
public typealias XCBServiceConsoleCommandInvocation = SWBServiceConsoleCommandInvocation
public typealias XCBServiceConsoleResult = SWBServiceConsoleResult
public typealias XCBDocumentationInfo = SWBDocumentationInfo
public typealias XCBDocumentationBundleInfo = SWBDocumentationBundleInfo
public typealias XCBIndexingFileSettings = SWBIndexingFileSettings
public typealias XCBIndexingHeaderInfo = SWBIndexingHeaderInfo
public typealias XCBBuildDescriptionTargetInfo = SWBBuildDescriptionTargetInfo
public typealias XCBLocalizationInfo = SWBLocalizationInfo
public typealias XCBLocalizationTargetInfo = SWBLocalizationTargetInfo
public typealias XCBLocalizationBuildPortion = SWBLocalizationBuildPortion
public typealias XCBBuildSettingsEditorInfo = SWBBuildSettingsEditorInfo
public typealias XCBMacroEvaluationError = SWBMacroEvaluationError
public typealias XCBPreviewInfo = SWBPreviewInfo
public typealias XCBPreviewTargetDependencyInfo = SWBPreviewTargetDependencyInfo
public typealias XCBActionInput = SWBActionInput
public typealias XCBSchemeInput = SWBSchemeInput
public typealias XCBSchemeDescription = SWBSchemeDescription
public typealias XCBActionsInfo = SWBActionsInfo
public typealias XCBProductDescription = SWBProductDescription
public typealias XCBDestinationInfo = SWBDestinationInfo
public typealias XCBActionInfo = SWBActionInfo
public typealias XCBTestPlanInfo = SWBTestPlanInfo
public typealias XCBProductInfo = SWBProductInfo
public typealias XCBProductTupleDescription = SWBProductTupleDescription
public typealias XCBProvisioningTaskInputsSourceData = SWBProvisioningTaskInputsSourceData
public typealias XCBProvisioningTaskInputs = SWBProvisioningTaskInputs
public typealias XCBSystemInfo = SWBSystemInfo
public typealias XCBTargetGUID = SWBTargetGUID
public typealias XCBUserInfo = SWBUserInfo
public typealias XCBWorkspaceInfo = SWBWorkspaceInfo
public typealias XCBTargetInfo = SWBTargetInfo
public typealias XCBuildMessage = SwiftBuildMessage
public typealias XCBBuildAction = SWBBuildAction
public typealias XCBBuildOperationState = SWBBuildOperationState
public typealias XCBProcessExitStatus = SWBProcessExitStatus
public typealias XCBExternalToolResult = SWBExternalToolResult
public typealias XCBBuildTaskStyle = SWBBuildTaskStyle
public typealias XCBBuildFilesAction = SWBBuildFilesAction
public typealias XCBBuildLocationStyle = SWBBuildLocationStyle
public typealias XCBPreviewStyle = SWBPreviewStyle
public typealias XCBSchemeCommand = SWBSchemeCommand
public typealias XCBBuildQoS = SWBBuildQoS
public typealias XCBDependencyScope = SWBDependencyScope
public typealias XCBuildError = SwiftBuildError
public typealias XCBBuildServiceConnectionMode = SWBBuildServiceConnectionMode
public typealias XCBBuildServiceVariant = SWBBuildServiceVariant
public typealias XCBServiceConsoleError = SWBServiceConsoleError
public typealias XCBuildServicePIFObjectType = SwiftBuildServicePIFObjectType
public typealias XCBMacroEvaluationLevel = SWBMacroEvaluationLevel
public typealias XCBPropertyListItem = SWBPropertyListItem
public typealias XCBProvisioningStyle = SWBProvisioningStyle
public typealias XCBProvisioningProfileSupport = SWBProvisioningProfileSupport
public typealias XCBPlanningOperationDelegate = SWBPlanningOperationDelegate
public typealias XCBServiceConsoleCommand = SWBServiceConsoleCommand
public typealias XCBDocumentationDelegate = SWBDocumentationDelegate
public typealias XCBIndexingDelegate = SWBIndexingDelegate
public typealias XCBLocalizationDelegate = SWBLocalizationDelegate
public typealias XCBPreviewDelegate = SWBPreviewDelegate
public typealias XCBCommandResult = SWBCommandResult

public func XCBuildGetVersion() throws -> String {
    return try SwiftBuildGetVersion()
}
