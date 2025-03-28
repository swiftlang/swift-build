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

public import Foundation

import SWBProtocol

/// Errors resulting from macro evaluation.
public struct SWBMacroEvaluationError: Error, LocalizedError {
    public let message: String

    init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        return message
    }
}

/// The top level to use for macro evaluation.
public enum SWBMacroEvaluationLevel: Sendable {
    case defaults
    case project(_ guid: String)
    case target(_ guid: String)

    var toSWBRequest: MacroEvaluationRequestLevel {
        switch self {
        case .defaults:
            return .defaults
        case .project(let guid):
            return .project(guid)
        case .target(let guid):
            return .target(guid)
        }
    }
}

/// The result of a request to get information for the build settings editor.
public struct SWBBuildSettingsEditorInfo: Sendable {
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

    init(from payload: BuildSettingsEditorInfoPayload) {
        self.targetSettingAssignments = payload.targetSettingAssignments
        self.targetXcconfigSettingAssignments = payload.targetXcconfigSettingAssignments
        self.projectSettingAssignments = payload.projectSettingAssignments
        self.projectXcconfigSettingAssignments = payload.projectXcconfigSettingAssignments

        self.targetResolvedSettingsValues = payload.targetResolvedSettingsValues
        self.targetXcconfigResolvedSettingsValues = payload.targetXcconfigResolvedSettingsValues
        self.projectResolvedSettingsValues = payload.projectResolvedSettingsValues
        self.projectXcconfigResolvedSettingsValues = payload.projectXcconfigResolvedSettingsValues
        self.defaultsResolvedSettingsValues = payload.defaultsResolvedSettingsValues
    }
}
