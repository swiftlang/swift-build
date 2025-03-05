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

public final class GenerateAppPlaygroundAssetCatalog: GenericCommandLineToolSpec, SpecIdentifierType, @unchecked Sendable {
    public static let identifier: String = "com.apple.tools.generate-app-playground-asset-catalog"

    public override func createTaskAction(_ cbc: CommandBuildContext, _ delegate: any TaskGenerationDelegate) -> (any PlannedTaskAction)? {
        return delegate.taskActionCreationDelegate.createDeferredExecutionTaskActionIfRequested(userPreferences: delegate.userPreferences)
    }
}
