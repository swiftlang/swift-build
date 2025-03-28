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


public enum MacroEvaluationRequestLevel: Equatable, Sendable, SerializableCodable {
    case defaults
    case project(_ guid: String)
    case target(_ guid: String)
}


/// Requests a macro evaluation scope handle in a session.
///
/// This is a flexible message in that the project, target, and build parameters are all optional, but the handler `CreateMacroEvaluationScopeMsg.handle()` will request the handle for the appropriate scope based on which fields were passed.
public struct CreateMacroEvaluationScopeRequest: SessionMessage, RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = StringResponse

    public static let name = "CREATE_MACRO_EVALUATION_SCOPE_REQUEST"

    public let sessionHandle: String

    /// The level the scope should evaluate against.
    public let level: MacroEvaluationRequestLevel

    /// The build parameters to use for the settings.  These are required since they include necessary parameters such as the configuration.
    public let buildParameters: BuildParametersMessagePayload

    public init(sessionHandle: String, level: MacroEvaluationRequestLevel, buildParameters: BuildParametersMessagePayload) {
        self.sessionHandle = sessionHandle
        self.level = level
        self.buildParameters = buildParameters
    }
}

/// Directs the service to discard the macro evaluation scope for the given handle in a session.
public struct DiscardMacroEvaluationScope: SessionMessage, RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = VoidResponse

    public static let name = "DISCARD_MACRO_EVALUATION_SCOPE_REQUEST"

    public let sessionHandle: String
    public let settingsHandle: String

    public init(sessionHandle: String, settingsHandle: String) {
        self.sessionHandle = sessionHandle
        self.settingsHandle = settingsHandle
    }
}


/// The context within which a macro evaluation should occur.
public enum MacroEvaluationRequestContext: Equatable, Sendable, SerializableCodable {
    /// A `Settings` handle, if called by something which is holding on to a handle.
    /// - remark: This was previously used when the client held a handle to a macro evaluation scope to use for evaluation. Presently it is unused, but could be revived if the handle-to-a-scope model is useful in the future.
    case settingsHandle(String)
    /// A level and build parameters, if called on the fly.
    case components(level: MacroEvaluationRequestLevel, buildParameters: BuildParametersMessagePayload)
}

/// The payload the client is requesting the service to evaluate.
public enum MacroEvaluationRequestPayload: Equatable, Sendable, SerializableCodable {
    /// A string.
    case macro(String)
    /// A string expression.
    case stringExpression(String)
    /// A string list expression.
    case stringListExpression([String])
    /// An array of string expressions.
    case stringExpressionArray([String])
}

/// The expected result type the client is requesting.
public enum MacroEvaluationRequestResultType: Equatable, Sendable, SerializableCodable {
    /// The result is expected to be a string.
    case string
    /// The result is expected to be a string list.
    case stringList
}

public struct MacroEvaluationRequest: SessionMessage, RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = MacroEvaluationResponse

    public static let name = "MACRO_EVALUATION_REQUEST"

    public let sessionHandle: String
    public let context: MacroEvaluationRequestContext
    public let request: MacroEvaluationRequestPayload
    public let overrides: [String: String]?
    public let resultType: MacroEvaluationRequestResultType

    public init(sessionHandle: String, context: MacroEvaluationRequestContext, request: MacroEvaluationRequestPayload, overrides: [String: String]?, resultType: MacroEvaluationRequestResultType) {
        self.sessionHandle = sessionHandle
        self.context = context
        self.request = request
        self.overrides = overrides
        self.resultType = resultType
    }
}

/// The result of the macro evaluation returned in a `MacroEvaluationResponse`.
public enum MacroEvaluationResult: Equatable, Sendable, SerializableCodable {
    /// The result is a string.
    case string(String)
    /// The result is a string list.
    case stringList([String])
    /// Something went wrong and an error is being returned.
    case error(String)
}

/// Response to a request to evaluate a macro.
public struct MacroEvaluationResponse: Message, Equatable, SerializableCodable {
    public static let name = "MACRO_EVALUATION_RESPONSE"

    public let result: MacroEvaluationResult

    public init(result: MacroEvaluationResult) {
        self.result = result
    }
}

/// Request to get all macro name-resolved value pairs of all macros in the scope which we wish to export.
public struct AllExportedMacrosAndValuesRequest: SessionMessage, RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = AllExportedMacrosAndValuesResponse

    public static let name = "ALL_EXPORTED_MACROS_AND_VALUES_REQUEST"

    public let sessionHandle: String
    public let context: MacroEvaluationRequestContext

    public init(sessionHandle: String, context: MacroEvaluationRequestContext) {
        self.sessionHandle = sessionHandle
        self.context = context
    }
}

/// Response to an `AllExportedMacrosAndValuesRequest`.
public struct AllExportedMacrosAndValuesResponse: Message, Equatable, SerializableCodable {
    public static let name = "ALL_EXPORTED_MACROS_AND_VALUES_RESPONSE"

    public let result: [String: String]

    public init(result: [String: String]) {
        self.result = result
    }
}

/// Request to get macro assignment and resolved value information to show in the build settings editor.
public struct BuildSettingsEditorInfoRequest: SessionMessage, RequestMessage, Equatable, SerializableCodable {
    public typealias ResponseMessage = BuildSettingsEditorInfoResponse
    
    public static let name = "INFO_FOR_BUILD_SETTINGS_EDITOR_REQUEST"

    public let sessionHandle: String
    public let context: MacroEvaluationRequestContext

    public init(sessionHandle: String, context: MacroEvaluationRequestContext) {
        self.sessionHandle = sessionHandle
        self.context = context
    }
}

/// Collection of information for display in the build settings editor.
public struct BuildSettingsEditorInfoPayload: Equatable, Sendable, SerializableCodable {
    public let targetSettingAssignments: [String: String]?
    public let targetXcconfigSettingAssignments: [String: String]?
    public let projectSettingAssignments: [String: String]?
    public let projectXcconfigSettingAssignments: [String: String]?

    public let targetResolvedSettingsValues: [String: String]?
    public let targetXcconfigResolvedSettingsValues: [String: String]?
    public let projectResolvedSettingsValues: [String: String]?
    public let projectXcconfigResolvedSettingsValues: [String: String]?
    public let defaultsResolvedSettingsValues: [String: String]?

    public init(targetSettingAssignments: [String: String]?, targetXcconfigSettingAssignments: [String: String]?, projectSettingAssignments: [String: String]?, projectXcconfigSettingAssignments: [String: String]?, targetResolvedSettingsValues: [String: String]?, targetXcconfigResolvedSettingsValues: [String: String]?, projectResolvedSettingsValues: [String: String]?, projectXcconfigResolvedSettingsValues: [String: String]?, defaultsResolvedSettingsValues: [String: String]?) {
        self.targetSettingAssignments = targetSettingAssignments
        self.targetXcconfigSettingAssignments = targetXcconfigSettingAssignments
        self.projectSettingAssignments = projectSettingAssignments
        self.projectXcconfigSettingAssignments = projectXcconfigSettingAssignments

        self.targetResolvedSettingsValues = targetResolvedSettingsValues
        self.targetXcconfigResolvedSettingsValues = targetXcconfigResolvedSettingsValues
        self.projectResolvedSettingsValues = projectResolvedSettingsValues
        self.projectXcconfigResolvedSettingsValues = projectXcconfigResolvedSettingsValues
        self.defaultsResolvedSettingsValues = defaultsResolvedSettingsValues
    }
}

/// Response to a `MacroInfoForBuildSettingsEditor`.
public struct BuildSettingsEditorInfoResponse: Message, Equatable, SerializableCodable {
    public static let name = "INFO_FOR_BUILD_SETTINGS_EDITOR_RESPONSE"

    public let result: BuildSettingsEditorInfoPayload

    public init(result: BuildSettingsEditorInfoPayload) {
        self.result = result
    }
}

let macroEvaluationMessageTypes: [any Message.Type] = [
    CreateMacroEvaluationScopeRequest.self,
    DiscardMacroEvaluationScope.self,
    MacroEvaluationRequest.self,
    MacroEvaluationResponse.self,
    AllExportedMacrosAndValuesRequest.self,
    AllExportedMacrosAndValuesResponse.self,
    BuildSettingsEditorInfoRequest.self,
    BuildSettingsEditorInfoResponse.self,
]
