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

import SWBUtil
import SWBMacro
import SWBCore
import Foundation

final class CopyStringsFileSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "com.apple.build-tasks.copy-strings-file"

    override func lookup(_ macro: MacroDeclaration, _ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, _ lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> MacroExpression? {
        switch macro {
        case BuiltinMacros.STRINGS_FILE_OUTPUT_FILENAME:
            let renamePlist = cbc.scope.evaluate(BuiltinMacros.STRINGS_FILE_INFOPLIST_RENAME)

            if renamePlist && inputIsInfoPlistStringsForThisTarget(cbc: cbc) {
                let inputPathFileExtension = cbc.input.absolutePath.fileExtension
                return cbc.scope.namespace.parseLiteralString("InfoPlist.\(inputPathFileExtension)")
            }
            return super.lookup(macro, cbc, delegate)
        default:
            return super.lookup(macro, cbc, delegate)
        }
    }

    private func inputIsInfoPlistStringsForThisTarget(cbc: CommandBuildContext) -> Bool {
        let inputPathBaseName = cbc.input.absolutePath.basenameWithoutSuffix

        let infoPlistPath = cbc.scope.evaluate(BuiltinMacros.INFOPLIST_FILE)
        // If the target has a designated Info.plist file, let's evaluate if the input we're looking at is the matching InfoPlist.strings file:
        if !infoPlistPath.isEmpty {
            if inputPathBaseName == infoPlistPath.basenameWithoutSuffix.appending("Plist") {
                return true
            }
            if inputPathBaseName == infoPlistPath.basenameWithoutSuffix.appending("-InfoPlist") {
                return true
            }
        }

        // If the target doesn't have a designated input Info.plist file, we're most likely looking at target with a generated Info.plist:
        if cbc.scope.evaluate(BuiltinMacros.GENERATE_INFOPLIST_FILE) {
            // If we can confirm that's the case, and that we're looking at the InfoPlist.strings file for this target, we'll rename:
            if let target = cbc.producer.configuredTarget?.target {
                return (inputPathBaseName == "\(target.name)-InfoPlist")
            }
        }

        // Otherwise, if we got here, we can't confirm that this input is the InfoPlist.strings that matches the Info.plist for this target:
        return false
    }

    override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        delegate.taskActionCreationDelegate.createCopyStringsFileTaskAction()
    }
}
