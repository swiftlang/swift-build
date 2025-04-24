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

import SWBMacro
import SWBCore
import SWBUtil

final class CopyPlistFileSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "com.apple.build-tasks.copy-plist-file"

    override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        delegate.taskActionCreationDelegate.createCopyPlistTaskAction()
    }

    override func lookup(_ macro: MacroDeclaration, _ cbc: CommandBuildContext, _ delegate: any DiagnosticProducingDelegate, _ lookup: ((MacroDeclaration) -> MacroExpression?)? = nil) -> MacroExpression? {
        // FIXME:  <rdar://problem/24544651> [Swift Build] Improve definition of task output paths w/ specs and the CommandBuildContext
        if cbc.outputs.count == 1 && macro == BuiltinMacros.ProductResourcesDir {
            return cbc.scope.table.namespace.parseLiteralString(cbc.output.dirname.str)
        }
        return super.lookup(macro, cbc, delegate, lookup)
    }
}
