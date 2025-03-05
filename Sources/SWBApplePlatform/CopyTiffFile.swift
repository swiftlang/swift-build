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

import SWBCore

final class CopyTiffFileSpec: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    static let identifier = "com.apple.build-tasks.copy-tiff-file"

    override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        delegate.taskActionCreationDelegate.createCopyTiffTaskAction()
    }
}
