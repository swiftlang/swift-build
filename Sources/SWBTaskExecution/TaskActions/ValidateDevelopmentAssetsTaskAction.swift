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

public import SWBCore
import SWBUtil
import SWBMacro

public final class ValidateDevelopmentAssetsTaskAction: TaskAction {
    public override class var toolIdentifier: String {
        return "validate-development-assets"
    }

    public override func performTaskAction(_ task: any ExecutableTask, dynamicExecutionDelegate: any DynamicTaskExecutionDelegate, executionDelegate: any TaskExecutionDelegate, clientDelegate: any TaskExecutionClientDelegate, outputDelegate: any TaskOutputDelegate) async -> CommandResult {
        let developmentAssetsPaths = task.commandLineAsStrings.dropFirst(3).map(Path.init)
        let behavior: Diagnostic.Behavior
        switch Array(task.commandLineAsStrings.dropFirst(2)).first {
        case "YES":
            behavior = .warning
        case "YES_ERROR":
            behavior = .error
        default:
            return .succeeded
        }

        // Check that all specified development assets paths exist on the file system
        var hadErrors = false
        for absolutePath in developmentAssetsPaths {
            if !absolutePath.isAbsolute {
                outputDelegate.emit(Diagnostic(behavior: behavior, location: .buildSetting(BuiltinMacros.DEVELOPMENT_ASSET_PATHS), data: DiagnosticData("One of the paths in \(BuiltinMacros.DEVELOPMENT_ASSET_PATHS.name) is not an absolute path: \(absolutePath.str)", component: .targetIntegrity)))
                hadErrors = true
            } else if !executionDelegate.fs.exists(absolutePath) {
                outputDelegate.emit(Diagnostic(behavior: behavior, location: .buildSetting(BuiltinMacros.DEVELOPMENT_ASSET_PATHS), data: DiagnosticData("One of the paths in \(BuiltinMacros.DEVELOPMENT_ASSET_PATHS.name) does not exist: \(absolutePath.str)", component: .targetIntegrity)))
                hadErrors = true
            }
        }

        return hadErrors ? .failed : .succeeded
    }
}
